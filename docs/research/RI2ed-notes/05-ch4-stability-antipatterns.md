# Chapter 4: Stability Antipatterns — Reflections for Umi

This is the densest chapter so far. Twelve antipatterns, each a different way systems die.

## The Catalog of Killers

### 1. Integration Points — "The Number-One Killer"

Every socket, process, pipe, or remote procedure call can and will hang. Every feed can crash you at the worst possible time.

**The 5 A.M. Problem** is particularly relevant: firewall connection timeouts that silently drop connections, causing the next use to block for *minutes* (TCP retries) or *forever* (reads). The application thinks the connection is fine because TCP connections are abstractions that exist only in endpoint memory.

**For Umi:** Proctor wraps external processes. Those processes are integration points. Every `pop_stdout` is a read that could hang. Every `push_stdin` is a write that could block. The timer port pattern in Proctor exists precisely because of this chapter.

But there's more: MCP servers are integration points. Any external service a worker communicates with is an integration point. **Umi's job is to make it easy to wrap integration points with timeouts, circuit breakers, and bulkheads.**

### 2. Chain Reactions — "Horizontal Scaling's Dark Side"

In a horizontally scaled farm, when one server dies, the survivors take its load. If the death was load-related (memory leak, race condition), the increased load makes survivors *more* likely to die. Accelerating cascade until all servers are down.

**For Umi:** This is about workers within a supervision tree. If one worker dies and a supervisor restarts it, but the new worker inherits the same load spike that killed the first... cascade.

Restart bounding (`max_restarts` within `period`) is one answer: if workers keep dying, the supervisor dies and escalates. But that's a blunt instrument.

Better: **the restart should not inherit the problematic state.** Erlang/OTP's answer is message queues—the dead process's mailbox is gone. When a new process starts, it starts fresh. The queue pressure is relieved by dropping the messages to the dead process.

In Umi, what happens to queued messages when a worker dies? If they're in a port owned by the dead Ractor, they're gone. This is probably correct—the old work is abandoned and the system continues. But it needs to be explicit and understood.

### 3. Cascading Failures — "The Number-One Crack Accelerator"

A failure in one layer triggers failures in calling layers. The database goes down; all apps that call it block; all users that call those apps block. Crack jumps the gap.

The mechanism is usually blocked threads (waiting for resources that will never come) or aggressive retries (hammering a dying service).

**For Umi:** This is the reason for supervisor hierarchies and blast radius control. A failure in a leaf worker should not cascade to siblings. A failure in an entire subtree might cascade to the parent, but that's deliberate escalation.

The key insight: **cascading failures require a transmission mechanism.** In thread-based systems, it's blocked threads. In Ractor-based systems, it's... blocked `Ractor.select`? Unbounded port queues? Workers that wait forever for responses?

**Umi's primary defense: timeouts on everything.** No `Ractor.select` without a timer port. No `call` without a timeout. This is the planning documents' emphasis on the timer pattern.

### 4. Users — "A Terrible Thing"

Users consume memory (sessions). Users do weird random things. Malicious users attack. Users gang up (flash mobs).

Most of this is about web sessions, which isn't directly relevant to Umi as infrastructure. But the deeper point matters: **external inputs are hostile.** Users, other systems, network events—all of them can send impulses at the worst time.

**For Umi:** The "users" of Umi-supervised workers are the callers—other Ractors, external clients, network events. Every `port.send` is potentially hostile. Workers must not assume callers are well-behaved.

### 5. Blocked Threads — "The Proximate Cause of Most Failures"

The interpreter is running, but every thread is waiting for something that will never come. The system isn't crashed—it's hung. From the user's perspective, there's no difference.

**This is probably the most important antipattern for Umi.**

Ractors don't have threads in the traditional sense, but they have the same problem: a Ractor blocked in `Ractor.select` (without timeout) or `port.receive` (blocking) can wait forever. If all workers are blocked, the system is hung.

The antidotes Nygard lists:
- **Use proven primitives** — Don't roll your own connection pool. In Umi terms: use well-tested patterns for port communication.
- **Defend with timeouts** — You can't prove code has no deadlocks, but you can ensure no deadlock lasts forever.
- **Beware code you cannot see** — Libraries block in surprising ways.

**For Umi:** Every blocking operation needs a timeout. The timer port pattern must be pervasive. `call` must have a timeout. `pop_stdout` must have a timeout. This is not optional.

### 6. Self-Denial Attacks — "Good Marketing Can Kill You"

The system attacks itself. Marketing sends an email with a deep link. Shared resources create contention. A rogue server damages all others.

**For Umi:** Shared resources within a Umi system could be:
- Registry (all workers look up names)
- Logging infrastructure
- Configuration distribution
- Any "kernel" Ractor that all workers depend on

These are single points of failure even though they're not integration points in the external sense. The "boring root principle" addresses this: kernel Ractors must be maximally simple.

But also: **shared-nothing is the ideal.** Workers that don't share state can't self-deny through contention.

### 7. Scaling Effects — "The Square-Cube Law"

Point-to-point communication scales as O(n²). Shared resources become bottlenecks. What works in dev/QA (1:1 ratios) breaks in production (10:1 ratios).

**For Umi:** Point-to-point between Ractors is fine for small systems but problematic at scale. If every worker needs to talk to every other worker, you have O(n²) ports.

