# Strategic Checkpointing for Crash Recovery

This document explores when and how to snapshot worker state for crash recovery,
focusing on strategic moments rather than continuous capture.

---

## Table of Contents

1. [The Core Insight](#the-core-insight)
2. [Failure Modes of a Worker](#failure-modes-of-a-worker)
3. [Strategic Checkpoint Moments](#strategic-checkpoint-moments)
4. [Two Types of Snapshots](#two-types-of-snapshots)
5. [Exception Handler Snapshots](#exception-handler-snapshots)
6. [Implementation Approaches](#implementation-approaches)
7. [Implications for Proctor](#implications-for-proctor)

---

## The Core Insight

BEAM's advantage isn't really about immutability—it's about **state being capturable
and restorable**. Ruby can achieve the same outcome through different means:

- State typically lives in instance variables (not scattered randomly)
- Ruby has reflection (`instance_variables`, `instance_variable_get/set`)
- Marshal can serialize most pure-data objects
- Strategic checkpointing avoids continuous overhead

The question isn't "how do we capture all state changes" but **"when does a
snapshot have high value?"**

---

## Failure Modes of a Worker

Not all moments are equally risky:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Worker Lifecycle                                                           │
│                                                                             │
│    INIT ──────> IDLE ──────> PROCESSING ──────> IDLE ──────> ...           │
│      │            │              │                                          │
│      │            │              ├── pure computation (rarely fails)        │
│      │            │              ├── external call (often fails) ◄────      │
│      │            │              ├── subprocess I/O (often fails) ◄────     │
│      │            │              └── resource exhaustion (sometimes)        │
│      │            │                                                         │
│      │            └── timeout waiting (rare)                                │
│      └── bad config (fails fast, on purpose)                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**High-risk operations:**
- External HTTP/database calls
- Subprocess interaction (Proctor's domain)
- File I/O, network operations
- Parsing untrusted input

**Low-risk operations:**
- Waiting for messages (idle)
- Pure computation on in-memory state
- Pattern matching, dispatching

**Implication**: Checkpoint around the risky operations, not continuously.

---

## Strategic Checkpoint Moments

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   Message      ┌─────────────────────────────────────────┐                 │
│   arrives      │           PROCESSING                    │                 │
│      │         │                                         │                 │
│      ▼         │  ┌─────────────────────────────────┐   │                 │
│  ┌───────┐     │  │ 1. Parse/validate message       │   │                 │
│  │ [CP1] │ ◄───┼──│    (usually safe)               │   │                 │
│  └───────┘     │  └─────────────────────────────────┘   │                 │
│                │                 │                       │                 │
│                │                 ▼                       │                 │
│                │  ┌─────────────────────────────────┐   │                 │
│  ┌───────┐     │  │ 2. Prepare for external call    │   │                 │
│  │ [CP2] │ ◄───┼──│    (CHECKPOINT BEFORE RISK)     │   │                 │
│  └───────┘     │  └─────────────────────────────────┘   │                 │
│                │                 │                       │                 │
│                │                 ▼                       │                 │
│                │  ┌─────────────────────────────────┐   │                 │
│                │  │ 3. External call / subprocess   │   │                 │
│                │  │    ════════ DANGER ZONE ════════│   │                 │
│                │  └─────────────────────────────────┘   │                 │
│                │                 │                       │                 │
│                │                 ▼                       │                 │
│  ┌───────┐     │  ┌─────────────────────────────────┐   │                 │
│  │ [CP3] │ ◄───┼──│ 4. Process result, update state │   │                 │
│  └───────┘     │  │    (CHECKPOINT AFTER SUCCESS)   │   │                 │
│                │  └─────────────────────────────────┘   │                 │
│                │                 │                       │                 │
│                └─────────────────┼───────────────────────┘                 │
│                                  ▼                                          │
│                            Back to IDLE                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Checkpoint Value by Moment

| Checkpoint | When | Value | Enables |
|------------|------|-------|---------|
| **CP1: Before processing** | Message received, validated | Consistent pre-work state | Abandon message cleanly on failure |
| **CP2: Before risky op** | About to call external service | Retry capability | Restore and retry if call fails |
| **CP3: After success** | External call succeeded | Idempotency | Don't redo work that succeeded |
| **After message complete** | Back to idle | Clean inter-request state | Restart between requests |
| **On exception** | Failure detected | Debug info | Understand what went wrong |

---

## Two Types of Snapshots

Snapshots serve different purposes:

### 1. Recovery Snapshots ("Last Known Good")

Taken at strategic success points. Used to restore a restarted worker.

```ruby
def handle_message(msg)
  # ... process ...

  result = risky_external_call()

  # We succeeded! Checkpoint so we don't redo this.
  checkpoint!(:recovery)

  update_state_with(result)
end
```

**Properties:**
- State is consistent and valid
- Safe to resume from here
- Taken AFTER successful operations

### 2. Diagnostic Snapshots ("Failure State")

Taken at moment of failure. Used for debugging, not recovery.

```ruby
def handle_message(msg)
  # ...
rescue => e
  checkpoint!(:diagnostic)  # What was state when we crashed?
  raise
end
```

**Properties:**
- State may be inconsistent or corrupted
- Useful for debugging, not for restarting
- Taken IN exception handlers

### Why Both?

```
Timeline:
  ─────────────────────────────────────────────────────────────>

  [CP:recovery]          [risky op]           [crash!]
       │                     │                    │
       │                     │                    └─ [CP:diagnostic]
       │                     │                       "what went wrong?"
       │                     │
       └─────────────────────┴─ Restart from here
                                "last known good"
```

If we only had the diagnostic snapshot, we might restore to a corrupted state.
If we only had the recovery snapshot, we'd lose insight into what failed.

---

## Exception Handler Snapshots

### Is it too heavy to snapshot in an exception handler?

**Short answer**: Usually no, for typical workers.

**Factors:**

| Factor | Concern | Typical Reality |
|--------|---------|-----------------|
| State size | Big state = slow | Most workers have small state (KB, not MB) |
| Serialization | Marshal overhead | Fast for simple objects (hashes, arrays, strings) |
| Storage | Disk I/O | Can store in memory (supervisor holds it) |
| Frequency | Every exception? | Exceptions should be rare in healthy systems |

**Benchmark intuition:**
```ruby
# Marshal.dump for typical worker state
state = { counter: 42, cache: { a: 1, b: 2 }, buffer: "x" * 1000 }
Marshal.dump(state)  # ~microseconds for KB-sized state
```

### When it might be too heavy:

1. **Very large state** - Multi-MB caches or buffers
2. **Non-serializable objects** - Would fail, not just be slow
3. **Exceptions in tight loops** - But those are bugs, not normal operation
4. **Deeply nested objects** - Marshal traverses everything

### Recommended approach:

```ruby
def handle_message(msg)
  # ... work ...
rescue => e
  # Only snapshot if state is reasonably sized
  if capturable?
    @failure_snapshot = capture_state
    @failure_exception = e
    @failure_backtrace = e.backtrace
  end
  raise
end

def capturable?
  # Heuristic: don't try to snapshot huge state
  estimated_size < MAX_SNAPSHOT_SIZE
end
```

### Alternative: Capture selectively

```ruby
rescue => e
  @failure_context = {
    exception: e.class.name,
    message: e.message,
    backtrace: e.backtrace.first(10),
    # Only capture essential state, not everything
    request_id: @current_request_id,
    operation: @current_operation,
    partial_result: @partial_result
  }
  raise
end
```

This is lighter than full state capture but still useful for debugging.

---

## Implementation Approaches

### Explicit Checkpointing

```ruby
class Umi::Worker
  def checkpoint!(type = :recovery)
    snapshot = capture_state
    case type
    when :recovery
      @supervisor_port.send([:checkpoint, self.id, snapshot])
    when :diagnostic
      @last_diagnostic = snapshot
    end
  end

  def capture_state
    instance_variables.each_with_object({}) do |var, hash|
      value = instance_variable_get(var)
      # Skip non-serializable or internal variables
      next if var.to_s.start_with?('@_')
      next unless marshalable?(value)
      hash[var] = value
    end
  end

  def restore_state(snapshot)
    snapshot.each do |var, value|
      instance_variable_set(var, value)
    end
  end
end
```

### Declarative Checkpointing

```ruby
class MyWorker < Umi::Worker
  # Checkpoint at these moments
  checkpoint after: :handle_message      # After each message
  checkpoint before: :call_external_api  # Before risky op
  checkpoint after: :call_external_api   # After risky op succeeds

  # Or mark risky operations (implies before + after)
  risky_operation :call_external_api
  risky_operation :write_to_subprocess
end
```

### Automatic for Risky Operations

```ruby
module Umi::RiskyOperation
  def risky(name)
    original = instance_method(name)

    define_method(name) do |*args, &block|
      checkpoint!(:before_risky)
      result = original.bind(self).call(*args, &block)
      checkpoint!(:after_risky)
      result
    rescue => e
      checkpoint!(:diagnostic)
      raise
    end
  end
end

class MyWorker < Umi::Worker
  extend Umi::RiskyOperation

  risky def call_external_api(data)
    # This method now auto-checkpoints
    http.post(url, data)
  end
end
```

### Supervisor-Side Handling

```ruby
class Umi::Supervisor
  def handle_child_exit(child_id, reason, diagnostic_snapshot)
    recovery_snapshot = @last_recovery_snapshots[child_id]

    case @restart_policy
    when :restore
      # Restart from last known good state
      new_child = start_child(child_id, from: recovery_snapshot)
    when :fresh
      # Restart from scratch
      new_child = start_child(child_id)
    end

    # Log diagnostic for debugging
    if diagnostic_snapshot
      Logger.error("Child #{child_id} failed",
        state: diagnostic_snapshot,
        reason: reason)
    end
  end
end
```

---

## Implications for Proctor

Proctor wraps external processes—every interaction is a risky operation.

### Strategic checkpoints for Proctor:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Proctor Lifecycle                                                          │
│                                                                             │
│    1. Spawn process                                                         │
│       └── [CP] Process spawned, initial state                              │
│                                                                             │
│    2. Send to stdin                                                         │
│       └── [CP before] About to send                                        │
│       └── [CP after] Send succeeded                                        │
│                                                                             │
│    3. Read from stdout/stderr                                               │
│       └── [CP after] Read succeeded, have response                         │
│                                                                             │
│    4. Process exits                                                         │
│       └── [CP] Capture exit status and any buffered output                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### What Proctor state to capture:

```ruby
class Umi::Proctor
  def capturable_state
    {
      # Process info
      command: @command,
      pid: @pid,
      status: @status,

      # Buffered I/O (might be important for recovery)
      pending_stdin: @pending_stdin,
      buffered_stdout: @buffered_stdout,
      buffered_stderr: @buffered_stderr,

      # Request tracking
      current_request: @current_request,
      request_sent_at: @request_sent_at
    }
  end
end
```

### Recovery scenarios:

| Failure | Recovery Snapshot | Action |
|---------|-------------------|--------|
| Process died | Last successful I/O | Restart process, maybe replay last request |
| Send failed | Before send | Retry send |
| Read timeout | After send | Decide: wait more, or restart process |
| Proctor crashed | Any checkpoint | Supervisor restarts Proctor, restores state |

---

## Summary

### Key Principles

1. **Checkpoint strategically**, not continuously
2. **Before risky operations** enables retry
3. **After successful operations** prevents redo
4. **Two types**: Recovery (for restart) vs Diagnostic (for debugging)
5. **Exception handler snapshots** are usually acceptable for typical state sizes
6. **Instance variables** provide a natural capture boundary in Ruby

### For Umi

The framework should:
- Provide `checkpoint!` primitive
- Support declarative `risky_operation` marking
- Supervisor manages recovery snapshots
- Optional diagnostic snapshots on failure
- Document the pattern, don't enforce immutability

### Related Documents

- [otp-principles-abstract.md](./otp-principles-abstract.md) - Supervision architecture
- [genserver-analysis.md](./genserver-analysis.md) - Worker patterns
- [worker-patterns.md](./worker-patterns.md) - Task, Pool, DynamicSupervisor
