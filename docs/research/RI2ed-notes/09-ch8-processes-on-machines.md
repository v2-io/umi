# Chapter 8: Processes on Machines — Reflections for Umi

This chapter focuses on individual instances—the processes that together form a service. Three concerns: code, configuration, and transparency. The third is the most relevant to Umi.

## Terminology Precision

Nygard defines:
- **Service**: Collection of processes across machines working together
- **Instance**: One installation of an executable, part of a load-balanced array
- **Executable**: Artifact that can be launched as a process
- **Process**: OS process running on a machine
- **Installation**: Executable plus config and resources as they exist on disk
- **Deployment**: Act of creating an installation

> "If you tell someone to 'reboot the server,' you might not know which server they're about to bounce."

**For Umi:** We need similar precision:
- **Worker**: A Ractor running application logic
- **Supervisor**: A Ractor managing other Ractors
- **Proctor**: A Ractor wrapping an external process
- **Application**: Collection of supervised Ractors that implement a unit of functionality
- **Coordinator**: The root that manages applications and kernel Ractors

Without precise terminology, discussions become confused. The glossary serves this purpose.

## Immutable and Disposable Infrastructure

> "The important part is that we can throw away the environment, piece by piece or as a whole, and start over."

Machines don't change once deployed. Need a change? Build a new image, deploy it, throw away the old.

**For Umi:** This is "let it crash" at the infrastructure level. Workers are immutable during their lifetime. Need different behavior? Restart with new configuration. Don't try to patch a running worker—kill it and start fresh.

The cleanest state is right after startup. This is why Umi workers should reconstruct state from durable sources (database, message queues) rather than accumulating state over time.

## Configuration

Nygard's key points:
- Keep per-environment config separate from code
- Never commit production passwords to version control
- For disposable infrastructure: inject config at startup or use a config service
- Name properties by function, not nature (`authenticationProvider` not `hostname`)

**For Umi:** How do workers receive configuration?

Options:
1. **Passed at spawn**: Supervisor provides config when starting worker
2. **Environment variables**: Worker reads from ENV
3. **Config service**: Worker queries a kernel Ractor for config
4. **Registry lookup**: Worker looks up config by name

Option 1 aligns best with supervision—the supervisor knows what its children need. Options 2-4 create dependencies that complicate startup ordering.

## Transparency: The Core Concept

> "Transparency refers to the qualities that allow operators, developers, and business sponsors to gain understanding of the system's historical trends, present conditions, instantaneous state, and future projections."

This is what saved the day in Chapter 6. Without visibility into thread states and connection pools, they couldn't have diagnosed the problem.

> "Debugging a transparent system is vastly easier, so transparent systems will mature faster than opaque ones."

> "A system without transparency cannot survive long in production."

**For Umi:** This is a first-class design requirement. Umi must be transparent:
- What Ractors exist?
- What's each Ractor's state (initializing, running, stopping)?
- What's the restart count for each supervised child?
- What messages are queued on each port?
- What's the circuit breaker state for each integration point?

Without this visibility, operators can't understand what Umi is doing. They'll be reduced to "restart everything and hope."

## Designing for Transparency

> "Transparency arises from deliberate design and architecture. 'Adding transparency' late in development is about as effective as 'adding quality.'"

Two key insights:

1. **Local visibility leads to local optimization.** You need to see the whole system, not just one instance. A batch job that finishes faster doesn't help if a parallel process is still the bottleneck.

2. **Monitoring should be an exoskeleton, not woven in.** Decisions about thresholds and alerts should be outside the instance. The instance emits data; policy is applied externally.

**For Umi:** Supervisors should emit events and metrics. What to alert on, how to aggregate across supervisors—that's a separate concern. Umi provides the data; monitoring tools interpret it.

## Logging: Human Factors

This section is gold.

> "Most developers implement logging as though they are the primary consumer of the log files. In fact, administrators and engineers in operations will spend far more time with these log files."

**Key principles:**
- Log for operators, not developers
- Reserve ERROR for things requiring action
- Bad input is not an error (it's expected behavior)
- A circuit breaker tripping IS an error (requires investigation)
- Include transaction/request IDs for tracing
- Log state transitions

**The Voodoo Operations story:** A debug message about encrypted channel reset was misinterpreted as a database warning. Operators did weekly database failovers *for six months* because of a coincidental temporal correlation.

> "That temporal connection, combined with an ambiguous, obscurely worded message, led the administrators to perform weekly database failovers during peak hours for six months."

**For Umi:** Log messages from supervisors and workers must be:
- Clear about what happened
- Clear about who needs to act (if anyone)
- Clear about whether action is automatic or manual
- Include identifiers for tracing

Bad: `"Worker died. Restarting."`
Better: `"Worker [user-session-handler:3] crashed (RuntimeError: connection refused). Supervisor [session-pool] restarting (attempt 2 of 5)."`

## Health Checks

More than "yup, it's running." Should report:
- Host/instance identity
- Version/commit
- Whether accepting work
- Connection pool status
- Circuit breaker status

**For Umi:** A supervisor's health check might include:
- Number of children alive/expected
- Restart count in current period
- Whether any circuit breakers are open
- Queue depths for child ports
- Time since last successful request

Health checks enable:
- Load balancers removing unhealthy instances
- "Go live" detection (startup complete)
- Graceful degradation (remove from pool when overloaded)

## White-Box vs Black-Box Monitoring

- **Black-box**: External observation (log scraping, HTTP probes)
- **White-box**: Internal instrumentation (metrics libraries, agents)

Black-box is more loosely coupled. White-box provides more specific data.

**For Umi:** Both matter:
- Black-box: Log files, health check endpoints
- White-box: Internal metrics emitted by supervisors

## The Shipboard Engineer Analogy

> "Shipboard engineers can tell when something is about to go wrong by the sound of the giant diesel engines. They've learned, by living with their engines, to recognize normal, nominal, and abnormal."

> "Our systems aren't so naturally exposed. They run in invisible, faceless, far-distant boxes... If we are to get the kind of 'environmental awareness' that the shipboard engineers naturally acquire, we must facilitate that awareness by building transparency into our systems."

**For Umi:** This connects to the earlier discussion about "knowing the pulse" of a system. The sampling scripts in Chapter 6 gave the team that pulse—session counts, order counts, page latency. They knew at a glance when something was wrong.

Umi should make it easy to build that pulse. Not just "is it running?" but "how is it feeling?"

## Questions for Umi

1. **What's the standard logging format for supervisors?** Structured JSON? Plain text with conventions?

2. **How do workers receive configuration?** At spawn time? From a config service?

3. **What does a supervisor's health check expose?** Child counts? Restart rates? Queue depths?

4. **How do we prevent "voodoo operations"?** Clear message wording, distinguishing automatic from manual actions?

5. **What's our story for white-box metrics?** Do supervisors emit metrics? In what format? To where?
