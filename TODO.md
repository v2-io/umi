# Umi TODO

## Priority: Supervision Foundation Spike

The following four cross-cutting issues are deeply interrelated and should be
resolved together in a focused spike session. They all touch on how supervisors
detect death, communicate with children, and integrate with existing code.

### 1. Dead Ractor Identification Problem

`Ractor#monitor(port)` sends only `:exited` or `:aborted` to the port—**not**
which Ractor died. Every document that handles death currently uses:

```ruby
dead = @children.find { |r| !r.alive? }
```

This is:
- **O(n)** per death notification
- **Racy** with concurrent deaths (could match wrong Ractor)
- **Fragile** if `alive?` has timing edge cases

**Spike goals:**
- Confirm this is the actual behavior in Ruby 4.0 (test empirically)
- Explore mitigations:
  - Maintain reverse map (Ractor.object_id → child_id)
  - Serialize death handling (only process one at a time)
  - Request Ruby core enhancement (Ractor identity in notification)
- Document the chosen pattern in `pre.md`
- Update all sketches in plan docs to use the pattern

### 2. Timeout Mechanism Clarification

**Resolved:** `Ractor.select` does NOT have a native timeout parameter. The
`etc.md` coordinator example using `timeout: 0` is incorrect.

**Spike goals:**
- Fix `etc.md` coordinator example to use timer port pattern
- Define canonical timeout utilities in `pre.md`:
  - `select_with_timeout(*ports, timeout:)`
  - `try_receive(port)` (non-blocking, returns nil if empty)
  - `call_with_timeout(port, message, timeout:)`
- Verify timer thread cleanup is safe (`Thread.kill` behavior)
- Document whether lingering timer threads are acceptable or a leak

### 3. Supervisor ↔ Child Protocol Specification

Message protocols between layers are undefined. Need to specify:

**Supervisor → Child:**
- How is `:shutdown` sent? To `default_port`? A dedicated command port?
- Message format: `[:shutdown, timeout_ms]`? Just `:shutdown`?
- What if child doesn't respond within timeout? (force-kill mechanism)

**Child → Supervisor:**
- How does child signal "I'm running"? (for `wait_for_running`)
- How does child send checkpoints? Same port as death notifications?

**Application → Coordinator:**
- How does application signal "running" after supervisor starts?
- What ports does coordinator provide to applications?

**Spike goals:**
- Design minimal protocol for supervisor ↔ child
- Implement in a test supervisor + test worker
- Document protocol in `sup.md` and `rac.md`
- Ensure protocol works with existing Proctor (see #4)

### 4. Proctor Supervision Integration

Proctor already exists with an internal Watcher Ractor. How does external
supervision compose with this?

**The three options from rac.md:**
1. Supervisor monitors the Proctor Ractor (not the OS process directly)
2. Proctor notifies supervisor when OS process dies
3. Both—defense in depth

**Spike goals:**
- Review Proctor internals (`lib/umi/proctor.rb`)
- Determine which option aligns with Proctor's current design
- Implement supervision of a Proctor in a test supervisor
- Verify death detection works correctly (OS process death → supervisor notified)
- Document the chosen pattern
- Ensure Proctor responds to the shutdown protocol from #3

---

## Remaining Decisions

_These can be addressed individually after the supervision foundation is solid._

1. **Linking question is moot** — `pre.md` confirms Ruby 4.0 has no linking
   primitive. Remove or reframe the "linking vs monitoring" open question in
   `rac.md`. Answer: only monitoring exists; mutual death must be simulated
   via bidirectional monitoring if needed.

2. **Rollback semantics on boot failure** — If application B fails to start,
   what happens to already-started application A? Options:
   - Stop A (true atomic boot)
   - Leave A running (partial boot, degraded state)
   - Configurable per-application

   This affects coordinator implementation. Decide before implementing boot
   sequence.

3. **Registration ownership** — Does the worker self-register in `init`, or
   does the supervisor register it after `start_link` returns? Implications:
   - Self-registration: worker controls its name, but race with restart
   - Supervisor registration: supervisor controls name, cleaner restart
   - Deregistration: who calls `Registry.unregister` on shutdown?

   Decide and document in `rac.md` and `reg.md`.

4. **Health check mechanism** — Needed for external supervision (systemd, k8s).
   Options:
   - HTTP endpoint (requires HTTP server—heavyweight)
   - TCP socket (simple connect test)
   - Unix socket
   - File touch (write timestamp to file)

   Decide and document. Consider: should this be a kernel Ractor or application
   responsibility?

5. **Define standard utility patterns** — After spike resolves timeout patterns,
   add to `pre.md`:
   - `select_with_timeout`
   - `try_receive` (non-blocking receive)
   - `call_with_timeout` (request-response with timeout)
   - Possibly `with_deadline` (deadline-based timeout tracking)

6. **Consolidate Ruby Box content** — `ini.md` and `app.md` have near-duplicate
   Box sections. Consolidate into one location (probably `pre.md` since Box is
   a primitive) and cross-reference from other docs.

---

## Notes

- Individual plan documents (`docs/plan/*.md`) have "Review Concerns" sections
  with document-specific issues. Those should be resolved when implementing
  each layer.

- The supervision foundation spike should produce working code in `spikes/`
  that validates the patterns before they're promoted to `lib/umi/`.
