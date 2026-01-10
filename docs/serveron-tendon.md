# Serveron and Tendon: Long-Lived Server Holons in Ruby

*Design exploration for Umi's core abstractions.*

---

## The Naming Journey

### Why Not "Worker"?

"Worker" carries connotations of something acted *upon*:
- Fungible, replaceable, interchangeable
- Executes tasks from a queue
- Exists to serve others' purposes
- Stateless or state-indifferent
- A means to an end

This is the wrong mental model for what we're building.

### Why "Serveron"?

The OTP insight encoded in "GenServer" isn't about HTTP servers—it's about the
*server pattern*: something that maintains ongoing existence, handles requests
while preserving its own concerns, has a lifecycle that matters.

A **Serveron** is:
- Something that *acts*, not something acted upon
- Has identity, has perspective
- Responds to requests but isn't defined by them
- Has its own state to maintain, its own health to preserve
- Has its own tiny universe of concerns
- An end in itself, even while serving others

The "-on" suffix (electron, proton, neutron) suggests a fundamental particle—the
irreducible unit of server-ness.

A Serveron is a **holon**.

### Why "Tendon"?

For supervision, we explored guardian/keeper/watcher concepts. "Tendon" emerged
from wordplay (tender + on) but the anatomical meaning reinforces the concept:

- Tendons connect muscle to bone
- They transmit force, enable movement
- They're structural, essential, often invisible
- When a muscle fails, the tendon is what enables reconnection

A **Tendon**:
- Connects serverons to the larger structure
- Transmits signals (restart, shutdown)
- Holds the system together
- Provides structural integrity
- *Tends* to its serverons

The anatomical pun fits the body/organ metaphor—and carries a bit of Ruby
community absurdist humor.

---

## The Holon Concept

Arthur Koestler introduced "holon" in *The Ghost in the Machine* (1967),
combining Greek *holos* (whole) with the "-on" suffix. His insight:

> At every level of organization, you find entities that are simultaneously
> complete wholes AND subordinate parts. Neither aspect is more "real" than
> the other.

A cell is:
- A **whole**: self-regulating, maintains its own boundaries, has its own metabolism
- A **part**: of an organ, subordinate to larger purposes

Every holon has two opposing drives:

1. **Self-assertion** — preserve autonomy, maintain boundaries, assert identity
2. **Integration** — function as part of a larger whole, subordinate to broader purposes

Healthy systems balance these. Pathology is imbalance:
- Too much self-assertion → **cancer** (cells refusing to integrate)
- Too much integration → **loss of identity** (parts losing their function)

### Holarchy, Not Hierarchy

Koestler coined "holarchy" for nested levels where each level is both autonomous
AND integrated. The "higher" level doesn't merely command—it depends on the
lower level's autonomous functioning.

The body doesn't micromanage each cell. It depends on cells being competent
wholes that handle their own affairs.

### Serverons as Holons

A Serveron is exactly a holon:
- **As a whole**: manages its own state, lifecycle, health, has its own purpose
- **As a part**: participates in a supervision tree, can be restarted by its
  tendon, contributes to a larger system

A Tendon is also a holon—complete in itself, but part of a larger tree.

The supervision tree is a holarchy: serverons supervising serverons, each level
both autonomous and integrated.

---

## How Serverons Differ from Ruby Modules

In traditional Ruby:
- One process, shared memory
- Classes coordinate via method calls
- Crash anywhere = crash everywhere
- Isolation is exceptional (external services, separate VMs via Redis/DB)
- Objects are cheap, ephemeral, garbage-collected
- State lives in instance variables, accessible by anyone with a reference

A Ruby module/class is not designed to:
- Run indefinitely
- Survive failures
- Maintain boundaries under stress
- Have its own lifecycle independent of its callers
- Be monitored for death
- Be restarted from a known good state

### The Serveron Difference

A Serveron is designed from the start for *longevity* and *stability* (in the
Release It! sense):

**Longevity**: The ability to keep processing transactions for a long time.
A Serveron expects to run for hours, days, weeks—not milliseconds.

**Stability**: The ability to keep processing transactions even when transient
impulses, persistent stresses, or component failures disrupt normal processing.
A Serveron expects things to go wrong and plans for it.

