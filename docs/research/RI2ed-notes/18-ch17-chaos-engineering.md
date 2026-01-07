# Chapter 17: Chaos Engineering — Reflections for Umi

> "Killing instances turns out to be a radical idea—but not a crazy one."

This chapter introduces chaos engineering: the discipline of deliberately breaking systems to learn how they fail. For Umi, this is both validation of design principles and a roadmap for testing strategy.

## The Core Definition

> "Chaos engineering is 'the discipline of experimenting on a distributed system in order to build confidence in the system's capability to withstand turbulent conditions in production.'"

Two key words: **experimenting** and **confidence**. Not proving correctness—building confidence through empirical evidence. We don't model what the system *should* do; we observe what it *does*.

**For Umi:** This aligns with the empirical philosophy. We don't prove supervision trees are correct; we test them under stress and observe behavior. The Proctor stress tests are already chaos engineering in miniature.

## Safety Is Not Composable

> "Like concurrency, safety is not a composable property. Two services may each be safe on their own, but the composition of them isn't necessarily safe."

The example: two services with 99.9th percentile latency of 30ms. Each individually meets a 50ms timeout. But call them in sequence and the composition fails.

**For Umi:** This is profound. Two workers may each be "safe" (handle errors, restart cleanly), but their *interaction* might not be safe:
- Worker A times out waiting for Worker B
- Worker B's response arrives after A has moved on
- Cascading restart when one goes down

Unit testing workers in isolation is insufficient. We need to test the *composition* under stress.

**Testing implication:** Worker integration tests should inject faults at the boundaries between workers, not just at individual workers.

## Drift into Failure

Dekker's insight about systems drifting toward their safety boundaries:

> "Over time, there's pressure to increase the economic return of the system... Those forces combine to create a gradient that pushes the whole system closer to the safety boundary."

And the consequence:

> "Highly efficient systems handle disruption badly. They tend to break all at once."

**For Umi:** This is a warning about optimization. If we tune supervision parameters for maximum throughput, we may sacrifice resilience. The leaky bucket algorithm for restart bounding is *intentionally* conservative—it resists drift.

**Design principle:** Umi's defaults should favor resilience over efficiency. Users who want to tune toward efficiency should have to explicitly acknowledge the trade-off.

## The Fundamental Regulator Paradox

Weinberg's insight:

> "The task of a regulator is to eliminate variation, but this variation is the ultimate source of information about its work. Therefore, the better a regulator does, the less information it gets about how to improve."

Paraphrased: "You don't know how much you depend on your IT staff until they go on vacation."

**For Umi:** This is the supervision trap. If supervisors are so good at hiding failures that no one notices, we lose the signal about what's failing. The transparency features (logging, health checks, metrics) exist to preserve this signal.

**Design question:** Should Umi track "restarts that succeeded silently"? If a worker crashes and restarts 100 times without user impact, that's important information being hidden.

## The Volkswagen Microbus Paradox

> "You learn how to fix the things that often break. You don't learn how to fix the things that rarely break."

