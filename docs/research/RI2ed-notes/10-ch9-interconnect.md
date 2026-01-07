# Chapter 9: Interconnect — Reflections for Umi

This chapter zooms out from individual instances to how they find each other and work together. The interconnect layer covers traffic management, load balancing, and discovery—the mechanisms that knit instances into a cohesive system.

## The Registry Connection

The moment I read this chapter title, I thought of `reg.md`. Umi's Registry *is* service discovery at the Ractor level. The problems are identical:

| Distributed System Problem | Umi Equivalent |
|---------------------------|----------------|
| How do callers find services? | How do Ractors find each other? |
| IP addresses change on restart | Ractor references invalid after restart |
| Need logical names, not physical addresses | Need Registry names, not Ractor refs |
| Discovery is itself a service that can fail | Registry is a kernel Ractor (death = halt) |

**Key insight from Nygard:**

> "It's best not to roll your own service discovery. Like connection pools and crypto libraries, there's a world of difference between writing one that works and writing one that *always* works."

This reinforces `ini.md`'s principle that the Registry must be *extremely simple and robust*—kernel-level infrastructure that "rarely fails." Umi's Registry has a smaller problem space than Consul (single-process, not distributed), but the warning still applies: even the "simple" version must be bulletproof.

## Solutions at Different Scales

Nygard introduces a framework for choosing interconnect solutions based on:
- **Rate of change**: How often do addresses change?
- **Operational support**: Who runs the discovery infrastructure?
- **Global knowledge**: Does every developer know every service?

**For Umi:** The rate of change within a single process is *high*. Workers restart. DynamicSupervisor creates and destroys children. A worker that crashes and restarts is at a new address (new Ractor reference). This justifies the Registry's existence—you need dynamic discovery even in a single process.

But Umi is also *simple* compared to a distributed system. There's no network partition. There's no geographic distance. The "operational support" is the coordinator itself. This means:
- Umi's Registry can be CP (consistent, partition-tolerant) because there are no partitions
- Lookups can be synchronous without meaningful latency cost
- No need for caching or stale-data fallbacks (within a single process)

## DNS Lessons for Registry

The DNS section has insights that translate directly:

> "When using DNS, it's important to have a logical service name to call, rather than a physical hostname. Even if that logical name is just an alias to the underlying host."

This is exactly `reg.md`'s thesis. Callers use names (`:database_pool`), not references. When the Ractor restarts, it re-registers under the same name. Callers never know the difference.

> "DNS round-robin load balancing... does poorly on other fronts. The DNS server has no information about the health of the instances."

This warns against simplistic load balancing. If Umi implements pools or process groups, they need health awareness. Sending work to a healthy worker is different from sending work to the *next* worker in round-robin order.

## Load Balancing Patterns

The load balancing section describes patterns Umi will need:

**Virtual IPs and Pools:**
```
VIP → Pool → Instances
```

In Umi terms:
```
Registry Name → Worker Pool → Individual Workers
```

**Health Checks:** Load balancers don't send traffic to instances that fail health checks. For Umi:
- Supervisors track child health
- Pools should track worker health
- A worker that's technically alive but thrashing isn't "healthy"

**Stickiness:** Sometimes you want repeated requests to go to the same instance. In Umi, this might be:
- Session affinity (all requests for user X go to session worker X)
- Stateful workers that cache per-client context
- Workers with expensive initialization that shouldn't be repeated

**Content-based routing:** Route different request types to different pools. In Umi:
- Different message patterns → different worker types
- A dispatcher Ractor that examines messages and routes to appropriate handlers

## Demand Control: The Core Insight

This section is gold for Umi:

> "Every failing system starts with a queue backing up somewhere."

This is what the planning documents warn about with unbounded Port queues. Messages pile up. Workers can't keep up. Response times climb. Callers timeout and retry (making it worse). Eventually: memory exhaustion, crash.

**The nonlinear effect:**

> "It's natural to expect your service to slow down under heavy load, but that means fewer and fewer sockets are available to receive requests exactly when the most requests are coming in! We call that 'going nonlinear,' and we don't mean it in a good way."

