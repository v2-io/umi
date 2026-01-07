# Chapter 10: Control Plane — Reflections for Umi

The control plane "encompasses all the software and services that run in the background to make production load successful." If production user data passes through it, it's production software. If its main job is to manage other software, it's the control plane.

**This is exactly what the coordinator and supervision tree do in Umi.** They don't process user transactions—they manage the workers that process transactions.

## Umi IS a Control Plane

The moment I read the chapter title, the connection crystallized. Consider the layered concerns:

| Nygard's Model | Umi Equivalent |
|----------------|----------------|
| Physical infrastructure | Ruby VM, OS |
| Virtual infrastructure | Ractors |
| Containers/processes | Workers, Proctors |
| Interconnect | Ports, Registry |
| **Control plane** | **Coordinator, Supervisors** |
| Applications | User code inside Workers |

Umi provides an *internal* control plane for a Ruby process. It schedules work (supervision), allocates resources (worker pools), manages lifecycles (restart policies), and provides discovery (Registry). This isn't just an analogy—it's the same pattern at a smaller scale.

## Mechanical Advantage and Its Dangers

> "Mechanical advantage is the multiplier on human effort that simple machines provide... The kicker about mechanical advantage is that it works for good or for ill."

Supervision is mechanical advantage. One supervisor can manage dozens of workers. The coordinator manages the entire system. A single restart policy propagates across an entire subtree.

**The S3 lesson:**

> "This is not a case of humans failing the system. It's a case of the system failing humans. The administrative tools and playbooks allowed this error to happen. They amplified a minor error into enormous consequences."

For Umi, this means:
- A misconfigured restart policy affects every child
- A bug in supervisor logic can cascade through the tree
- The coordinator is the ultimate amplifier—if it misbehaves, everything suffers

This is why `ini.md` emphasizes that the coordinator must be "boring." It must not be clever. It must not do interesting things. It manages the lifecycle of everything else—boring is its superpower.

## Automation Goes Really Fast

> "With a command queue, it's even easier to create a dogpile."

> "Automation has no judgment. When it goes wrong, it tends to do so really, really quickly."

The Reddit autoscaler story is sobering. It saw stale data, believed the system needed fewer servers, and obediently shut most of them down. Faster than any human could intervene.

**For Umi:** The restart bounding mechanism is a governor on automation. Without it:

```
Worker crashes → Supervisor restarts immediately
                → Worker crashes again → Supervisor restarts immediately
                → Worker crashes again → ...
```

This loop runs at machine speed. In milliseconds, you've exhausted system resources, filled logs, and potentially crashed the entire process. Restart bounding is the safety mechanism that says "slow down, something is wrong, escalate to a human (or parent supervisor)."

The question from `sup.md` about restart bounding state (leaky bucket? exponential backoff?) isn't academic—it determines how fast the system can hurt itself.

## System Failure, Not Human Error

I want to sit with this framing:

> "This is not a case of humans failing the system. It's a case of the system failing humans."

When a developer misconfigures a supervision tree and causes a cascade, that's not "developer error." That's Umi failing to prevent the misconfiguration, or failing to contain its effects, or failing to provide visibility that something was wrong.

This shifts the design question from "how do we prevent users from making mistakes?" to "how do we design so that mistakes have limited consequences?"

**For Umi:**
- Clear error messages when supervision specs are invalid
- Validation at definition time, not at crash time
- Restart bounding that limits blast radius
- Transparency so operators can see what's happening
- Governors on dangerous operations

## Platform Team Mental Model

> "The monitoring team doesn't do the monitoring, it provides the ability for others to do their own monitoring."

> "The team should be trying to take themselves out of the loop on every day-to-day process."

This is how to think about Umi's relationship to application developers. Umi doesn't supervise your workers—it provides the ability for you to supervise your own workers. Umi doesn't define your restart policies—it provides the primitives for you to define your own.

The implication: Umi should provide *capabilities*, not *opinions*. Sensible defaults, yes. But the developer defines supervision trees, not Umi.

## Two Fundamental Questions

The chapter's framework for system-wide transparency:

1. **Are users receiving a good experience?**
2. **Is the system creating the economic value we want?**

Note what's *not* on the list: "Is everything running?"

> "Even at small scale, we should be able to survive periods where everything *isn't* running. At scale, 'partially broken' is the normal state of operation."

**For Umi:** The equivalent questions are:
1. Are workers processing messages successfully?
2. Are supervision restarts keeping workers available?

A worker that crashes but restarts quickly might be "broken" in one sense (it crashed) but "working" in another (users never noticed). Umi's transparency should answer the meaningful questions, not just "how many Ractors exist?"

## What to Expose

The chapter's comprehensive list of metrics categories is directly applicable:

