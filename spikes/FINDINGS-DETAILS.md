# Spike Findings: Detailed Analysis

**Date:** 2025-12-26
**Ruby Version:** 4.0.0 (2025-12-25 revision 553f1675f3) +PRISM [arm64-darwin25]

This document records exactly what was tested, what worked, what failed, and what
assumptions were made. A fresh reader should be able to verify or challenge any conclusion.

---

## Spike A: Ractor Shareability (`spike_a_shareability.rb`)

### Purpose
Explore what objects can cross Ractor boundaries, specifically for passing IO pipes
from Process.spawn to a Ractor.

### Tests Run and Results

#### Baseline: Ruby 4.0 API Discovery

| Test | Description | Result | Output |
|------|-------------|--------|--------|
| B1 | `Ractor.new { 42 }; r.value` | SUCCESS | `42` |
| B2 | `Ractor.new(10) { |x| x * 2 }; r.value` | SUCCESS | `20` |
| B3 | `Ractor::Port.new; port.send("hello"); port.receive` | SUCCESS | `"Sent and received: hello"` |
| B4 | Cross-Ractor via Port (Ractor sends, main receives) | SUCCESS | `"Main received: message from sender"` |
| B5 | `r.default_port.send("msg"); Ractor.receive` inside | SUCCESS | `"Ractor got: via default port"` |

**Confirmed:** Ruby 4.0 API uses `r.value` (not `r.take`), `Ractor::Port` for communication.

#### Q1: Can IO Pipes Cross Ractor Boundaries?

| Test | Description | Result | Output |
|------|-------------|--------|--------|
| 1a | Pass pipe read-end via `Ractor.new(rd)` | SUCCESS | `"Ractor read: hello from pipe"` |
| 1b | Pass pipe via `default_port.send(wr)` | SUCCESS | `"wrote to pipe, main read: from ractor"` |
| 1c | Pipe from `Process.spawn` to Ractor | SUCCESS | `"Ractor got spawn output: hello from spawn"` |
| 1d | **Bidirectional pipes via Ractor.new args** | **TIMEOUT** | Hung for 2s |
| 1d2 | Bidirectional pipes via `Port#send move:true` | SUCCESS | `"Ractor bidirectional: echo this back"` |
| 1e | `Ractor.shareable?(IO.pipe[0])` | SUCCESS | `false` |

**Critical Finding:** Passing IO via `Ractor.new` args works for simple cases but
**HANGS for bidirectional pipes**. Use `port.send(io, move: true)` instead.

**NOT TESTED:**
- What specifically causes the hang in Test 1d (race condition? deadlock?)
- Whether the hang is deterministic or timing-dependent
- Other patterns for bidirectional IO passing

#### Q2: Can Ractor::Port Be Passed Between Ractors?

| Test | Description | Result | Output |
|------|-------------|--------|--------|
| 2a | `Ractor.shareable?(Ractor::Port.new)` | SUCCESS | `true` |
| 2b | Pass Port to Ractor, Ractor sends, main receives | SUCCESS | Works |
| 2c | Multiple Ractors send to same Port | SUCCESS | `"Received: from r1, from r2"` |
| 2d | Ractor tries to receive from Port it didn't create | SUCCESS (error) | `"Error: Ractor::Error - only allowed from the creator Ractor of this port"` |
| 2e | Ractor creates Port, sends to main, main replies | SUCCESS | `"Ractor received: hello from main to ractor's port"` |
| 2f | Pass Port via another Port (Ractor receives from non-owned Port) | SUCCESS (error) | `"Error: Ractor::Error"` |
| 2g | Ractor creates Port, sends to main's port, main sends back | SUCCESS | `"Ractor got: hello to ractor"` |

**Critical Finding:** Only the **creator** Ractor can call `receive` on a Port.
Any Ractor can `send` to any Port.

**NOT TESTED:**
- What happens if creator Ractor dies while Port has pending messages
- Whether Port can be garbage collected while in use by another Ractor
- Memory semantics of Port message queues

#### Q3: What Errors Do We Get With Non-Shareable Objects?

| Test | Description | Result | Output |
|------|-------------|--------|--------|
| 3a | Pass mutable String | SUCCESS | `"got: mutable string"` |
| 3b | Pass mutable Array | SUCCESS | `"got array: [1, 2, 3]"` |
| 3c | Pass mutable Hash | SUCCESS | `"got hash: {key: \"value\"}"` |
| 3d | Pass frozen String | SUCCESS | Works |
| 3e | Pass deeply frozen Array | SUCCESS | Works |
| 3f | Pass custom class instance | SUCCESS | `"got: 42"` |
| 3g | `Ractor.make_shareable` on nested structure | SUCCESS | Works |
| 3h | Shareability survey | SUCCESS | See below |

**Shareability Survey Results:**
```ruby
{
  frozen_string: true,
  mutable_string: false,
  integer: true,
  symbol: true,
  nil: true,
  range_frozen: true,
  range_mutable: true,   # Surprising!
  frozen_array: true,
  ractor: true,
  ractor_port: true,
  proc: false,
  io_pipe: false
}
```

