# Chapter 7: Foundations — Reflections for Umi

This chapter covers the physical/virtual infrastructure layer. Much of it is about networking, VMs, and containers—concerns that sit *below* Umi's abstraction layer. But several principles translate upward.

## Design for Production

> "Design for production means thinking about production issues as first-class concerns."

This includes:
- The production network (different from dev)
- Logging and monitoring
- Runtime control
- Security
- Operators as users

**For Umi:** Operators interact with systems through "configuration, control, and monitoring interfaces." Umi needs to provide these interfaces—not just for applications, but for Umi itself. How does an operator:
- See what supervisors exist?
- See what workers are running?
- See restart counts and failure reasons?
- Change configuration at runtime?
- Gracefully shut down a subtree?

## Ephemeral Identity

Throughout the chapter, a theme emerges: **machine identity is increasingly ephemeral.**

- VMs can be started/stopped without notice
- Containers have "short-lived identity"
- Cloud VM IP addresses change on every boot
- Container images must not contain hostnames or credentials

The implication: **don't design for stable identity.**

**For Umi:** Workers shouldn't assume they have stable identity either. A worker that dies and restarts is a *different* worker, even if it has the same name in the registry. State must be reconstructed, not assumed to persist.

This connects to the "let it crash" philosophy: if identity is ephemeral, you can't rely on accumulated state. Clean startup is the norm.

## The Volunteer Pattern

> "The general rule is that VMs have to 'volunteer' to do work, rather than having a controller dole the work out."

New VMs join worker pools. They register with load balancers. They compete for queue messages. They don't wait to be assigned work.

**For Umi:** This is the actor model naturally. Workers receive messages from their ports. They don't have work pushed to them by a central controller. The supervisor's job is lifecycle management (start, stop, restart), not work distribution.

Work distribution comes from:
- Callers sending messages directly
- Load balancers routing requests
- Competing consumers on a queue

## Fast Startup

> "Containers are meant to start and stop rapidly. Avoid long startup or initialization sequences... Aim for a total startup time of one second."

Heavy initialization (loading reference data, warming caches) makes containers unsuitable.

**For Umi:** Workers should be lightweight. If a worker takes 10 seconds to start, the "let it crash" strategy becomes expensive. Fast restart requires fast startup.

This is why `ini.md` distinguishes kernel Ractors from applications: kernel Ractors are simple, fast to start, critical. Applications can be heavier but should still aim for fast startup.

**Implication:** If a worker needs heavy initialization, consider separating the initialization from the worker. A separate process loads the data; workers just use it.

## Clock Issues in VMs

> "A clock on a virtual machine is not necessarily monotonic or sequential."

VMs can be suspended, migrated, and resumed. The OS clock can jump backward or forward. The virtualization layer tries to sync with the host, which makes jumps worse from the application's perspective.

> "The bottom line is: don't trust the OS clock."

**For Umi:** This reinforces `pre.md`'s recommendation to use monotonic clock for timeouts:

```ruby
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
```

The wall clock (`Time.now`) can lie. The monotonic clock only counts forward. For timeout calculations, always use monotonic.

## The 12-Factor App

The sidebar lists the 12 factors. Several are directly relevant to Umi-based applications:

| Factor | Umi Relevance |
|--------|---------------|
| **Config** — Store config in environment | Workers should receive config at startup, not bake it in |
| **Processes** — Execute as stateless processes | Workers should be stateless or reconstruct state on restart |
| **Disposability** — Fast startup, graceful shutdown | Workers should start quickly and handle shutdown signals |
| **Logs** — Treat logs as event streams | Workers should write logs to stdout, not files |
| **Port binding** — Export services via ports | Workers expose ports for communication (literally, in Umi) |

**The disposability factor is key:** "Maximize robustness with fast startup and graceful shutdown." This is what Umi enables—workers that can be killed and restarted without ceremony.

## Multihoming and Network Awareness

Data center machines have multiple NICs for different purposes:
- Production traffic
- Backup traffic
- Administrative access

Applications must be told which interfaces to bind to; they can't just listen on "all interfaces."

**For Umi:** Proctor spawns external processes that might listen on sockets. If those processes need to bind to specific interfaces, the configuration must be explicit. This is an application concern, but Umi's configuration mechanism should make it easy to pass network configuration to workers.

## The Layered Concerns Diagram

Nygard's diagram shows layers from bottom to top:
1. Physical infrastructure
2. Virtual infrastructure
3. Containers/processes
4. Interconnect
5. Control plane
6. Applications

**For Umi:** We're primarily operating at layers 3-5:
- **Processes**: Ractors, workers, Proctors
- **Interconnect**: Ports, message passing, supervision protocols
- **Control plane**: Supervisors, coordinators, registry

Umi doesn't manage VMs or containers—that's the platform's job. But Umi provides the control plane *within* a process, managing the lifecycle of Ractors the way Kubernetes manages the lifecycle of containers.

## Questions for Umi

1. **How do we handle configuration?** Should workers receive config at spawn time? From a kernel Ractor? From environment variables?

2. **What's our logging story?** Should Umi provide structured logging? Should workers log to a central logger Ractor?

3. **How do we expose Umi's internal state to operators?** A control port? HTTP endpoint? Files?

4. **Should workers be able to bind to specific network interfaces?** Or is that purely an application concern?

5. **What's the target startup time for a worker?** If we say "under 100ms," that constrains what workers can do in their init phase.