A Serveron has:
- **Isolation**: Runs in its own Ractor, memory-isolated from others
- **Boundaries**: Explicit ports for communication, no shared state
- **Identity**: Can be named in a Registry, survives restarts
- **Lifecycle**: init → running → degraded → terminating → dead
- **Supervision**: A Tendon monitors it and decides what to do when it dies
- **Steady State**: Can run without human intervention indefinitely

---

## Concerns of a Long-Lived Server

A Serveron must address concerns that typical Ruby objects never consider.
These aren't administrative metadata imposed from outside—they're the
serveron's own concerns, thought about in first person:

### 1. Initialization / Birth

**Prerequisites (Mise en Place)**: What must exist before I can start?
Dependencies, configuration, credentials, connections. *Mise en place*—
everything in its place before cooking begins. This is the foundation of
**Fail Fast**: if prerequisites aren't met, fail immediately rather than
discovering it mid-transaction.

**Startup Sequence**: How do I boot? What order? Is it idempotent?

**Steady State Achievement**: How do I know I'm "ready"? The transition from
starting → operational. Until steady state is achieved, I shouldn't accept
work.

**Announcement/Registration**: How do I make myself known to the system?
Registry entry, health endpoint available, ready to receive on my port.

**Startup Duration**: How long is acceptable? The 12-factor principle:
seconds, not minutes. Fast startup enables **Disposability**—I can be killed
and restarted without drama.

### 2. Steady State Operation

**Primary Work**: What transactions do I process? My reason for existing.

**Idle Behavior**: What do I do when there's no work? Heartbeat? Background
maintenance? Sleep? A serveron isn't just a request handler—it exists between
requests too.

**Resource Management**: How do I manage bounded resources? Connection pools,
memory, file handles. Every mechanism that accumulates resources must have a
corresponding mechanism to recycle them—this is the **Steady State** pattern.

**Self-Maintenance**: Log rotation, cache pruning, connection refresh. A
serveron that requires human intervention isn't at steady state.

### 3. Degraded Operation

**Graceful Degradation**: What reduced functionality can I offer when
dependencies are unavailable? Not all failures should be fatal.

**Circuit Breaker States**: When do I stop trying to reach a failing
dependency? When do I try again? The **Circuit Breaker** pattern tracks
failures and trips when a threshold is exceeded, failing fast rather than
waiting for timeouts.

**Stasis/Suspension**: Can I pause accepting work while remaining alive?
**Handshaking** with callers to signal "not ready."

**Load Shedding**: When demand exceeds my capacity, can I refuse new work
rather than slowing down until everything fails?

**Back Pressure**: Can I signal upstream to slow down?

### 4. Termination / Death

**Graceful Shutdown**: How do I respond to SIGTERM? What cleanup is required?
The **Disposability** principle: shut down gracefully, release resources,
complete or abandon in-flight work.

**Drain Time**: How long do I need to finish in-flight work? If I have
**Blocked Threads** (or blocked Ractor receives), drain time is infinite—
another reason timeouts are essential.

**Deregistration**: Remove myself from load balancers, registries, service
discovery. Stop accepting new work before finishing old work.

**Crash Behavior**: What happens on unexpected death? What state might be
corrupt? What needs cleanup that won't happen?

### 5. Recovery / Resurrection

**Restart Strategy**: How quickly can I restart? What state do I resume from?
The **Let It Crash** philosophy: instead of trying to recover from every
error, crash and restart from a known good state.

**Reintegration**: How do I rejoin the system after restart? Automatic
**Reintegration** is essential for Let It Crash—circuit breakers auto-retry,
registries detect health, serverons rejoin pools.

**Clean State**: The cleanest state is right after startup. If I carry
corruption across restarts, Let It Crash doesn't help.

### 6. Dependencies (What I Need)

**Hard Dependencies**: What must be available for me to function at all?
Every **Integration Point** is a risk—the number-one killer of systems.

**Soft Dependencies**: What can I operate without (in degraded mode)?

**Startup Order**: Do my dependencies need to be ready before I start?

**Failure Propagation**: How do dependency failures affect me? With
**Timeouts** and **Circuit Breakers**, a problem in another system doesn't
have to become my problem. Without them, I'm a **Crack Amplifier**.

