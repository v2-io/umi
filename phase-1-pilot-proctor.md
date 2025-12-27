# Phase 1 Pilot: Proctor

**Status:** Ready for Implementation
**Date:** 2025-12-26
**Updated:** After spike validation

## What Is Proctor?

Proctor transforms a long-lived external process into a Ractor-citizen with:
- **Bidirectional messaging** - stdin/stdout as send/receive
- **Death notification** - via `Ractor.monitor` (discovered in spikes!)
- **Isolation** - process crashes become messages, not Ruby crashes

Think of it as: "Erlang ports for Ruby 4.0"

```ruby
# Vision
proctor = Umi::Proctor.new("redis-server", "--port", "6379")

# Bidirectional communication
proctor << "PING\r\n"
response = proctor.receive  # => "PONG\r\n"

# Death notification (non-blocking)
proctor.on_exit { |status| log "Redis died: #{status}" }

# Or blocking wait
result = proctor.join  # => Proctor::Result
```

---

## What We Learned From Spikes

### Key Discoveries (see `spikes/FINDINGS-DETAILS.md`)

1. **`Ractor.monitor(port)`** - Ruby 4.0 provides death notification!
   - Sends `:exited` (normal) or `:aborted` (crash) to specified port
   - Can be mixed with message ports in `Ractor.select`

2. **Spawn INSIDE the Ractor** - Process must be spawned internally
   - Passing IO objects from main to Ractor hangs for bidirectional pipes
   - `Open3.popen3` works inside Ractors
   - Ractor that spawns the process "owns" it for `Process.wait2`

3. **Threads inside Ractors** - Essential for async I/O
   - stdout_thread, stderr_thread, death_thread pattern works
   - Threads send to parent via `parent << [:event, data]`

4. **NO native timeout in `Ractor.select`** - Must use timer Ractor pattern
   - Spawn a Ractor that sleeps then sends `:timeout`
   - Include timer_port in select
   - Challenge: cleanup timer if message arrives first

5. **Port ownership** - Only creator can `receive`, anyone can `send`

### What the Original Plan Got Wrong

| Original Assumption | Reality |
|---------------------|---------|
| Pass pipes to Watcher Ractor | Spawn process INSIDE Watcher |
| `Ractor.select` has timeout | NO - use timer Ractor pattern |
| "No built-in process linking" | `Ractor.monitor` provides this! |
| Need to build death detection | Already exists via monitor |

---

## Architecture (Revised)

### Core Components

```
┌─────────────────────────────────────────────────────────┐
│                    User Code                             │
│   proctor = Proctor.new("cmd"); proctor << msg          │
└─────────────────────────┬───────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────┐
│                  Proctor (API object)                    │
│   - Holds reference to Watcher Ractor                   │
│   - Forwards commands: [:stdin, data], [:kill, sig]     │
│   - Receives events: [:stdout, line], [:process_died]   │
│   - Monitors Watcher with watcher.monitor(inbox)        │
└─────────────────────────┬───────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────┐
│              Watcher Ractor (OWNS EVERYTHING)           │
│   - Spawns process with Open3.popen3 internally         │
│   - stdout_thread: reads stdout, sends to parent        │
│   - stderr_thread: reads stderr, sends to parent        │
│   - death_thread: wait_thr.value, sends to parent       │
│   - Command loop: Ractor.receive → stdin.write          │
└─────────────────────────┬───────────────────────────────┘
                          │
                    ┌─────┴─────┐
                    │ OS Process │
                    │ (the cmd)  │
                    └───────────┘
```

### Message Flow (Revised)

```
User           Proctor         Watcher Ractor       OS Process
  │                │                  │                  │
  │── new(cmd) ───▶│                  │                  │
  │                │── Ractor.new ───▶│                  │
  │                │   (cmd passed    │── popen3(cmd) ──▶│
  │                │    as arg)       │   (spawns        │
  │                │                  │    internally)   │
  │                │                  │                  │
  │                │◀─ [:started,pid]─│                  │
  │                │                  │                  │
  │── << msg ─────▶│                  │                  │
  │                │── [:stdin,msg] ─▶│                  │
  │                │                  │── stdin.write ──▶│
  │                │                  │                  │
  │                │                  │◀── stdout ───────│
  │                │◀─ [:stdout,line]─│  (via thread)    │
  │◀── receive ────│                  │                  │
  │                │                  │                  │
  │                │                  │    (process dies)│
  │                │◀─[:process_died]─│◀── wait_thr ─────│
  │                │◀─ :exited ───────│  (via monitor)   │
  │◀── on_exit ────│                  │                  │
```

