# Phase 1 Pilot: Shellac

**Status:** Planning
**Date:** 2025-12-26

## What Is Shellac?

Shellac transforms a long-lived external process into a Ractor-citizen with:
- **Bidirectional messaging** - stdin/stdout as send/receive
- **Death notification** - linked lifecycle, no polling required
- **Isolation** - process crashes become messages, not Ruby crashes

Think of it as: "Erlang ports for Ruby 4.0"

```ruby
# Vision
shellac = ROTP::Shellac.new("redis-server", "--port", "6379")

# Bidirectional communication
shellac << "PING\r\n"
response = shellac.receive  # => "PONG\r\n"

# Death notification (non-blocking)
shellac.on_exit { |status| log "Redis died: #{status}" }

# Or blocking wait
result = shellac.join  # => Shellac::Result
```

---

## Why Start Here?

1. **Solves a real problem** - Joseph's devex gem needs better subprocess management
2. **Forces the hard questions** - Death detection is the core unsolved primitive
3. **Concrete and testable** - External processes are observable
4. **Addresses #1 killer** - Integration Points (from Release It!)
5. **Pattern transfers** - What we learn applies to Ractor supervision

---

## Design Constraints

### From Ruby 4.0 Ractors
- Objects crossing Ractor boundaries must be shareable (frozen) or moved
- Ractor::Port provides named mailboxes
- Ractor.select enables multiplexed waiting with timeout
- No built-in process linking

### From the Problem Domain
- External processes communicate via stdin/stdout/stderr
- They signal completion via exit codes and signals
- They can hang, crash, or produce unbounded output
- We need timeout capability at every layer

### From Ruby Philosophy
- Blocks for configuration
- Duck typing over rigid interfaces
- Composition over inheritance
- Explicit over implicit

---

## Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────┐
│                    User Code                             │
│   shellac = Shellac.new("cmd"); shellac << msg          │
└─────────────────────────┬───────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────┐
│                  Shellac (API)                           │
│   - new/start                                            │
│   - send (<<)                                            │
│   - receive                                              │
│   - on_exit                                              │
│   - join                                                 │
│   - kill                                                 │
└─────────────────────────┬───────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────┐
│              Watcher Ractor                              │
│   - Owns the OS process (pid)                            │
│   - Runs Process.wait2 in background                     │
│   - Posts to exit_port when process dies                 │
│   - Handles stdin/stdout/stderr pipes                    │
└─────────────────────────┬───────────────────────────────┘
                          │
                    ┌─────┴─────┐
                    │ OS Process │
                    │ (the cmd)  │
                    └───────────┘
```

### Message Flow

```
User           Shellac         Watcher Ractor       OS Process
  │                │                  │                  │
  │── new(cmd) ───▶│                  │                  │
  │                │── spawn ────────▶│                  │
  │                │                  │── Process.spawn ▶│
  │                │                  │                  │
  │── << msg ─────▶│                  │                  │
  │                │── write_port ───▶│                  │
  │                │                  │── stdin.write ──▶│
  │                │                  │                  │
  │                │                  │◀── stdout ───────│
  │                │◀── read_port ────│                  │
  │◀── receive ────│                  │                  │
  │                │                  │                  │
  │                │                  │    (process dies)│
  │                │                  │◀── wait2 ────────│
  │                │◀── exit_port ────│                  │
  │◀── on_exit ────│                  │                  │
```

---

## API Design

### Creation

```ruby
# Basic
shellac = ROTP::Shellac.new("redis-server")

# With arguments
shellac = ROTP::Shellac.new("ffmpeg", "-i", input, "-o", output)

# With options
shellac = ROTP::Shellac.new("server",
  env: { "PORT" => "3000" },
  chdir: "/app",
  stderr: :merge,        # merge stderr into stdout stream
  line_buffered: true    # receive line-by-line instead of chunks
)

# Block form (auto-cleanup)
ROTP::Shellac.open("redis-server") do |redis|
  redis << "PING\r\n"
  puts redis.receive
end  # automatically killed and joined on block exit
```

### Sending (stdin)

```ruby
# Send bytes
shellac << "raw bytes"
shellac.send("explicit send")

# Send with newline (convenience)
shellac.puts("line of text")
```

### Receiving (stdout/stderr)

```ruby
# Blocking receive
data = shellac.receive

# With timeout
data = shellac.receive(timeout: 5.0)
# => data or raises Shellac::Timeout

# Non-blocking check
if shellac.readable?
  data = shellac.receive
end

# Enumerable interface
shellac.each_line do |line|
  process(line)
end
```

### Death Notification

```ruby
# Callback style (non-blocking)
shellac.on_exit do |result|
  puts "Process exited: #{result.exit_code}"
  puts "Signal: #{result.signal}" if result.signaled?
end

# Blocking wait
result = shellac.join
result = shellac.join(timeout: 30.0)

# Check without blocking
shellac.alive?   # => true/false
shellac.exited?  # => true/false
```

### Lifecycle Control

```ruby
# Signals
shellac.kill(:TERM)
shellac.kill(:INT)
shellac.kill(:KILL)

