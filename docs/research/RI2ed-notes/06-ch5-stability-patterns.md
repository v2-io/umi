# Chapter 5: Stability Patterns — Reflections for Umi

This is the heart of the book. Twelve patterns that counter the twelve antipatterns. Every one has direct relevance to Umi.

## Pattern Catalog

### 1. Timeouts — "Hope Is Not a Design Method"

> "Your code can't just wait forever for a response that might never come."

The fundamental defense. Every blocking operation needs a timeout. The cost is complexity—"half your code devoted to error handling"—but the benefit is resilience.

**For Umi:** This is why the planning documents emphasize the timer port pattern. `Ractor.select` has no native timeout, so every select must use a timer thread. This isn't optional overhead; it's the foundation of stability.

**Key insight:** Timeout + retry is often worse than timeout alone. Fast retries probably hit the same problem. Either fail fast to the caller, or queue for slow retry later.

**Umi implication:** Should `call_with_timeout` default to failing fast, or should it queue for retry? Probably fail fast—let the caller decide whether to retry. But the option to queue should exist.

### 2. Circuit Breaker — "Don't Do It If It Hurts"

State machine: Closed → (failures exceed threshold) → Open → (timeout) → Half-Open → (probe succeeds) → Closed

When something is failing, stop calling it. This prevents waste (calling something that will fail) and gives the failing system time to recover.

**For Umi:** Circuit breakers wrap integration points. Proctor wraps external processes—should Proctor have built-in circuit breaker support? If the subprocess crashes repeatedly, stop trying to call it.

More interesting: **supervisors are a form of circuit breaker.** When a child crashes too often (restart bounding), the supervisor "trips" and stops restarting. The escalation to the parent is like opening the circuit.

**Key insight:** Circuit breaker state should be per-process, not shared across processes. Sharing introduces a new integration point (and failure mode). In Umi terms: per-Ractor circuit breakers, not system-wide.

### 3. Bulkheads — "Save Part of the Ship"

Partition capacity to preserve partial functionality. Physical redundancy, thread pool partitioning, dedicated server pools for critical functions.

**For Umi:** Ractors are natural bulkheads. Each Ractor is isolated—a failure in one doesn't automatically affect others. The supervision tree provides organizational bulkheads—failures in one subtree don't affect siblings.

**Key insight:** Pick a useful granularity. You can partition at many levels: Ractors, worker pools, supervisors, applications. Too fine-grained wastes resources; too coarse-grained doesn't protect.

**The airline lesson:** If the airline had separate CF instances for kiosks vs. web, the kiosks would have kept working. Bulkheads trade efficiency for resilience.

### 4. Steady State — "Avoid Fiddling"

Systems should run without human intervention for at least one release cycle. Every mechanism that accumulates resources needs a corresponding mechanism to recycle them.

**The Buckets:**
- Data: purge old rows, or they accumulate forever
- Logs: rotate and delete, or they fill the disk
- Caches: limit size and invalidate, or they consume all memory

**For Umi:** What accumulates in an Umi system?
- Port message queues (unbounded by default)
- Supervisor restart counts (should decay over time)
- Worker state (if workers live long)
- Registry entries (if workers die without deregistration)

**Umi implication:** Consider providing bounded port queues (or monitoring for unbounded ones). Consider time-decay for restart counts (the "leaky bucket" algorithm). Consider TTL for registry entries.

### 5. Fail Fast — "Don't Waste Work"

If you can tell in advance that an operation will fail, fail immediately. Check prerequisites before starting work (*mise en place*).

**For Umi:** A worker that receives a message could check circuit breaker state before processing. If the integration point it needs is open, reject the message immediately.

**Key distinction:** System failures vs. application failures. A popped circuit breaker is a system failure. Bad input is an application failure. Report them differently so upstream systems don't trip their circuit breakers just because users submit bad data.

### 6. Let It Crash — "Crash Components to Save Systems"

The OTP philosophy, explicitly named. Nygard's four requirements:

1. **Limited granularity:** Crash a component, not the whole system
2. **Fast replacement:** Get back to clean state quickly
3. **Supervision:** Someone monitors and restarts crashed components
4. **Reintegration:** Restarted components rejoin the system automatically

**This is Umi's core value proposition.**

Ractors provide granularity. Supervision provides restart and reintegration. The question is: how fast is replacement?

**Key insight:** "The supervisor is *not* the service consumer. Managing the worker is different than requesting work."

This is why Umi separates supervision from communication. The supervisor monitors and restarts; callers send messages through ports. They're orthogonal concerns.

**Warning:** "Don't crash monoliths." Large processes with heavy runtimes aren't suitable for let-it-crash. Umi workers should be lightweight—fast to start, cheap to replace.

### 7. Handshaking — "Cooperative Demand Control"

Let the server tell the client when it's not ready to receive work. TCP does this with flow control. Application protocols rarely do.

**For Umi:** This is backpressure at the protocol level. A worker could respond with "I'm busy" instead of accepting a message it can't process. But this requires protocol support.

**Alternative:** Health checks. A worker exposes a health status; callers check before sending. The load balancer model: if health check fails, stop routing to that instance.

**Umi implication:** Should workers expose a health port? Should supervisors aggregate health from children? This could enable sophisticated routing—send work only to healthy workers.

### 8. Test Harnesses — "Make Your Tests Nasty"