**For Umi:** Workers that never crash are dangerous. When they finally do crash, we won't know how to handle it. This is an argument for:
1. Regular restart cycling (like Erlang's "let it crash" philosophy—restart periodically even if healthy)
2. Chaos testing that deliberately kills healthy workers
3. Documentation of recovery procedures for rarely-exercised paths

## Chaos Monkey and the Simian Army

Netflix's approach: randomly kill instances to make failure routine.

> "Basically, Netflix needed failures to happen *more often* so that they became totally routine. (This is an example of the agile adage, 'If something hurts, do it more often.')"

**For Umi:** What would "Chaos Monkey for Ractors" look like?

| Netflix Simian | Umi Equivalent |
|----------------|----------------|
| Chaos Monkey | Randomly terminate workers |
| Latency Monkey | Inject delays in message delivery |
| Chaos Kong | Kill entire supervision subtrees |
| Conformity Monkey | Verify workers match expected configuration |
| Janitor Monkey | Clean up orphaned resources (ports, Registry entries) |

**The simplest chaos tool:** A testing module that sends `:exit` to random workers and verifies the system recovers.

## Opt-In vs. Opt-Out

Netflix chose opt-out: all services subject to chaos unless explicitly exempted.

> "Adoption rates are much lower in opt-in environments than in opt-out."

**For Umi:** This is an organizational question, not a technical one. But Umi could *support* opt-out by making chaos testing easy:
- Built-in "chaos mode" that supervisors can enable
- Workers marked with `chaos_exempt: true` survive
- Everything else gets randomly terminated

## Prerequisites for Chaos

The chapter lists requirements:
1. **Can't kill your company** - failures must be tolerable
2. **Limit blast radius** - control which requests are affected
3. **Trace requests** - know what succeeded and failed
4. **Know what healthy looks like** - have monitoring
5. **Have a recovery plan** - system may not auto-recover

**For Umi:**

1. **Tolerable failures**: Umi already assumes failures are normal. Workers are designed to crash and restart.

2. **Blast radius**: Pool-level isolation means killing one worker doesn't affect others in the pool. Bulkheading across pools limits damage further.

3. **Tracing**: Umi doesn't have built-in request tracing. If messages carry a correlation ID, you can trace them. But this is application-level, not framework-level. *Possible enhancement.*

4. **Monitoring**: Transparency features should report worker health, restart counts, message processing times. Without these, chaos testing is blind.

5. **Recovery**: The supervision tree *is* the recovery plan. But should Umi have an "abort chaos" signal that stops all fault injection immediately?

## Designing the Experiment

> "Think about it in terms of invariants that you expect the system to uphold even under turbulent conditions. Focus on externally observable behavior, not internals."

**For Umi:** What are the system invariants?

1. "Worker pools maintain at least N healthy workers"
2. "No message is lost (either processed or error-logged)"
3. "Supervisor restart count never exceeds threshold"
4. "Registry eventually reflects actual worker state"
5. "External processes managed by Proctor are properly cleaned up on failure"

These invariants become testable hypotheses:
- "Kill 50% of workers in a pool. Within 5 seconds, pool should have original capacity."
- "Send a message while killing the target worker. Message should be either delivered or error-handled."

## Types of Injection

Three injection types:
1. **Kill instances** - crude but effective
2. **Add latency** - finds timeouts and race conditions
3. **Fail service calls** - finds missing fallbacks

**For Umi:**

| Injection | Umi Implementation |
|-----------|-------------------|
| Kill instance | Send `:exit` to worker |
| Add latency | Intercept message delivery, sleep |
| Fail call | Registry returns `nil` for lookups |
| Corrupt data | Send malformed messages |
| Resource exhaustion | Spawn workers until pool is full |

**Latency injection** is particularly interesting. Umi uses Ractor.select with timeout. If messages are delayed past the timeout, what happens? This should be tested.

## Targeting Chaos

> "Randomness works well at the beginning because the search space for faults is densely populated."

But later:

> "At some point, we can't rely just on randomness. We need a way to devise more targeted injections."

**For Umi:** Random worker killing finds obvious problems. Targeted chaos requires understanding the call graph:
- Which workers call which?
- What happens if the Registry fails?
- What happens if the Coordinator fails?
- What if a supervisor dies while restarting children?

The "cunning malevolent intelligence" approach (LDFI) suggests tracking message flows and systematically cutting links to find critical paths.

## Disaster Simulations

The "zombie apocalypse" simulation: randomly designate 50% of people as unavailable.

**For Umi (the project, not the software):** What happens if key contributors are unavailable?
- Is documentation sufficient for someone new to debug a supervision failure?
- Can someone unfamiliar with the codebase restart a crashed coordinator?
- Are there single points of knowledge failure?

This is why the planning documents (`sup.md`, `pre.md`, etc.) exist—to distribute knowledge.

## Questions for Umi

1. **Chaos testing infrastructure**: Should Umi ship with built-in chaos testing tools? A `Umi::Chaos` module?

2. **Composability testing**: How do we test that worker *compositions* are safe, not just individual workers?

3. **Drift detection**: Can Umi detect when systems are being tuned toward unsafe configurations?

4. **Silent restart tracking**: Should supervisors report "successful but worrisome" restart patterns?

5. **Invariant verification**: What system-level invariants should Umi guarantee, and how do we verify them?

6. **Request tracing**: Should Umi support correlation IDs natively, or is this purely application concern?

7. **Abort signal**: Should there be a way to immediately stop all chaos injection across the entire system?

## The Bigger Picture

Chaos engineering is the validation phase for everything else in this book. Stability patterns are defensive measures; chaos engineering tests whether they work.

For Umi, this chapter suggests a testing strategy:

1. **Unit tests**: Individual workers handle errors correctly
2. **Integration tests**: Worker compositions survive faults
3. **Chaos tests**: System-wide invariants hold under turbulence
4. **Stress tests**: System degrades gracefully under overload

The Proctor stress tests are a start. But they test one component. Chaos engineering for Umi should test the *system*: workers, supervisors, Registry, Coordinator, all interacting under hostile conditions.

The goal is not to prove the system is correct. The goal is to build justified confidence that it will survive production.

---

Part 4 is complete. The arc from Adaptation (Chapter 16) to Chaos Engineering (Chapter 17) makes a pair: evolution and testing. You can't evolve what you can't test. You can't test what you don't understand. Chaos engineering closes the loop—it creates the feedback that enables safe evolution.