# Graceful shutdown (TERM, wait, KILL if needed)
shellac.stop(timeout: 5.0)

# Close stdin (signal EOF to process)
shellac.close_stdin
```

### Result Object

```ruby
class Shellac::Result
  def exit_code    # Integer 0-255, or nil if signaled
  def signal       # Symbol like :TERM, :KILL, or nil
  def success?     # exit_code == 0
  def signaled?    # killed by signal
  def duration     # Float seconds
  def pid          # Integer
end
```

---

## Implementation Plan

### Step 1: Minimal Viable Shellac
- [ ] `Shellac.new(cmd, *args)` spawns process
- [ ] `Shellac#<<` writes to stdin
- [ ] `Shellac#receive` reads from stdout (blocking)
- [ ] `Shellac#join` waits for exit, returns Result
- [ ] `Shellac#alive?` checks if still running
- [ ] Basic test with a simple command like `cat`

### Step 2: Death Notification
- [ ] Watcher Ractor that runs `Process.wait2`
- [ ] Exit port for death notifications
- [ ] `Shellac#on_exit` callback registration
- [ ] Test: process exits normally, callback fires
- [ ] Test: process killed, callback fires with signal

### Step 3: Timeout Support
- [ ] `Shellac#receive(timeout:)` using Ractor.select
- [ ] `Shellac#join(timeout:)`
- [ ] `Shellac::Timeout` exception
- [ ] Test: slow process times out correctly

### Step 4: Robustness
- [ ] stderr handling (separate stream vs merged)
- [ ] Line buffering option
- [ ] Graceful shutdown with `stop(timeout:)`
- [ ] Handle process that ignores SIGTERM
- [ ] Test: flaky process that sometimes hangs

### Step 5: Ergonomics
- [ ] Block form with auto-cleanup
- [ ] Enumerable interface for output
- [ ] Environment and chdir options
- [ ] Integration example with a real CLI tool

---

## Test Cases

### Happy Path
```ruby
# Echo test
shellac = Shellac.new("cat")
shellac << "hello"
shellac.close_stdin
assert_equal "hello", shellac.receive
result = shellac.join
assert result.success?
```

### Death Detection
```ruby
# Process exits on its own
shellac = Shellac.new("sleep", "0.1")
exited = false
shellac.on_exit { exited = true }
sleep 0.2
assert exited
```

### Timeout
```ruby
# Process that never responds
shellac = Shellac.new("sleep", "100")
assert_raises(Shellac::Timeout) do
  shellac.receive(timeout: 0.1)
end
shellac.kill(:KILL)
```

### Crash Detection
```ruby
# Process that crashes
shellac = Shellac.new("ruby", "-e", "exit 42")
result = shellac.join
assert_equal 42, result.exit_code
refute result.success?
```

### Signal Detection
```ruby
# Process killed by signal
shellac = Shellac.new("sleep", "100")
shellac.kill(:TERM)
result = shellac.join
assert result.signaled?
assert_equal :TERM, result.signal
```

---

## Open Questions

1. **How to handle stderr?**
   - Separate stream (more control, more complexity)
   - Merged with stdout (simpler, loses distinction)
   - Configurable per-shellac

2. **What if stdout fills up faster than we read?**
   - OS buffers are finite (~64KB typically)
   - Process can block on write
   - Need to document this or add buffering

3. **How granular should receive be?**
   - Raw bytes (simple but awkward for line protocols)
   - Line-buffered (convenient but assumes text)
   - Configurable

4. **Should on_exit callbacks run in the Watcher Ractor or main?**
   - In Watcher: isolated, but can't access main state
   - In main: convenient, but blocks main thread
   - Via another port to main Ractor?

5. **Integration with devex?**
   - Can `Shellac` become the foundation for `spawn`?
   - How does environment stack (dotenv/mise/bundle) interact?

---

## Success Criteria

Phase 1 is complete when:

1. **Basic bidirectional works** - Can `cat` echo our input back
2. **Death notification works** - `on_exit` callback fires reliably
3. **Timeout works** - Can escape hung processes
4. **Tests pass** - Automated verification of above
5. **Documentation** - Clear examples of usage
6. **Clean code** - Ready for review and iteration

---

## What We'll Learn

Building Shellac will teach us:

1. **How to detect death** - The `Process.wait2` in a Ractor pattern
2. **How to multiplex** - Ractor.select for timeout + multiple sources
3. **How to structure supervision** - The Watcher pattern
4. **What's hard** - Where Ruby 4.0 Ractors have rough edges
5. **What generalizes** - Patterns that apply to Ractor supervision

This is foundational work. Get it right here, and ROTP has solid ground to build on.

---

## References

- Erlang Ports: https://www.erlang.org/doc/tutorial/c_port.html
- Ruby Process: https://ruby-doc.org/core/Process.html
- Ruby Ractor: https://ruby-doc.org/core/Ractor.html
- devex ADR-001: External Commands design