### 7. Dependents (What Needs Me)

**Fan-In**: How many callers do I have? High **Fan-In** services spread their
problems widely.

**Contract**: What do I promise? Response format, latency bounds, availability.

**Back Pressure**: How do I signal "slow down" to callers?

**Load Shedding**: When do I refuse new work? **Shed Load** at system edges
when demand exceeds capacity.

### 8. Supervision (My Place in the Holarchy)

**Supervised By**: Who is my Tendon? What restart strategy applies to me?

**Supervises**: What serverons do I tend? What strategy?

**Escalation**: When does my failure escalate to my tendon? The **Leaky
Bucket Algorithm** tracks restart frequency—too many restarts in a window
means escalation.

**Restart Bounding**: How many times can I restart before my tendon gives up?
Infinite restarts mask bugs; bounded restarts surface them.

### 9. Transparency / Visibility

**Health Reporting**: Can I report my ability to do work? Not just "am I
running?" but: connection pool status, circuit breaker state, queue depth,
time since last successful transaction. **Transparency** allows operators
to understand historical trends, present conditions, and future projections.

**Metrics**: What should be measured? Latency, throughput, error rate.
**Lagging Indicators** (like response time) can only be measured after
transactions complete—if requests are hanging, you don't see their response
time.

**Logging**: What events do I log? Clear messages prevent **Voodoo
Operations**—rituals based on coincidental correlation rather than causation.

### 10. Evolution / Change

**Configuration**: How am I configured? Environment? Files? Service?
**Dynamic Reconfiguration** allows parameter changes at runtime without
restart—essential for production recovery.

**Schema Evolution**: How do my data structures change over time? The
**Expansion/Contraction** pattern: add first, remove later.

**Replaceability**: Can I be substituted? Can I be deleted without breaking
the system? Every boundary is an opportunity for the **Modular Operators**:
splitting, substituting, augmenting, excluding.

---

## The Crack Dynamics of Serverons

Understanding how failures propagate is essential for serveron design.

### Faults, Errors, and Failures

- **Fault**: A condition that creates incorrect internal state. The crack
  waiting to propagate.
- **Error**: Visibly incorrect behavior. A fault made manifest.
- **Failure**: An unresponsive system. When users can't get work done.

### Crack Propagation

A **Crack** is an initial point of failure. Under stress, cracks propagate—
sometimes instantly in software. **Tight Coupling** accelerates propagation;
**Loose Coupling** slows or stops it.

Serverons are **Crackstoppers**—design elements that prevent cracks from
propagating. The Ractor isolation boundary is a natural **Bulkhead**,
partitioning the system into watertight compartments.

### The Chain of Failure

The sequence from fault → error → failure is a **Chain of Failure**. Each
link increases the probability of subsequent links. Events are not
independent—a slow dependency makes application OOM *more* likely.

Serverons break the chain:
- **Timeouts** prevent indefinite waiting
- **Circuit Breakers** stop calling failing dependencies
- **Bulkheads** (Ractor isolation) contain failures
- **Supervision** (Tendons) detect death and restart

### Avoiding Antipatterns

Serverons must avoid the **Blocked Threads** antipattern—the proximate cause
of most application failures. A running process with every Ractor waiting
for something that will never come. From the user's perspective: failure.

Every blocking operation needs a timeout. **Hope is not a design method.**

---

## The Umi Mindset

Serverons and Tendons embody a different way of thinking about Ruby programs:

1. **Isolated long-running processes are the default.** Not an optimization,
   not added at boundaries—the default mode of existence.

2. **The supervision tree IS the architecture.** Failure domains, restart
   strategies, dependency ordering—these aren't configuration, they're the
   system design.

3. **Ruby's expressiveness lives WITHIN each serveron.** DSLs, method_missing,
   blocks, all the Ruby goodness—but within a Ractor's isolation boundary.

4. **Message passing BETWEEN serverons.** Ports, not method calls. Tagged
   tuples, not exceptions. Timeouts as control flow.

5. **Identity survives process death.** Registry names, not Ractor refs. A
   serveron's identity persists even when its Ractor restarts.

