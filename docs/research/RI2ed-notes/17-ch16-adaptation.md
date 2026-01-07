# Chapter 16: Adaptation — Reflections for Umi

> "Change is guaranteed. Survival is not."

This is the chapter that connects operational resilience to business survival. Adaptation is not just a technical concern—it's the fundamental challenge of any system that must evolve.

## The Core Insight: Decision Loop Speed

> "The time it takes to go all the way around this cycle, from observation to action, is the key constraint on your company's ability to absorb or create change."

The OODA loop: Observe → Orient → Decide → Act

Faster loops mean competitive advantage. In the limit, you force competitors to react to you rather than the other way around.

**For Umi:** Umi's supervision tree is part of the "Act" phase. Fast restart = fast adaptation to failure. Fast rolling restart = fast adaptation to new code. Fast feature flags = fast adaptation to business needs.

But Umi also supports "Observe": transparency, metrics, health checks. The loop needs both.

## Thrashing: The Feedback Danger

> "Thrashing happens when your organization changes direction without taking the time to receive, process, and incorporate feedback."

Like pilot-induced oscillation—changing controls faster than the system responds leads to violent swings.

**For Umi:** This warning applies to supervision policy. If restart bounding is too aggressive, you might oscillate between crashing and restarting without ever stabilizing. If configuration changes faster than workers can adapt, you'll thrash.

The "leaky bucket" algorithm for restart bounding is about pacing—not preventing restarts, but preventing restarts faster than the system can recover.

## Service Extinction

> "The most important part of evolution is extinction."

Build small services. Let them compete. Kill the losers. This requires that services be small enough to kill without breaking the system.

**For Umi:** This is bulkheading taken to its logical conclusion. If workers are small and independent, you can stop one type of worker without affecting others. The supervision tree becomes a pruning tool—you can remove entire subtrees.

**The implication:** Design supervision trees with service extinction in mind. Each subtree should be deletable without destroying the whole system.

## Two-Pizza Team Autonomy

> "The two-pizza team is about reducing external dependencies."

Small teams that can deploy independently, without coordination with other teams.

**For Umi:** The "no coordinated deployments" sidebar is gold:

> "If you ever find that you need to update both the provider and caller of a service interface at the same time, it's a warning sign that those services are strongly coupled."

For Umi workers: if you have to restart multiple worker types atomically, they're too coupled. Each worker type should be deployable independently.

## Beware Efficiency

> "Efficiency can go wrong in two crucial ways that hurt your adaptability."

1. **Utilization fallacy**: Keeping people 100% busy makes work move slower (queuing theory)
2. **Specialization trap**: Optimizing for today makes tomorrow's changes harder

**For Umi:** The efficiency warning applies to architecture. A supervision tree optimized for current workload might be hard to change for future workload. Leave room for adaptation.

> "Shell scripts are crude, but they work everywhere."

Sometimes the less optimized solution is more adaptable. Umi should provide primitives that can be combined flexibly, not a fixed framework.

## Evolutionary Architecture

> "Supports incremental, guided change as a first principle across multiple dimensions."

Key insight: layered architecture inhibits change because it couples horizontally. Component-based architecture couples vertically (within the component) but allows components to change independently.

**For Umi:** The supervision tree should support component-based architecture:
- Each subtree is a component
- Components communicate through well-defined interfaces (ports)
- Components can be split, substituted, augmented, excluded without affecting siblings

## The Six Modular Operators

From Baldwin and Clark's *Design Rules*:

| Operator | Description | Umi Analog |
|----------|-------------|------------|
| **Splitting** | Break module into submodules | Split worker pool into specialized pools |
| **Substituting** | Replace one module with another | Replace worker implementation |
| **Augmenting** | Add a module | Add new worker type to supervision tree |
| **Excluding** | Remove a module | Remove worker type without affecting others |
| **Inversion** | Extract common functionality to higher level | Extract shared concerns to supervisor |
| **Porting** | Use module from different system | Reuse worker design across applications |

Every boundary in the supervision tree is an opportunity to apply these operators.

## Loose Clustering

> "In a loose cluster, the loss of an individual instance is no more significant than the fall of a single tree in a forest."

Requirements:
- No differentiated roles (or roles present in multiple instances)
- Independent startup order
- No static knowledge of cluster members

**For Umi:** This is exactly what supervision provides:
- Workers are interchangeable (within a type)
- Supervisors start workers in any order
- Workers discover each other through Registry, not static config

The nuance: workers can *discover* colleagues at runtime, but shouldn't be *configured* with colleague identities.

## Explicit Context

> "Implicit dependencies limit you to working with just one service provider."

The example: an opaque item ID requires implicit knowledge of where to look it up. A URL carries its own context—you can resolve it without external knowledge.

**For Umi:** Registry names are like opaque IDs. You need to know "ask the Registry" to resolve them. But within a single process, this is acceptable—the Registry is always available.

The more interesting application: if workers need to communicate with external services (via Proctor), they should use explicit context. Pass URLs, not IDs that require hardcoded service addresses.

## Services Control Their Identifiers

> "Services should issue their own identifiers. Let the caller keep track of ownership."

Don't embed ownership in your model. Let callers manage their own mapping of "owner" to "resource."

**For Umi's Registry:** Workers register themselves under names they choose (or that supervisors choose for them). Callers look up by name. This is simpler than having the Registry manage ownership hierarchies.

## Concept Leakage

> "There's no such thing as a natural data model, there are only choices we make."

The "price point" example: an internal concept leaking to all downstream systems, forcing them to change.

**For Umi:** Message formats between workers can leak concepts. If worker A adds a new field to its messages, does worker B need to understand it? If B just passes through, no leakage. If B must parse and process, there's coupling.

**Design principle:** Workers should be data-agnostic where possible. Parse only what you need. Pass through the rest.

## Information Architecture: Events vs State

> "In a few databases, the event itself is primary. Events are preserved as a journal or log."

Event sourcing: the journal is truth, current state is just a cache.

**For Umi:** This connects to the checkpointing discussion in the planning docs. Should Umi store events (what happened to workers) or state (current worker config)?

Event sourcing would mean: "worker A was started at T1, crashed at T2, restarted at T3..." From this, you can reconstruct current state. This is more powerful (you can replay history) but more complex.

For now, Umi probably stores state (current supervision tree). Event sourcing is a future consideration for debugging and replay.

## Questions for Umi

1. **Service extinction**: How do you safely remove an entire worker type from a running system?

2. **Coordinated deployment**: How do you detect when worker upgrades require coordinated changes? Is this a lint check?

3. **Loose clustering**: Do Umi workers meet the loose clustering requirements? Any hidden dependencies?

4. **Modular operators**: Which operators does Umi supervision support well? Which are awkward?

5. **Explicit context**: Should Umi encourage URL-style identifiers for resources, rather than bare IDs?

6. **Concept leakage**: How do we prevent supervisor-level concepts from leaking into worker implementations?

## The Bigger Picture

This chapter completes a shift that started in Part 2. The earlier chapters asked: "How do we survive failures?" This chapter asks: "How do we evolve?"

Survival is static. Evolution is dynamic. Umi must support both:
- **Survival**: Supervision, restarts, circuit breakers, timeouts
- **Evolution**: Modular operators, loose clustering, service extinction

The supervision tree is not just a safety net. It's a lattice for growth. Each worker is a module that can be split, substituted, augmented, or excluded. The tree structure provides the boundaries where evolution happens.