**SURPRISE:** Ruby 4.0 uses **implicit move semantics**. Mutable objects don't fail -
they get moved/copied. This is different from earlier Ractor proposals.

**NOT TESTED:**
- What happens to the original object after it's "moved" (is it still accessible?)
- Whether this is copy or true move
- Performance implications of implicit copying

#### Q4: Move vs Share Semantics for IO

| Test | Description | Result | Output |
|------|-------------|--------|--------|
| 4a | Access IO in main after passing to Ractor | SUCCESS | `"Main could still read: \"t\", Ractor: Ractor read: est data"` |
| 4b | Pass same IO to multiple Ractors | SUCCESS | `["r1 has pipe", "r2 has pipe"]` |
| 4c | Check object_id before/after | SUCCESS | `"Original: 16, After: 16, Ractor pipe id: 24"` |
| 4d | `port.send(io, move: true)` then access original | SUCCESS | `"rd inaccessible after move: Ractor::MovedError"` |

**Critical Finding:** Without `move: true`, **BOTH sender and receiver can access IO!**
Test 4a shows a race condition: main read "t", Ractor read "est data" from same pipe.

**Critical Finding:** With `move: true`, accessing original raises `Ractor::MovedError`.

**Critical Finding:** Same IO CAN be passed to multiple Ractors (Test 4b). This seems
dangerous and may be undefined behavior.

**Assumption:** We should ALWAYS use `move: true` for IO to avoid race conditions.

---

## Spike B: Ractor.select (`spike_b_select.rb`)

### Purpose
Understand multiplexing semantics for implementing `receive(timeout:)`.

### Tests Run and Results

#### Q1: Basic Ractor.select Syntax

| Test | Description | Result |
|------|-------------|--------|
| Select on two Ports | `Ractor.select(port1, port2)` | Returns `[port, message]` |
| Select on Ractor directly | `Ractor.select(r)` | Returns `[ractor, return_value]` when terminated |

**Finding:** `Ractor.select` works with both `Ractor::Port` objects and `Ractor` objects.
Returns `[source, value]` tuple.

#### Q2: Timeout Support

| Test | Description | Result |
|------|-------------|--------|
| `Ractor.select(port, timeout: 1.0)` | Try keyword arg | **FAILS**: `ArgumentError: should be Ractor::Port or Ractor` |
| Timer Ractor pattern | Create Ractor that sleeps then sends | SUCCESS |

**Critical Finding:** **NO native timeout support** in `Ractor.select`.
Must use a timer Ractor pattern:

```ruby
timer_port = Ractor::Port.new
timer = Ractor.new(timer_port, timeout) { |p, t| sleep(t); p.send(:timeout) }
source, msg = Ractor.select(inbox_port, timer_port)
```

**NOT TESTED:**
- Performance overhead of timer Ractor pattern
- How to cleanly cancel timer if message arrives first
- Whether there's a way to interrupt `Ractor.select`

#### Q3: Select Priority/Ordering

| Test | Description | Result |
|------|-------------|--------|
| 3 ports at 0.05s, 0.10s, 0.15s | Check order | Correct order: earliest first |

**Finding:** `Ractor.select` returns results in arrival order.

#### Q4: Closed Port Behavior

| Test | Description | Result |
|------|-------------|--------|
| Select with one closed port | `Ractor.select(open_port, closed_port)` | **FAILS IMMEDIATELY** with `Ractor::ClosedError` |

**Critical Finding:** If ANY port in select is closed, entire select fails immediately.
Must filter out closed ports before calling select.

#### Ractor.monitor Discovery

| Test | Description | Result |
|------|-------------|--------|
| Monitor normal exit | `r.monitor(port); wait; receive` | Receives `:exited` |
| Monitor crash | `r.monitor(port); crash; receive` | Receives `:aborted` |
| Mixed select with monitor | `Ractor.select(msg_port, monitor_port)` | Works! Can multiplex |

**Critical Finding:** `Ractor.monitor(port)` sends `:exited` or `:aborted` to port
when Ractor terminates. CAN be mixed in same `Ractor.select` with message ports.

---

## Spike C: End-to-End Watcher Pattern (`spike_c_watcher.rb`)

### Purpose
Build a complete process watcher with bidirectional messaging and death notification.

### Tests Run and Results

| Test | Description | Result |
|------|-------------|--------|
| 1 | Spawn process inside Ractor with Open3.popen3 | SUCCESS |
| 2 | Ractor owns process, notifies parent of lifecycle | SUCCESS |
| 3 | Multiple processes from single coordinator Ractor | SUCCESS |
| 4 | Command/response pattern ([:write, data], [:close_input]) | SUCCESS |
| 5 | Async with internal threads (stdout_thread, death_thread) | SUCCESS |
| 6 | `Ractor.monitor` for crash detection | SUCCESS (receives `:aborted`) |
| 7 | `Ractor.monitor` for normal exit | SUCCESS (receives `:exited`) |
| FINAL | Complete Shellac pattern | SUCCESS |