Mock objects test conforming behavior. Test harnesses test *out-of-spec* behavior. They simulate network errors, protocol violations, slow responses, garbage data.

> "A good test harness should be devious. It should be as nasty and vicious as real-world systems will be."

**For Umi:** The Proctor stress testing we did is exactly this philosophy. Thousands of tests hunting for edge cases. The MCP client that "felt too easy" until we stress-tested it.

**Nygard's failure catalog:**
- Connection refused
- Connection accepted but no response
- Slow responses
- Garbage responses
- Responses that are too large
- Authentication failures
- Partial responses

Every one of these should be testable against Umi workers. A "killer test harness" for Ractors could:
- Send malformed messages
- Send messages at overwhelming rates
- Never respond to calls
- Respond after the timeout
- Send responses to the wrong port

### 9. Decoupling Middleware — "Synchronous Calls Are Vicious Amplifiers"

Request/reply is tight coupling. The caller blocks until the callee responds. If the callee is slow, the caller is slow. Cascading failures propagate through synchronous calls.

Message queues are loose coupling. The sender doesn't wait. Failures don't propagate synchronously.

**For Umi:** The `call` pattern (send message, wait for reply) is synchronous. The `cast` pattern (send message, continue immediately) is asynchronous.

**Umi's position:** Both patterns are valid. But `call` should always have a timeout (synchronous with bounds), and callers should prefer `cast` when they don't need a response.

The deeper insight: **Umi's port-based communication is inherently more decoupled than direct function calls.** The message goes into a queue; the worker processes it when ready. Even a "synchronous" `call` is async under the hood—it's just that the caller blocks waiting for a response.

### 10. Shed Load — "You Can't Out-Scale the World"

When demand exceeds capacity, refuse new work. TCP does this with the listen queue. Services should do it with explicit load shedding.

**For Umi:** How does a worker shed load?
- Bounded port queue: when full, new sends fail
- Explicit rejection: worker checks queue depth and rejects messages
- Health check failure: worker reports "unhealthy," supervisor stops routing

**Key insight:** Shed load at the edge. Inside the system, use backpressure. At the boundary (where callers are uncontrolled), shed load to protect the interior.

### 11. Back Pressure — "Queues Must Be Finite"

When a queue is full, options:
1. Drop the new item (silent loss)
2. Drop an old item (prioritize freshness)
3. Refuse the item (explicit rejection)
4. Block the producer (flow control)

Blocking propagates pressure upstream—all the way to the ultimate client.

**For Umi:** Port queues are currently unbounded. What happens when they grow without limit? Memory exhaustion, then crash.

Options for Umi:
- Bounded queues with blocking sends (back pressure)
- Bounded queues with rejecting sends (load shedding)
- Monitoring of queue depth (visibility, not control)

**Warning:** Back pressure with blocking can lead to blocked threads (Ractors). Must combine with timeouts.

### 12. Governor — "Slow Down for Human Intervention"

Automation is fast; humans are slow. When automation goes wrong, it goes wrong fast. Governors limit the rate of dangerous actions.

**For Umi:** The supervisor's restart bounding is a governor. It limits how fast children can be restarted. If restarts exceed the bound, the supervisor escalates—giving humans (or higher-level supervisors) a chance to intervene.

**Key insight:** Governors are asymmetric. Fast in the safe direction, slow in the unsafe direction. Spinning up workers is safe; shutting them down is unsafe. Accepting messages is safe; dropping them is unsafe.

---

## Cross-Cutting Themes

### Timeouts Are Foundational

Six patterns directly involve timeouts:
- Timeouts pattern (obviously)
- Circuit Breaker (tracks timeouts)
- Handshaking (alternatives to timeouts)
- Test Harness (tests timeout handling)
- Shed Load (responds to timeouts)
- Back Pressure (alternative to indefinite blocking)

**For Umi, this confirms:** The timer port pattern is not optional. Every blocking operation must have a timeout. This is the single most important stability primitive.

### Let It Crash Is Strategy, Not Tactic

Let It Crash requires infrastructure:
- Isolation (Ractors)
- Fast restart (lightweight workers)
- Supervision (supervisors)
- Reintegration (automatic)

Without all four, crashing is just crashing. With all four, crashing is recovery.

**Umi provides this infrastructure.** But users must use it correctly: keep workers lightweight, design supervision trees thoughtfully, ensure reintegration is automatic.

### Cynicism Is Design Philosophy

Throughout both chapters, the theme is: **trust nothing, expect failure, design for recovery.**

This is what the planning documents mean by "cynical software." It's not pessimism; it's realism. Systems will fail. The question is: will failure be contained, or will it cascade?

---

## Questions for Umi

1. **Should Proctor have built-in circuit breaker support?** If the subprocess crashes repeatedly, should Proctor automatically "open" and refuse calls?

2. **Should port queues be bounded by default?** Unbounded queues eventually exhaust memory. Bounded queues require a policy for full-queue behavior.

3. **How do workers expose health?** A dedicated health port? A callback in the supervision spec? Something supervisors aggregate?

4. **What's the governor for restart bounding?** Linear? Exponential backoff? Leaky bucket? The choice affects how quickly escalation happens.

5. **How do we build test harnesses for Ractors?** A "killer Ractor" that sends malformed messages, never responds, responds late, overwhelms with volume?