6. **Each serveron has its own concerns.** Not administrative metadata
   imposed from outside, but first-person questions: "How do I know I'm
   healthy?" "What do I need to function?" "How do I gracefully wind down?"

---

## Summary

| Concept | Meaning |
|---------|---------|
| **Serveron** | The fundamental unit of server-ness. A holon—complete in itself, part of a larger system. Has its own lifecycle, state, health, purpose. |
| **Tendon** | One who tends. Connects serverons to structure, transmits signals, revives the fallen. Itself a holon, part of a holarchy. |
| **Holon** | A whole that is simultaneously a part. Self-asserting AND integrating. The supervision tree is a holarchy of holons. |
| **Steady State** | A serveron that can run indefinitely without human intervention. Every accumulation mechanism has a corresponding recycling mechanism. |
| **Crackstopper** | A design element preventing failure propagation. Timeouts, circuit breakers, bulkheads, supervision boundaries. |

---

## Discussion: Ruby Idioms vs Serveron Patterns

This section explores the mapping between familiar Ruby concepts and their
serveron equivalents—what translates, what doesn't, and what's genuinely new.

### Lifecycle: Ruby Objects vs Serverons

| Ruby | Serveron | The Gap |
|------|----------|---------|
| `initialize` | `init` | Similar purpose, but Ruby's initialize is synchronous, in shared memory. Serveron's init is inside an isolation boundary, can fail without killing caller. |
| `ObjectSpace.define_finalizer` | `terminate` | Finalizers are GC-triggered, timing uncertain, often never called if process exits. Serveron's terminate is an explicit lifecycle event with timeout. |
| *(nothing)* | steady state | Ruby objects are "ready" instantly after initialize. Serverons may need to establish connections, warm caches, verify dependencies before accepting work. |
| GC'd when unreachable | supervised death | Ruby objects silently disappear. Serverons have witnessed death—someone notices and decides what to do. |

Ruby objects have no concept of "becoming ready" or "winding down." They exist
or they don't. Serverons have a lifecycle with distinct phases, each with its
own concerns.

### Dependencies: require vs Runtime Availability

| Ruby | Serveron | The Gap |
|------|----------|---------|
| `require 'foo'` | hard dependency declaration? | `require` is load-time, file-based, all-or-nothing. Serveron dependencies are runtime, can be up/down/degraded. |
| Method call to collaborator | message to port | Method call assumes collaborator exists and is responsive. Message passing assumes nothing—timeout is natural. |
| Dependency injection (passing objects) | Registry lookup? Port passing? | DI gives you a reference you can call. What's the serveron equivalent? |
| `rescue` when dependency fails | circuit breaker state | Ruby: catch exception, maybe retry. Serveron: track failures, trip circuit, fail fast, recover later. |

**The missing concept in Ruby**: "This dependency is *down* right now, but might
come back."

Ruby's model is:
- It exists and works, OR
- It doesn't exist (LoadError), OR
- It raises an exception (handle it)

No first-class concept of "temporarily unavailable, operating in degraded mode,
will retry later." This is what **Circuit Breakers** provide.

### Identity: References vs Names

| Ruby | Serveron | The Gap |
|------|----------|---------|
| `object_id` | Ractor reference | Object_id is stable until GC. Ractor ref is stable until Ractor dies—then useless. |
| Object reference (variable) | ??? | Reference lets you call methods directly. What "holds" a serveron? |
| Singleton pattern | named serveron in Registry | Singleton is in-memory, dies with process. Registry name survives serveron restart. |
| Global variable `$foo` | `Registry.lookup(:foo)` | Globals are shared memory. Registry is lookup-by-name with indirection. |
| `ObjectSpace.each_object` | `Registry.all`? | Can enumerate all objects of a class. Can enumerate all registered serverons? |

**The key shift**: Ruby identity is *reference-based*—I have a pointer to the
object. Serveron identity is *name-based*—I know its name, I look it up, the
actual Ractor behind the name may have changed since last time.

This is why identity survives death: the name persists even when the Ractor
is replaced.

### Error Handling: Exceptions vs Supervised Crashes