### What Worked

1. **Spawning processes INSIDE Ractors with Open3.popen3** - No need to pass FDs
2. **Threads inside Ractors** - Essential for concurrent stdout/stderr reading
3. **`Ractor.monitor(port)`** - Death notification works perfectly
4. **Pattern matching with `in`** - Clean command handling
5. **`Process.kill(signal, pid)` from within Ractor** - Signal handling works
6. **Multiple concurrent reader threads** - stdout and stderr simultaneously
7. **Clean shutdown protocol** - `:shutdown` command, join threads, return

### What Didn't Work (From Earlier Attempts)

1. **Passing IO objects from main to Ractor** - Isolation violation or hangs
2. **`Process.wait2(pid)` in Ractor when process spawned in main** - ECHILD error
3. **Passing Thread objects (Process::Waiter)** - Not shareable
4. **`Ractor.yield`** - Does not exist in Ruby 4.0!
5. **`Ractor.take`** - Replaced by `r.value` in Ruby 4.0

### The Working Architecture

```
Main Ractor
    |
    +-- creates Watcher Ractor (passing self as parent)
    +-- monitors with watcher.monitor(main.default_port)
    |
    +-- sends: [:stdin, data], [:close_stdin], [:kill, sig], [:shutdown]
    +-- receives: [:process_started, pid], [:stdout, line],
    |             [:stderr, line], [:stdout_closed], [:stderr_closed],
    |             [:process_died, pid, exit_code],
    |             :exited (from monitor)

Watcher Ractor
    |-- require 'open3' inside the Ractor
    |-- spawns process with Open3.popen3
    |-- owns all IOs internally (never passed out)
    |-- stdout_thread: reads stdout line by line, sends to parent
    |-- stderr_thread: reads stderr line by line, sends to parent
    |-- death_thread: waits on wait_thr.value, sends to parent
    |-- main loop: Ractor.receive -> case cmd -> write stdin
    |-- on :shutdown: joins all threads, returns :watcher_finished
```

### Example Output From Final Test

```ruby
{
  messages: [
    [:process_started, 49933],
    [:stdout, "hello shellac\n"],
    [:stdout, "goodbye shellac\n"],
    [:stdout_closed],
    [:stderr_closed],
    [:process_died, 49933, 0],
    [:watcher_exited, :exited]
  ],
  final: :watcher_finished
}
```

---

## Assumptions Made

1. **`move: true` is always safe for IO** - Not extensively tested for edge cases
2. **Threads inside Ractors are stable** - Limited testing, worked in all cases tried
3. **`Ractor.monitor` is reliable** - Only tested with simple crash/exit scenarios
4. **Open3.popen3 is thread-safe inside Ractors** - Assumed from stdlib, not verified
5. **Line-by-line reading with `.gets` won't miss data** - May buffer issues with binary

## Not Tested / Open Questions

1. **Binary/raw mode reading** - Only tested line-buffered with `.gets`
2. **Very large outputs** - Buffer behavior with megabytes of output
3. **Interactive processes** - REPLs, shells with prompts
4. **PTY support** - Pseudo-terminal for programs that require it
5. **Signal handling edge cases** - SIGKILL, process groups, zombie cleanup
6. **Timer Ractor cleanup** - Memory leaks if many timeouts are started
7. **Long-running stability** - Hours/days of operation
8. **Memory usage** - Message queue growth, thread accumulation
9. **Error propagation** - What happens if stdout_thread crashes?
10. **Concurrent Shellacs** - Many watchers running simultaneously

## Implications for Shellac Implementation

1. **Process MUST be spawned inside the Ractor** - Cannot receive FDs from outside
2. **Use Open3.popen3** - Works inside Ractors, handles all three streams
3. **Use internal threads** - One for stdout, one for stderr, one for death
4. **Use `Ractor.monitor`** - For detecting watcher Ractor crashes
5. **Timer Ractor for timeouts** - No native timeout in `Ractor.select`
6. **Filter closed ports** - Before calling `Ractor.select`
7. **Line buffering is default** - Consider raw mode option for binary
8. **Pattern matching for commands** - Clean, Ruby 3+ compatible

---

## Ruby 4.0 Ractor API Summary (Different from Earlier Proposals)

| Old API | New API (Ruby 4.0) |
|---------|-------------------|
| `Ractor.take` | `Ractor#value` |
| `Ractor.yield` | Use `port.send` instead |
| Push model | `Ractor::Port` is primary mechanism |
| - | `Ractor#default_port` for incoming |
| - | `Ractor#monitor(port)` for death notification |
| - | `Ractor.recv` reads from default_port |

---

## Reproducibility

All tests can be re-run:

```bash
cd /Users/josephwecker-v2/src/rotp
ruby spikes/spike_a_shareability.rb
ruby spikes/spike_b_select.rb
ruby spikes/spike_c_watcher.rb
```

Each spike has a timeout wrapper to prevent hangs from blocking forever.