---

## Design Constraints (Updated)

### From Ruby 4.0 Ractors (Verified by Spikes)
- Process MUST be spawned inside the Ractor (not passed FDs)
- `Ractor.monitor(port)` provides death notification
- `Ractor.select` has NO timeout - use timer Ractor pattern
- Port ownership: only creator can receive
- Threads inside Ractors work for async I/O

### From the Problem Domain (Unchanged)
- External processes communicate via stdin/stdout/stderr
- They signal completion via exit codes and signals
- They can hang, crash, or produce unbounded output
- We need timeout capability at every layer

### From Ruby Philosophy (Unchanged)
- Blocks for configuration
- Duck typing over rigid interfaces
- Composition over inheritance
- Explicit over implicit

---

## API Design (Mostly Unchanged)

### Creation

```ruby
# Basic
proctor = Umi::Proctor.new("redis-server")

# With arguments
proctor = Umi::Proctor.new("ffmpeg", "-i", input, "-o", output)

# With options
proctor = Umi::Proctor.new("server",
  env: { "PORT" => "3000" },
  chdir: "/app",
  stderr: :merge,        # merge stderr into stdout stream
  line_buffered: true    # receive line-by-line instead of chunks (default)
)

# Block form (auto-cleanup)
Umi::Proctor.open("redis-server") do |redis|
  redis << "PING\r\n"
  puts redis.receive
end  # automatically killed and joined on block exit
```

### Sending (stdin)

```ruby
proctor << "raw bytes"
proctor.puts("line of text")  # adds newline
proctor.close_stdin           # signal EOF
```

### Receiving (stdout/stderr)

```ruby
# Blocking receive (default: line-buffered)
line = proctor.receive

# With timeout (uses timer Ractor internally)
line = proctor.receive(timeout: 5.0)
# => line or raises Proctor::Timeout

# Check without blocking
if proctor.readable?
  line = proctor.receive
end

# Enumerable interface
proctor.each_line do |line|
  process(line)
end
```

### Death Notification

```ruby
# Callback style - fires when process dies
proctor.on_exit do |result|
  puts "Process exited: #{result.exit_code}"
  puts "Signal: #{result.signal}" if result.signaled?
end

# Blocking wait
result = proctor.join
result = proctor.join(timeout: 30.0)

# Check without blocking
proctor.alive?   # => true/false
proctor.exited?  # => true/false
```

### Lifecycle Control

```ruby
proctor.kill(:TERM)
proctor.kill(:KILL)
proctor.stop(timeout: 5.0)  # TERM, wait, KILL if needed
proctor.close_stdin
```

### Result Object

```ruby
class Proctor::Result
  def exit_code    # Integer 0-255, or nil if signaled
  def signal       # Symbol like :TERM, :KILL, or nil
  def success?     # exit_code == 0
  def signaled?    # killed by signal
  def duration     # Float seconds
  def pid          # Integer
end
```

---

## Implementation Plan (Revised)

### Step 1: Minimal Watcher Ractor
Based on spike_c's proven pattern:

- [ ] Watcher Ractor spawns process with `Open3.popen3` internally
- [ ] stdout_thread reads lines, sends `[:stdout, line]` to parent
- [ ] stderr_thread reads lines, sends `[:stderr, line]` to parent
- [ ] death_thread waits on `wait_thr.value`, sends `[:process_died, pid, code]`
- [ ] Command loop receives `[:stdin, data]`, `[:close_stdin]`, `[:kill, sig]`, `[:shutdown]`
- [ ] Test: `cat` echoes input back

### Step 2: Proctor API Wrapper
- [ ] `Proctor.new(cmd, *args)` creates Watcher Ractor
- [ ] `Proctor#<<` sends `[:stdin, data]` to Watcher
- [ ] `Proctor#receive` blocks on inbox port for `[:stdout, line]`
- [ ] `Proctor#join` sends `[:shutdown]`, waits for Watcher, returns Result
- [ ] `Proctor#alive?` checks Watcher status
- [ ] `watcher.monitor(inbox)` for Watcher crash detection
- [ ] Test: full lifecycle with cat

### Step 3: Death Notification
- [ ] Collect `[:process_died, pid, exit_code]` events
- [ ] `Proctor#on_exit` registers callback
- [ ] Callback fired when process_died received
- [ ] Also detect Watcher crash via `:aborted` from monitor
- [ ] Test: process exits normally, callback fires
- [ ] Test: process killed, callback fires with signal info

### Step 4: Timeout Support
Timer Ractor pattern (no native Ractor.select timeout):

