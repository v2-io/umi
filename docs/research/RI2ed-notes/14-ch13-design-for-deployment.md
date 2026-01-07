# Chapter 13: Design for Deployment — Reflections for Umi

> "I hate the phrase 'planned downtime.' Nobody ever clues the users in on the plan."

This chapter is about treating deployment as a feature, not an afterthought. The goal is zero downtime—users should never know a deployment happened.

## The Core Insight: Deployment Takes Time

> "The process of updating the system takes time. A typical design requires that the system always sees itself in either the 'before' or 'after' state, never 'during.' The users get to see the system in the 'during' state."

Most systems are designed for the end state. You write code that expects the new schema, the new API, the new workers. But deployment is a *process*, and during that process, both old and new coexist.

**For Umi:** During a supervision tree restart:
- Some workers are old code, some are new code
- Some workers are draining, some are initializing
- The system is in a "during" state

Umi should be designed so this "during" state is safe. Old workers and new workers can coexist. The transition is gradual, not instantaneous.

## Deployment Phases

Nygard identifies three phases:
1. **Preparation**: Apply safe changes before rollout (schema expansion, asset upload)
2. **Rollout**: Switch machines to new code, in batches
3. **Cleanup**: Remove old structures, add constraints

**For Umi worker upgrades:**

1. **Preparation**:
   - New code is available (e.g., module loaded)
   - Configuration for new workers is ready
   - Any shared state is prepared for both old and new workers

2. **Rollout**:
   - Stop some workers (drain, then terminate)
   - Start new workers with new code
   - Health check new workers
   - Repeat until all workers upgraded

3. **Cleanup**:
   - Remove old code paths
   - Apply stricter validation
   - Remove feature flags

## Drain Time

> "How long does it take to drain activity after you stop accepting new requests?"

When a machine (or worker) is being upgraded:
1. Stop accepting new work
2. Wait for in-flight work to complete
3. Apply changes
4. Restart

**For Umi:** Workers need a "draining" state:
- Reject new messages (or queue them for other workers)
- Continue processing current message
- Signal completion to supervisor
- Supervisor then terminates and restarts

This is different from "crash" (immediate termination). Graceful shutdown = drain + terminate.

**The blocked thread problem:**

> "Any blocked threads in your application will also block up the drain."

If a worker is stuck waiting on an integration point, it won't drain. This is why timeouts are essential—a stuck worker should timeout and exit, not block the deployment forever.

## Rolling Restart as Rolling Deployment

Nygard describes rolling deployments for machines:

> "We can't update all machines simultaneously... Instead, we typically look to update machines in batches."

**For Umi:** This maps directly to rolling restart of workers:

```
Groups: [A, B, C, D, E] (workers)

1. Instruct A to drain
2. Wait for A to finish current work
3. Restart A with new configuration
4. Wait for A to be healthy
5. Repeat for B, C, D, E
```

The supervision tree enables this. The supervisor knows all its children and can orchestrate the rollout. If any step fails, the supervisor can halt the rollout or escalate.

## Canary Workers

> "Your first group should be the 'canary' group. Pause there to evaluate the build before moving on."

**For Umi:** After restarting the first batch of workers:
- Watch their restart count (are they crashing?)
- Watch their response times (are they slower?)
- Watch their error rates (are they failing?)

Only proceed to the next batch if the canary workers look healthy. If they don't, the supervisor should:
- Roll back (restart with old code, if possible)
- Or escalate to parent
- Or pause for human intervention

## Health Checks and Readiness

> "A good health check page reports the application version, the runtime's version... and the status of connection pools, caches, and circuit breakers."

> "The service should start with the 'available' flag set to false so the load balancer doesn't send requests prematurely."

**For Umi:** Workers have startup time. They're not ready immediately:
- Maybe initializing state
- Maybe warming caches
- Maybe establishing connections (via Proctor)

Supervisors should track worker readiness:
- Not just "Ractor exists" but "worker is ready for work"
- Health check before routing traffic
- Health check during operation (to detect degradation)

## Trickle Then Batch

This is a brilliant migration strategy:

> "We add some conditional code in the new version that migrates documents as they are touched."

**For Umi:** This applies to any stateful migration:
- New workers handle both old and new formats
- On first access of old-format data, convert to new format
- After most data is converted (through normal use), run a batch to convert the rest
- Finally, deploy code that removes the conditional check

This is "lazy migration"—amortize the cost across requests instead of taking downtime.

## Immutable Workers (Cattle, Not Pets)

> "Under immutable infrastructure, you always start with a basic OS image."

**For Umi:** Workers should be immutable during their lifetime:
- Don't mutate a running worker
- If configuration changes, restart with new configuration
- This is "let it crash" extended to deployment

The supervisor creates new workers, it doesn't patch old ones. This is why `sup.md` says "cannot restart a Ractor in place—must spawn new, migrate state."

## "During" State Compatibility

The chapter emphasizes that old and new versions must coexist:
- Schema expansions must be safe for old code
- Schema contractions must wait until old code is gone
- Both versions may read/write the same data

**For Umi:** If workers share state (via database, files, or shared Ractors):
- New workers must handle old data formats
- Old workers must handle new data (or new data must be backward-compatible)
- Shared Ractors may need to support multiple protocols during transition

This is the "during" state problem at the Ractor level.

## Feature Toggles

> "Any new feature toggles should have been set to 'off' by default."

**For Umi:** Feature toggles at the worker level:
- Workers receive configuration at spawn time
- Configuration includes feature flags
- New behavior is off until enabled
- Enables rolling out code without enabling features

This decouples "deployment" from "release":
- Deployment: Code is in production
- Release: Feature is enabled for users

## Questions for Umi

1. **Drain mode**: Should Umi define a standard "draining" state? How does a worker signal it's ready to be terminated?

2. **Rolling restart**: Should supervisors support `restart_strategy: :rolling` with batch size and delay?

3. **Canary detection**: How do supervisors detect that canary workers are unhealthy? By restart count? By health callback?

4. **Readiness vs liveness**: Should Umi distinguish "worker exists" from "worker is ready"?

5. **Feature flags**: Should Umi provide any support for feature toggles, or is that purely application concern?

6. **State migration**: If a worker's internal state format changes, how does the new worker migrate from old format? Does the supervisor help?

## The Bigger Picture

This chapter reframes deployment as design:

> "We must design our software to be deployable, just as we design software for production."

Umi already embodies this philosophy at the Ractor level:
- Supervision *is* deployment infrastructure
- Restart policies *are* rollout strategies
- Health checks *are* readiness probes
- Let-it-crash *is* immutable infrastructure

The insight is that Umi doesn't just run applications—it *deploys* them continuously. Every restart is a micro-deployment. The patterns are the same; the scale is smaller.