Replace "sockets" with "Ractor processing capacity" and this describes Umi under load perfectly. Slow processing → longer queues → even slower processing → feedback loop → collapse.

**The solution:**

> "The best thing to do under high load is turn away work we can't complete in time. This is called 'load shedding.'"

For Umi, this means:
1. Bounded Port queues (reject when full)
2. Health-aware routing (don't send to overloaded workers)
3. Quick rejection is better than slow timeout
4. Shed load as early as possible (at the edge, not deep in the system)

**Listen queue heuristic:** Nygard gives a formula for listen queue length:

```
max_wait_time / mean_processing_time + 1
× number_of_request_handlers
× 1.5
```

For a Ractor worker: if you want 100ms max response time, processing takes 10ms, and you have 1 handler (the Ractor itself):
```
(100/10 + 1) × 1 × 1.5 = 16.5 → queue depth ~17
```

This is a starting point for bounded queue sizing.

## Little's Law

Referenced but not explained in detail:

```
L = λW
```

- L = average number of items in queue
- λ = average arrival rate
- W = average wait time

**If queue length grows toward infinity, response time also heads toward infinity.**

This is why the planning documents say "queues must be finite." Infinite queues = infinite response times = system collapse.

## Service Discovery and CAP

Nygard discusses ZooKeeper (CP) vs Consul (AP):

| System | CAP Trade-off | Behavior During Partition |
|--------|---------------|---------------------------|
| ZooKeeper | CP | Some nodes refuse queries |
| Consul | AP | May return stale data |

**For Umi's future distribution story:** This matters when you have multiple nodes. A distributed Registry would need to choose:
- CP: Consistent but potentially unavailable
- AP: Available but potentially stale

For single-process Umi, this is moot—no partitions possible. But if Umi ever supports distributed supervision, these trade-offs become real.

## Migratory Virtual IPs and Failover

The VIP section describes what happens when the server behind an IP address changes mid-connection:

> "If your application calls any other service through a handoff virtual IP, it must be prepared for the possibility that the next TCP packet isn't going to the same interface as the last packet."

**For Umi:** When a worker restarts:
- Old Ractor reference is invalid
- Callers holding old references get errors
- Registry name is the stable identity

This is why `reg.md` says Registry is *essential*, not optional. Ractor references are like IP addresses that change on restart. Names are like DNS entries that survive failover.

**The error handling implication:**

> "The application must be prepared to handle that error—and handle it differently than just a 'destination unreachable' error."

In Umi terms: a send to a dead Ractor is different from a send to a live but busy Ractor. The caller needs to distinguish:
- Worker died → retry via Registry lookup (new Ractor)
- Worker busy → backpressure or shed load
- Worker rejected → maybe circuit breaker

## Questions for Umi

1. **Bounded queue sizing**: How should Umi calculate or recommend Port queue bounds? The listen queue heuristic is a starting point.

2. **Health-aware routing**: If Umi has pools, how do they track worker health? Restart count? Response time? Queue depth?

3. **Load shedding location**: Where should Umi shed load? At the supervisor? At the worker? At a dispatcher? Principle: as early as possible.

4. **Content-based routing**: Should Umi support message-type routing to different worker pools? Or is that application-layer concern?

5. **Stickiness**: Should Umi provide session affinity primitives? Or is that purely an application pattern?

6. **Distribution preparation**: What patterns should single-process Umi establish that will ease distributed Umi later? Registry already uses names; what else?

## The Bigger Pattern

This chapter reinforces a pattern we've seen throughout:

**Transparency + Control + Queues everywhere**

- Transparency: Know which workers exist, their health, their load
- Control: Ability to route, shed load, failover
- Queues: Every blocking point is a queue; every queue must be bounded

Umi is building the interconnect layer *within* a process. The problems are the same as building it across a network—just smaller. The solutions are the same—just simpler. But "simpler" doesn't mean "trivial." The queuing math, the health checks, the load shedding—all still apply.