- [ ] `receive(timeout:)` spawns timer Ractor
- [ ] Timer sleeps, sends `:timeout` to timer_port
- [ ] `Ractor.select(inbox, timer_port)`
- [ ] Return message or raise `Proctor::Timeout`
- [ ] **Challenge:** Clean up timer Ractor if message arrives first
- [ ] Test: slow process times out correctly

### Step 5: Robustness
- [ ] stderr handling (separate events vs merged)
- [ ] `stop(timeout:)` - TERM, wait, KILL escalation
- [ ] Handle process that ignores SIGTERM
- [ ] Filter closed ports before `Ractor.select` (spike finding)
- [ ] Test: flaky process that sometimes hangs

### Step 6: Ergonomics
- [ ] Block form with auto-cleanup
- [ ] `each_line` enumerable interface
- [ ] Environment and chdir options
- [ ] Integration example with a real CLI tool

---

## Test Cases (Unchanged, but Now Validated by Spikes)

### Happy Path
```ruby
proctor = Proctor.new("cat")
proctor << "hello"
proctor.close_stdin
assert_equal "hello\n", proctor.receive  # Note: cat adds newline
result = proctor.join
assert result.success?
```

### Death Detection
```ruby
proctor = Proctor.new("sleep", "0.1")
exited = false
proctor.on_exit { exited = true }
sleep 0.2
assert exited
```

### Timeout
```ruby
proctor = Proctor.new("sleep", "100")
assert_raises(Proctor::Timeout) do
  proctor.receive(timeout: 0.1)
end
proctor.kill(:KILL)
```

### Crash Detection
```ruby
proctor = Proctor.new("ruby", "-e", "exit 42")
result = proctor.join
assert_equal 42, result.exit_code
refute result.success?
```

### Signal Detection
```ruby
proctor = Proctor.new("sleep", "100")
proctor.kill(:TERM)
result = proctor.join
assert result.signaled?
assert_equal :TERM, result.signal
```

---

## Open Questions (Updated)

### Answered by Spikes

1. ~~**How to detect death?**~~ → `Ractor.monitor(port)` sends `:exited`/`:aborted`
2. ~~**Can we pass IO to Ractors?**~~ → Spawn inside instead, works perfectly
3. ~~**Does Ractor.select have timeout?**~~ → No, use timer Ractor pattern

### Still Open

1. **Timer Ractor cleanup** - If message arrives before timeout, timer Ractor
   keeps running and will send `:timeout` later. Options:
   - Let it complete, discard late `:timeout` messages
   - Track timer Ractors, close their ports on message receipt
   - Timer pool that can be cancelled

2. **Binary/raw mode** - Spikes only tested `.gets` line-by-line. For binary
   protocols, need `.readpartial` or `.read_nonblock`. Add `mode: :raw` option?

3. **Buffer overflow** - What if process writes faster than we read? OS buffers
   are ~64KB. Process blocks on write. Document this? Add internal buffering?

4. **on_exit callback execution** - Currently callbacks would fire in main thread
   when processing messages. Is this the right model? Should there be a
   dedicated callback thread?

5. **Integration with devex** - Can Proctor become foundation for devex `spawn`?
   Need to consider environment stack (dotenv/mise/bundle).

---

## Success Criteria (Unchanged)

Phase 1 is complete when:

1. **Basic bidirectional works** - Can `cat` echo our input back
2. **Death notification works** - `on_exit` callback fires reliably
3. **Timeout works** - Can escape hung processes
4. **Tests pass** - Automated verification of above
5. **Documentation** - Clear examples of usage
6. **Clean code** - Ready for review and iteration

---

## What We Already Learned (From Spikes)

Building the spikes taught us:

1. **Death detection** - `Ractor.monitor` exists and works!
2. **How to multiplex** - `Ractor.select` with timer Ractor for timeout
3. **Architecture** - Spawn inside Ractor, threads for async I/O
4. **Ruby 4.0 API** - `r.value` not `r.take`, `Ractor::Port` is primary
5. **Gotchas** - Closed port in select fails immediately, need filtering

The foundational patterns are proven. Now we wrap them in a clean API.

---

## References

- Spike findings: `spikes/FINDINGS.md`, `spikes/FINDINGS-DETAILS.md`
- Working pattern: `spikes/spike_c_watcher.rb` FINAL test
- Erlang Ports: https://www.erlang.org/doc/tutorial/c_port.html
- Ruby Process: https://ruby-doc.org/core/Process.html
- Ruby Ractor: https://ruby-doc.org/core/Ractor.html
- devex ADR-001: External Commands design