Alternatives from Nygard:
- Publish/subscribe messaging
- Message queues
- Broadcast/multicast

The process groups concept in `etc.md` is an answer: broadcast to a group rather than point-to-point to each member.

### 8. Unbalanced Capacities — "The Front End Always Wins"

Front-end systems can overwhelm back-end systems because their capacities don't match. 3,000 front-end threads calling 75 back-end threads is "not in the ballpark."

**For Umi:** This is about backpressure. If a worker pool has 10 workers, but 1,000 messages arrive per second, something has to give. Either:
- Callers block (backpressure via full queues)
- Messages are dropped (load shedding)
- Workers crash from overload (failure)

The `rac.md` planning doc discusses backpressure (async/sync/discard modes). This antipattern is why that matters.

### 9. Dogpile — "Power Restoration Surge"

Synchronized demand: all servers boot at once, all cron jobs fire at midnight, all caches expire simultaneously. The transient load is much higher than steady-state.

**For Umi:**
- **Startup:** If a supervisor restarts all children at once, they all hit the database at once.
- **Timers:** If all workers set timers for the same interval, they all fire simultaneously.
- **Cache expiry:** If all workers cache data with the same TTL, they all expire at once.

**Mitigation: jitter.** Add randomness to intervals. Stagger restarts. Don't use round-number timeouts.

The restart strategy in `sup.md` should consider this: should children restart in parallel or sequentially? Parallel is faster but can dogpile downstream resources.

### 10. Force Multiplier — "Automation Gone Wrong"

Automation senses state, computes desired state, effects changes. If it senses wrong (partition) or computes wrong (stale data), it can make catastrophic changes at machine speed.

The Reddit example: autoscaler reads partially migrated data, thinks too many servers are running, shuts them down. Outage.

**For Umi:** The supervisor *is* automation. It senses child state (alive/dead), computes desired state (all children running), effects changes (restart dead children).

If the supervisor's sensing is wrong (race condition in dead Ractor identification), it could restart the wrong child. If its state is corrupted, it could make bad decisions at machine speed.

**Safeguards:**
- Hysteresis (start fast, stop slow)
- Confirmation for large gaps between expected and observed state
- Limits on actions per time period (restart bounding is this)
- Don't trust 80%+ of system being down—probably a sensing problem

### 11. Slow Responses — "Worse Than No Response"

A slow response ties up resources in both caller and callee. Fast failure allows the caller to proceed. Slow responses propagate upward as cascading failures.

**For Umi:** A worker that processes slowly is dangerous. If it takes 10x longer than expected, callers queue up, their callers queue up, and so on.

**Mitigation: Fail Fast.** If a worker knows it can't meet its SLA, it should reject requests immediately rather than try and fail slowly.

This is related to backpressure: a system that knows it's overloaded should shed load rather than struggle through.

### 12. Unbounded Result Sets — "Design With Skepticism"

A query returns 5 million rows instead of 100. The application loops over all of them, exhausting memory.

**For Umi:** This is about not trusting data sources. When receiving messages, don't assume they're well-formed or reasonably sized. When iterating over collections, consider limits.

More generally: **cynical software doesn't trust anyone, including itself.** Validate inputs. Limit iterations. Bound memory usage.

---

## Cross-Cutting Themes

Several themes run through all twelve antipatterns:

### 1. Timeouts Everywhere

Almost every antipattern can be mitigated by timeouts:
- Integration points: timeout on socket operations
- Blocked threads: timeout on all waits
- Cascading failures: timeout breaks the chain
- Slow responses: timeout defines "slow"

**Umi must make timeouts easy and default.** Not opt-in, but opt-out.

### 2. Fail Fast

If you can't succeed, fail quickly. Don't consume resources trying when the outcome is predetermined. Return errors, shed load, crash cleanly.

Umi's "let it crash" philosophy is a form of Fail Fast: rather than limp along in a corrupted state, die and restart fresh.

### 3. Bounded Everything

Unbounded queues, unbounded result sets, unbounded retries, unbounded sessions—all lead to resource exhaustion.

Umi should provide bounded primitives:
- Bounded port queues (or at least monitoring of queue depth)
- Bounded restarts (restart bounding)
- Bounded message sizes
- Bounded processing time

### 4. Isolation

Bulkheads, shared-nothing, blast radius control—all are forms of isolation. Failures in one compartment shouldn't sink the ship.

Ractors provide structural isolation. Supervision trees provide organizational isolation. Together, they're Umi's primary defense.

### 5. Cynicism

Expect bad things. Trust nothing. Verify everything.

This is the mindset Umi should encourage: every message could be malformed, every dependency could fail, every caller could be hostile. Design as if your allies are trying to kill you.

---

## Questions for Umi

1. **What happens to queued messages when a worker Ractor dies?** Are they lost? Preserved? Redistributed?

2. **How does Umi expose queue depth for monitoring?** Can a supervisor see that a child's port is backing up?

3. **What's the default timeout policy?** Should every `call` have a default 5-second timeout like Erlang's GenServer?

4. **How does restart bounding interact with dogpile?** If all children in a pool need restarting, should they restart simultaneously or with jitter?

5. **What safeguards does the supervisor have against sensing errors?** If `alive?` lies or races, what's the fallback?