| Ruby | Serveron | The Gap |
|------|----------|---------|
| `raise` | crash (let the Ractor die) | Exception propagates up call stack. Crash is contained in Ractor. |
| `rescue` | tendon's restart strategy | Rescue handles error in-band. Tendon handles death out-of-band. |
| `ensure` | `terminate` callback | Ensure runs on exception. Terminate runs on shutdown signal. |
| `retry` | restart from tendon | Retry re-runs same code path. Restart re-runs from init (clean slate). |
| Exception backtrace | ??? | Backtrace shows call stack. What shows crash history of a serveron? |

**The key shift**: Ruby exceptions are *synchronous, in-band, propagating*.
Serveron failures are *asynchronous, out-of-band, contained*.

The caller doesn't catch your exception—your tendon notices your death. This
is **Let It Crash**: instead of defensive coding everywhere, crash cleanly
and let supervision handle recovery.

### Metaprogramming: What Survives Isolation

| Ruby | Serveron | Status |
|------|----------|--------|
| `method_missing` | proxy forwarding across Ractor | **Works!** This is how the proxy operates. |
| `define_method` | dynamic methods inside Ractor | **Works** within a single Ractor. |
| `included` / `extended` callbacks | ??? | Module composition—TBD how this works for serverons. |
| `const_missing` | ??? | Auto-loading—does this make sense for serverons? |
| `instance_variable_get` on other objects | **Forbidden** | Violates isolation boundary. |
| `class_eval` with external binding | **Forbidden** | Can't share bindings across Ractors. |
| `ObjectSpace` tricks | **Forbidden** | Can't enumerate across Ractor boundaries. |

**What survives**: method_missing, define_method, class macros (like
`attr_accessor`-style DSLs)—as long as they operate within a single Ractor.
Ruby's expressiveness lives *inside* the serveron.

**What doesn't survive**: Anything that reaches into another object's internals.
No cross-Ractor introspection, no binding manipulation, no shared mutable state.

### Parallel Patterns Worth Exploring

#### `attr_accessor` vs State Access

```ruby
# Ruby: direct memory access
class Counter
  attr_accessor :count
end
obj = Counter.new
obj.count      # read from memory
obj.count = 5  # write to memory
```

```ruby
# Serveron: message passing with same syntax?
serveron.count      # synchronous call (message, wait for reply)
serveron.count = 5  # asynchronous cast (message, don't wait)?
```

The syntax could be identical but the semantics are utterly different. Ruby
developers get familiar syntax; the serveron abstraction handles the messaging.

#### Singleton vs Named Serveron

```ruby
# Ruby singleton: in-memory, dies with process
class Config
  include Singleton
end
Config.instance.get(:database_url)

# Serveron equivalent: survives restarts
Registry.lookup(:config).get(:database_url)
```

The singleton pattern gives you *the one instance*. A named serveron gives you
*the current instance with that name*—which might be a fresh restart of a
crashed predecessor.

#### `require` vs Runtime Dependency

```ruby
# Ruby: fail at load time if missing
require 'redis'
# If redis gem isn't installed, LoadError immediately

# Serveron: what's the equivalent?
class MyServeron < Umi::Serveron
  depends_on :redis_pool        # hard dependency?
  soft_depends_on :cache        # can degrade without?

  def init(args)
    # Tendon ensures :redis_pool is available before starting me?
    # Or I check and enter degraded mode if missing?
  end
end
```

This is an open design question. Should serverons declare dependencies that
tendons enforce? Or discover them at runtime?

#### Method Call vs Message

```ruby
# Ruby: synchronous, assumes existence, raises on failure
result = collaborator.do_thing(arg)
# If collaborator is nil: NoMethodError
# If do_thing fails: exception propagates

# Serveron: timeout-aware, failure-aware
case serveron.do_thing(arg, timeout: 5.0)
in [:ok, result]    then handle_success(result)
in [:error, reason] then handle_error(reason)
in nil              then handle_timeout
end
```

The serveron version is more verbose but encodes the reality that remote calls
can timeout or fail. The Ruby version assumes a world where method calls always
complete (or raise).

### Open Questions

These questions emerged from exploring Ruby↔Serveron mappings:

1. **Should serverons have something like `require` for runtime dependencies?**
   A declaration of "I need these other serverons" that the tendon verifies
   before starting me?

