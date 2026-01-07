# Chapter 3: Stabilize Your System — Reflections for Umi

## Cynical Software

> "Enterprise software must be cynical. Cynical software expects bad things to happen and is never surprised when they do. Cynical software doesn't even trust itself, so it puts up internal barriers to protect itself from failures. It refuses to get too intimate with other systems, because it could get hurt."

This is Umi's design philosophy in a paragraph.

Cynical software:
- Expects bad things (timeouts, crashes, malformed data)
- Isn't surprised when they happen (failure is a normal return value, not an exception)
- Doesn't trust itself (internal barriers = supervisor boundaries)
- Doesn't trust other systems (circuit breakers, bulkheads)

The contrast is "optimistic software" that assumes:
- Network calls succeed
- Resources are available
- Input is well-formed
- Dependencies are healthy

Optimistic software is easier to write. It's also fragile. Umi's job is to make cynical software *as easy to write* as optimistic software—to shift the default from optimism to cynicism.

## Impulse vs. Stress

Nygard borrows from mechanical engineering:

- **Impulse**: A rapid shock. Flash mob, celebrity tweet, midnight batch job dumping 12M messages. Fractures the system in the blink of an eye.

- **Stress**: Sustained force over time. Slow credit card processor, overloaded database. Causes strain that propagates to distant parts of the system.

For Umi, these map to different failure modes:

**Impulse failures** might look like:
- A burst of messages overwhelming a worker's port queue
- Many simultaneous Ractor spawns exhausting OS resources
- A Proctor subprocess producing massive output that fills buffers

**Stress failures** might look like:
- Gradually increasing message latency as a dependency slows
- Memory growth from accumulated state in a long-lived worker
- Slow resource leak that eventually exhausts a pool

The responses differ. Impulses need **rate limiting**, **load shedding**, **backpressure**. Stress needs **monitoring**, **early detection**, **graceful degradation**.

Umi's current design addresses impulses (restart on crash, supervisor restart bounding) better than stress (no built-in latency monitoring, no automatic degradation).

## Longevity Bugs

> "The only way you can catch them before they bite you in production is to run your own longevity tests."

Memory leaks and data growth. Bugs that only appear after hours, days, weeks of continuous operation. Development environments restart too often to catch them. QA environments don't run under continuous load long enough.

For Umi, this is particularly relevant:
- A supervisor with a slow memory leak will eventually crash—but it might take days
- A worker that accumulates state without bound will eventually OOM
- Port queues that grow without limit will eventually exhaust memory
- Timer threads that aren't cleaned up properly will accumulate

The Proctor stress testing we did—thousands of tests, hunting for heisenbugs—is exactly this philosophy. But Proctor is one class. Umi will be a system of interacting Ractors. The emergent behaviors under prolonged operation will be harder to predict.

**Implication:** Umi needs its own longevity test harness. Not just "does it pass unit tests" but "does it run for a week under load without degradation."

## Failure Modes and Crackstoppers

> "Just as auto engineers create crumple zones—areas designed to protect passengers by failing first—you can create safe failure modes that contain the damage and protect the rest of the system."

Chiles's terminology:
- **Crack**: An initial fault
- **Crackstoppers**: Design elements that prevent cracks from propagating

The airline had no crackstoppers. The SQLException propagated through:
1. Connection pool (no timeout on blocked callers)
2. EJB layer (no timeout on RMI calls)
3. Calling applications (no timeout on external calls)
4. Service architecture (no partitioning, all callers hit same instances)

Each missing crackstopper allowed the crack to propagate further.

**For Umi, crackstoppers are:**
- Supervisor boundaries (a crash in one subtree doesn't affect siblings)
- Timeouts on all blocking operations (a slow response doesn't steal a thread forever)
- Restart bounding (a crashing child eventually stops the supervisor, not infinite restarts)
- Bulkheads (separate pools for separate concerns)
- The Ractor boundary itself (isolation is structural, not optional)

The question for any Umi design decision: **Is this a crackstopper or a crack amplifier?**

## The Fault → Error → Failure Chain

Nygard gives precise terminology:

- **Fault**: Incorrect internal state (the bug exists, waiting to trigger)
- **Error**: Visibly incorrect behavior (the bug manifests)
- **Failure**: Unresponsive system (the user can't get work done)

The chain: Fault → Error → Failure

The goal is to break the chain:
- Prevent faults from becoming errors (defensive programming, input validation)
- Prevent errors from becoming failures (recovery, restart, graceful degradation)

OTP's "let it crash" philosophy focuses on the second transition. You *accept* that faults will become errors (processes will crash). You *prevent* errors from becoming failures (supervisors restart crashed processes, isolation prevents cascade).

Umi inherits this philosophy. But Nygard notes the tension:

> "Our community is divided about how to handle faults. One camp says we need to make systems fault-tolerant... The other camp says 'let it crash' so you can restart from a known good state."

Both camps agree: faults will happen, and we must keep them from becoming failures. The disagreement is about mechanism: catch-and-recover vs. crash-and-restart.

Umi's position: **crash-and-restart is the default, but recovery is possible within a single message cycle.** A worker can catch an exception, handle it, and continue—as long as doing so doesn't leave it in a corrupted state. If in doubt, crash.

## Tight Coupling Accelerates Cracks

> "Tight coupling accelerates cracks... The more tightly coupled the architecture, the greater the chance this coding error can propagate."

The airline's tight coupling:
- Synchronous RMI calls with no timeout
- Request-handling threads making blocking external calls
- All callers using the same CF instances

Loose coupling alternatives mentioned:
- Request/reply message queues (caller expects that reply might never arrive)
- Tuple spaces (eventual consistency, no direct coupling)
- HTTP with timeouts (at least there's a timeout)
- Partitioned services (not all eggs in one basket)

For Umi, the interesting question is: **what's the coupling structure between Ractors?**

A synchronous `call` (send message, wait for reply) is tight coupling. The caller blocks until the callee responds. If the callee is slow or dead, the caller is stuck.

An asynchronous `cast` (send message, don't wait) is loose coupling. The sender continues immediately. But now the sender doesn't know if the message was processed.

The planning documents show both patterns. The question is whether Umi should have opinions about which to prefer. Perhaps: **cast is the default, call requires explicit timeout specification.**

## The Question to Always Ask

> "What are all the ways this can go wrong?"

Nygard's checklist for any external call or I/O:
- What if it can't make the initial connection?
- What if it takes ten minutes to make the connection?
- What if it connects then disconnects?
- What if it connects but doesn't respond?
- What if it takes two minutes to respond?
- What if 10,000 requests come in at the same time?
- What if the disk is full when logging the error about the network timeout?

This is the "failure modes up front" thinking we discussed earlier. The OTP affordance makes this natural: every receive has a timeout clause, every call can return `{:error, reason}`, every process can crash and be restarted.

For Umi, the equivalent questions for any Ractor communication:
- What if the port send blocks (queue full)?
- What if the Ractor is dead and we're sending to a dead port?
- What if the Ractor is alive but not receiving (busy loop)?
- What if the response never comes?
- What if the response is malformed?
- What if we spawn 10,000 Ractors at once?
- What if the supervisor crashes while restarting a child?

Each of these should have an answer in Umi's design.

## The Plateau of Enlightenment

The chapter closes by noting that the next two chapters will cover antipatterns (what kills systems) and patterns (what saves them).

For Umi, the "plateau of enlightenment" is making these patterns natural—so that writing stable Ruby feels as easy as writing fragile Ruby. Not through discipline and vigilance, but through structure and affordance.