| Category | Umi Equivalent |
|----------|----------------|
| Traffic indicators | Messages processed, queue depth |
| Business transactions | Application-specific (user's domain) |
| Resource pool health | Worker count, restart count, queue depth |
| Integration point health | Proctor state, circuit breaker state, timeouts |
| Cache health | Application-specific |

**The most interesting:**

> "Integration point health: State of circuit breaker, number of timeouts, number of requests, average response time... current number of concurrent requests..."

For Proctor specifically, this means tracking:
- Number of messages sent to external process
- Number of responses received
- Response time distribution
- Number of timeouts
- Number of process crashes
- Current circuit breaker state

Umi should make it easy to expose this. Not built-in dashboards, but structured data that operators can feed to their monitoring systems.

## Configuration Service Warnings

> "Make sure your instances can start without the configuration service."

> "Make sure your instances don't stop working when configuration is unreachable."

For Umi's Registry:
- Workers should start with default configuration, not block waiting for Registry
- If Registry becomes unavailable, workers should continue with last known configuration
- Registry is kernel infrastructure—but workers shouldn't crash if lookup fails

This is subtle. The Registry is "essential" (`reg.md`), but that doesn't mean workers should hard-fail on Registry errors. The supervisor can restart them. The question is: should a worker crash because it can't look up a name, or should it log an error and continue with degraded functionality?

The answer probably depends on what the name lookup is for. If it's discovering a dependency, maybe crash. If it's checking for an optional peer, maybe continue.

## Controls to Offer

The checklist is gold for Umi's dynamic reconfiguration story:

- Reset circuit breakers → Proctor should support this
- Adjust connection pool sizes and timeouts → Worker configuration
- Disable specific outbound integrations → Proctor enable/disable
- Reload configuration → Worker restart with new params
- Start or stop accepting load → Health check "unhealthy"
- Feature toggles → Application-level, but Umi could provide primitives

**The warning about "flush cache" buttons:**

> "It may not be a self-destruct button, but it's the button that vents all your atmosphere into space."

For Umi: A "restart all workers" command is the equivalent. It flushes all in-flight work and triggers a dogpile of initialization. The governor pattern applies—maybe restart waves, not all at once.

## Command Queue vs Direct API

> "Suppose each API call takes just a quarter-second to complete. It will take two minutes to loop over a fleet of 500 instances."

For Umi, this is less of a concern (all workers are in the same process), but the principle matters: broadcast commands should be asynchronous. A supervisor shouldn't synchronously wait for each child to acknowledge a configuration change—it should send the command and let children apply it when ready.

**The dogpile warning:**

> "Be careful, though! With a command queue, it's even easier to create a dogpile."

If all workers receive "restart now" simultaneously, they all stop accepting work, all reinitialize, and all start again. Jitter and waves help—stagger the restarts over time.

## Scriptable Interfaces

> "The best interface for long-term operation is the command line."

For Umi: The introspection APIs should be programmatic, not GUI-first. Operators should be able to script:
- Query supervision tree structure
- Get worker health metrics
- Trigger restarts
- Change configuration
- Enable/disable circuit breakers

If Umi provides these as method calls or message-based APIs, operators can build whatever visualization and automation they need.

## Questions for Umi

1. **Coordinator as control plane**: How do we make the coordinator's control-plane nature explicit? What operations should it expose?

2. **Supervisor transparency**: What metrics should supervisors automatically expose? Restart count? Queue depths? Worker health?

3. **Dynamic reconfiguration**: Can we restart workers with new configuration without restarting the whole supervision tree?

4. **Broadcast with jitter**: If we support "restart all children of this supervisor," should we automatically add jitter?

5. **Governor on restart**: Should the coordinator have a governor that prevents restarting too many workers system-wide?

6. **Registry degradation**: What should workers do when Registry is unreachable? Crash? Continue with cached lookups?

## The Bigger Picture

This chapter cements something I've been feeling throughout the book: **Umi is building infrastructure for infrastructure.**

The coordinator and supervisors are the "control plane" for the application's Ractors, just as Kubernetes is the control plane for a cluster's containers. The patterns are the same:
- Scheduling and placement → Supervision and restart
- Health checks → Worker liveness monitoring
- Service discovery → Registry
- Configuration management → Worker configuration at spawn
- Logging and metrics → Transparency from supervisors

Umi doesn't need to implement Kubernetes. But it should provide the *internal equivalent* of what Kubernetes provides externally. A well-designed Umi application should feel like a well-orchestrated distributed system—just within a single process.

The difference is scale and failure domain. Umi's "network partitions" are Ractor crashes. Umi's "machine failures" are worker deaths. The patterns translate; the implementation is simpler.