2. **What's the serveron equivalent of a module/mixin?** Shared behavior
   composed into multiple serveron types. Does `include` work inside a Ractor?
   Are there "serveron concerns" like Rails concerns?

3. **How do Ruby-idiomatic DSLs work inside a serveron?** Can I use
   `attr_accessor`, `define_method`, class-level macros freely? What about
   DSLs that store state in class variables?

4. **What's the equivalent of `ObjectSpace.each_object(SomeServeron)`?**
   Probably Registry queries, but what's the API? Filter by type? By state?

5. **Can serverons have "class methods"?** Or is everything instance-based
   because each serveron is a running Ractor? What about factory methods?

6. **How do we express "I'm degraded but alive"?** Ruby has no standard way
   to express partial functionality. Serverons need this for circuit breaker
   half-open states, missing soft dependencies, etc.

7. **What does `super` mean across serveron boundaries?** If serverons form
   a hierarchy (not just supervision, but behavioral inheritance), how does
   that work with isolation?

### What Ruby Gives Us

Despite the differences, Ruby offers valuable tools for serverons:

- **Blocks and Procs**: Natural for callbacks, can become shareable with
  `Ractor.shareable_proc`
- **Symbols**: Naturally shareable, perfect for message tags and registry names
- **Pattern matching**: Excellent for handling message types (case/in)
- **method_missing**: Enables transparent proxy pattern
- **Refinements**: Scoped monkey-patching that respects boundaries
- **Frozen objects**: Naturally shareable across Ractors

### Tentative Non-Goals (Subject to Revision)

Some things we're *probably* not trying to do, but these are exploratory
thoughts, not firm commitments:

- **Not trying to make Ractors invisible**: The isolation boundary is real
  and important. We're making it *ergonomic*, not *hidden*. (But how ergonomic?
  TBD.)

- **Not trying to port Elixir/OTP**: We're solving similar problems with
  Ruby idioms, not translating Elixir syntax. (But we should learn from OTP's
  decades of refinement.)

- **Not trying to make all Ruby code work**: Some patterns (shared mutable
  state, cross-object introspection) are fundamentally incompatible with
  isolation. (But which patterns can we preserve? Which matter most?)

---

## Addendum: Lessons from Background Job Systems

*Reflections prompted by Ben Sheldon's "Reflections on GoodJob for Solid Queue"
(October 2023), read in the context of Umi's design.*

Background job systems like GoodJob and Solid Queue solve a subset of the
problems Umi addresses—but they've been battle-tested in production Ruby
environments. Their hard-won insights are worth incorporating.

### SIGKILL Safety as Default Assumption

Sheldon prioritizes recovering from abrupt shutdowns using mechanisms that
auto-release on disconnection (Advisory Locks), avoiding timeout-based recovery
that creates retry latency.

**For Umi**: Design for ungraceful death as the *normal* case, not the edge
case. The Proctor fix (closing IO handles before joining threads) embodies this
—when child processes inherit file descriptors, the "clean" shutdown path hangs.
The fix assumes the messy path.

Every Serveron concern in section 4 (Termination / Death) should be re-examined
through this lens: "What if I'm SIGKILLed mid-operation?"

### The Nuance of "Why It Died"

Sheldon identifies that teams need to distinguish between:
- Retried jobs (transient failure, worth another try)
- Stopped retries (gave up after N attempts)
- Explicit discards (intentional, "this job is invalid")
- Interrupted processes (SIGKILL, external termination)
- Unhandled errors (bugs)

Each routes differently to exception trackers, metrics, and operator attention.

**For Umi**: The current `:permanent`/`:temporary`/`:transient` restart types
capture *policy* but not *cause*. A Serveron's death notification might need to
distinguish:

| Death Type | Meaning | Typical Response |
|------------|---------|------------------|
| `:normal` | Clean exit, work complete | Don't restart (unless permanent) |
| `:error` | Unhandled exception | Restart, notify exception tracker |
| `:shutdown` | Graceful stop requested | Don't restart |
| `:killed` | External termination (SIGKILL) | Restart, maybe investigate |
| `:timeout` | Watchdog killed it | Restart, definitely investigate |

