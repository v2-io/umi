# ETC: Future Enhancements

Patterns and capabilities that build on top of the core architecture. Not
required for a working system, but valuable for production robustness.

---

## Strategic Checkpointing

OTP's "let it crash" means losing in-flight state—the process restarts fresh.
For many use cases this is fine. But production systems often need:

- **Retry capability**: Don't lose the request that was in progress
- **Idempotency**: Don't redo work that already succeeded
- **Debuggability**: Understand what state led to a crash

### The Core Insight

Ruby can achieve capturable/restorable state without Erlang-style immutability:

- State typically lives in instance variables (not scattered randomly)
- Ruby has reflection (`instance_variables`, `instance_variable_get/set`)
- Marshal can serialize most pure-data objects
- Strategic checkpointing avoids continuous overhead

The question isn't "how do we capture all state changes" but **"when does a
snapshot have high value?"**

### Risk-Stratified Checkpointing

Not all code is equally dangerous:

**High-risk operations** (checkpoint around these):
- External HTTP/database calls
- Subprocess interaction (Proctor's domain)
- File I/O, network operations
- Parsing untrusted input

**Low-risk operations** (no checkpoint needed):
- Waiting for messages (idle)
- Pure computation on in-memory state
- Pattern matching, dispatching

### Strategic Checkpoint Moments

```
  Message arrives
       │
       ▼
   ┌───────┐
   │ [CP1] │  Before processing - enables clean abandon on failure
   └───────┘
       │
       ▼
   ┌───────┐
   │ [CP2] │  Before risky operation - enables retry if call fails
   └───────┘
       │
       ▼
   ═══════════ DANGER ZONE (external call) ═══════════
       │
       ▼
   ┌───────┐
   │ [CP3] │  After success - prevents redoing completed work
   └───────┘
       │
       ▼
  Back to idle
```

### Two Types of Snapshots

**Recovery Snapshots ("Last Known Good")**

Taken at strategic success points. Used to restore a restarted worker.

```ruby
result = risky_external_call()
checkpoint!(:recovery)  # We succeeded—don't redo this on restart
update_state_with(result)
```

Properties:
- State is consistent and valid
- Safe to resume from here
- Taken AFTER successful operations

**Diagnostic Snapshots ("Failure State")**

Taken at moment of failure. Used for debugging, not recovery.

```ruby
rescue => e
  checkpoint!(:diagnostic)  # What was state when we crashed?
  raise
end
```

Properties:
- State may be inconsistent or corrupted
- Useful for debugging, not for restarting
- Taken IN exception handlers

**Why both?** If we only had diagnostic, we might restore to corrupted state.
If we only had recovery, we'd lose insight into what failed.

### Is Exception-Handler Checkpointing Too Heavy?

Usually no, for typical workers:

| Factor | Concern | Typical Reality |
|--------|---------|-----------------|
| State size | Big state = slow | Most workers have small state (KB, not MB) |
| Serialization | Marshal overhead | Microseconds for simple objects |
| Storage | Disk I/O | Can store in memory (supervisor holds it) |
| Frequency | Every exception? | Exceptions should be rare in healthy systems |

For very large state, capture selectively:

```ruby
rescue => e
  @failure_context = {
    exception: e.class.name,
    message: e.message,
    backtrace: e.backtrace.first(10),
    request_id: @current_request_id,
    operation: @current_operation
  }
  raise
end
```

### Implementation Sketch

**Explicit checkpointing:**

```ruby
class Umi::Worker
  def checkpoint!(type = :recovery)
    snapshot = capture_state
    case type
    when :recovery
      @supervisor_port << [:checkpoint, self.id, snapshot]
    when :diagnostic
      @last_diagnostic = snapshot
    end
  end

  def capture_state
    instance_variables.each_with_object({}) do |var, hash|
      value = instance_variable_get(var)
      next if var.to_s.start_with?('@_')  # Skip internal
      next unless marshalable?(value)
      hash[var] = value
    end
  end
end
```

**Declarative risky operations:**

```ruby
class MyWorker < Umi::Worker
  extend Umi::RiskyOperation

  risky def call_external_api(data)
    # Auto-checkpoints before, after, and on exception
    http.post(url, data)
  end
end
```

**Supervisor-side handling:**

```ruby
def handle_child_exit(child_id, reason, diagnostic_snapshot)
  recovery_snapshot = @last_recovery_snapshots[child_id]

  # Restart from last known good state
  new_child = start_child(child_id, from: recovery_snapshot)

  # Log diagnostic for debugging
  if diagnostic_snapshot
    Logger.error("Child #{child_id} failed", state: diagnostic_snapshot)
  end
end
```

### Implications for Proctor

Every Proctor interaction is a risky operation:

| Moment | Checkpoint Value |
|--------|------------------|
| Process spawned | Initial state captured |
| Before stdin write | Can retry send on failure |
| After stdin write | Know what was sent |
| After stdout read | Have the response |
| Process exits | Capture exit status + buffered output |

---

## Process Groups

Registry gives 1:1 (name → ractor). Sometimes you need 1:N (name → [ractors]).

```ruby
# All workers in a pool
Groups.members(:worker_pool) → [ractor1, ractor2, ractor3]

# Broadcast to all
Groups.broadcast(:worker_pool, message)

# Send to one (round-robin or random)
Groups.notify(:worker_pool, message)
```

This builds on Registry—a separate abstraction for group membership and
messaging patterns.

---

## Adaptive Backpressure

Beyond simple "wait for response" backpressure, Elixir's Logger demonstrates
adaptive mode switching:

```
messages >= discard_threshold → :discard (drop messages)
messages >= sync_threshold   → :sync    (wait for response)
otherwise                    → :async   (fire-and-forget)
```

This lets high-throughput components stay fast under normal load but
automatically slow down (or shed load) when overwhelmed.

Implementation would involve:
- Queue depth monitoring
- Mode switching thresholds
- Graceful transitions between modes

---

## Distribution

The analysis in `beam-otp-analysis.md` covers BEAM's distribution architecture:
- Discovery (EPMD)
- Connection setup (net_kernel)
- Message transport (VM runtime)
- Full mesh topology
- Phoenix Tracker's CRDT-based presence

This is complex machinery. Single-process resilience should be solid before
considering multi-node distribution.

If/when distribution becomes relevant:
- Start with simple patterns (explicit connections, not auto-mesh)
- Consider CRDTs for eventually-consistent shared state
- Study Phoenix Tracker's delta-replication approach

---

## References

- [strategic-checkpointing.md](../strategic-checkpointing.md) - Full checkpointing analysis
- [beam-otp-analysis.md](../beam-otp-analysis.md) - Distribution architecture
- [otp-principles-abstract.md](../otp-principles-abstract.md) - Process groups (Layer 6)