This is richer than `:exited`/`:aborted` from `Ractor#monitor`. The Tendon might
need to infer or track additional context.

### Process Harnesses: The Shared Infrastructure

> "Queue backends involve substantial operational overlap with web servers:
> signal handling, timeouts, health checks, and scaling instrumentation across
> platforms like Kubernetes, systemd, and Heroku."

Sheldon sees this as a common layer that shouldn't be reimplemented per-system.

**For Umi**: This validates the Coordinator's role. The signal handling,
shutdown sequencing, health checks, and external supervision integration in
`ini.md` aren't specific to any application—they're the *harness* that any
long-running Ruby process needs.

Umi's value proposition might be: "The process harness layer that GoodJob,
Solid Queue, and your custom services can all build on."

### Organizing by Promise, Not Purpose

Sheldon advocates organizing queues by maximum latency SLOs (`latency_15s`,
`latency_15m`, `latency_8h`) rather than functional purpose (`email_queue`,
`payment_queue`).

The insight: the **promise** (latency bound, failure tolerance) should be the
organizing principle, not the **purpose** (what work is done).

**For Umi**: This suggests supervision trees might be organized not by what
serverons *do* but by their **operational characteristics**:

```
root_sup
├── critical_sup (intensity=0, latency_ms)     # Payment processing
│   └── payment_worker
├── standard_sup (intensity=3, latency_sec)    # User requests
│   ├── api_handler
│   └── session_manager
└── background_sup (intensity=10, latency_min) # Batch work
    ├── report_generator
    └── cleanup_worker
```

A payment worker and an API handler might be functionally unrelated, but if they
have the same latency requirements and failure tolerance, they might belong
under the same supervisor configuration.

This also connects to the Serveron's "Contract" concern: "What do I promise?"
isn't just documentation—it's a classification that affects supervision strategy.

### Identity vs Routing

Sheldon advocates using labels for identity and reserving queue names for
routing/SLOs. Don't overload one concept with both meanings.

**For Umi**: We already separate these—Registry names are for identity,
supervision tree position is for restart policy. But it's worth being explicit:

- **Registry name**: "Who am I?" — survives restarts, how clients find me
- **Supervisor placement**: "What happens when I die?" — restart policy, blast radius
- **Labels/metadata**: "What kind of thing am I?" — for introspection, filtering

### Performance Philosophy: Knowing Your Scale

> "GoodJob targets small-to-medium projects, prioritizing operational simplicity
> over raw throughput."

**For Umi**: This is the right positioning. Umi isn't competing with BEAM for
massive scale—it's bringing resilience patterns to Ruby projects that currently
have *none*. A Ruby shop with 10 background workers doesn't need BEAM's million-
process capacity. They need: "When one worker hangs, the others keep running."

The goal is making OTP patterns *accessible*, not making Ruby as fast as Erlang.

### The Test Is Real Systems

Sheldon emphasizes that responsive iteration from real usage is essential. The
patterns that survive are the ones that solve actual problems.

**For Umi**: The plan documents are theoretical. The "Open Questions" sections
are honest about uncertainty. The real test is building systems—like the
`worker_pickaxe` that prompted investigating Proctor's thread cleanup—and
discovering what breaks, what's missing, and what patterns emerge.

### Where Does Umi End?

This reflection raises a scoping question: Should Umi include a job queue
abstraction, or is that a separate layer?

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Application Layer                                                          │
│  (GoodJob, Solid Queue, your app)                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│  Job Queue Abstraction (maybe)                                              │
│  (Enqueue, dequeue, retry, scheduling)                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│  Umi Layer                                                                  │
│  (Serverons, Tendons, Registry, Coordinator, Proctor)                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  Ruby 4.0 Primitives                                                        │
│  (Ractor, Port, monitor, Thread, Fiber)                                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

GoodJob and Solid Queue are complete job queue systems. Umi might be the
*process harness* layer beneath them—or might include enough job-queue-like
functionality (scheduled work, retry policies, persistence) to obviate separate
systems for some use cases.

This is an open question. The answer will emerge from building real systems.

---

*This document captures design thinking from January 2026. The concepts will
evolve as we build real systems and discover what patterns emerge.*
