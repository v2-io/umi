# OTP Principles: A Language-Agnostic Analysis

This document distills the principled foundations of OTP-style fault-tolerant
systems, separating what's essential from what's BEAM-specific implementation
detail.

The analysis assumes only:
- **Isolation units**: Share-nothing concurrent execution contexts
- **Message passing**: Asynchronous communication between units
- **Death notification**: Ability to observe when a unit terminates

These primitives exist in Ruby 4.0 Ractors, Erlang processes, and other
actor-like systems.

---

## Table of Contents

1. [The Fundamental Problems](#the-fundamental-problems)
2. [The Principled Layers](#the-principled-layers)
3. [Distribution Layers](#distribution-layers)
4. [What's NOT Principled (BEAM-Specific)](#whats-not-principled-beam-specific)
5. [The Minimal Principled Stack](#the-minimal-principled-stack)
6. [The Composability Insight](#the-composability-insight)

---

## The Fundamental Problems

Any system built on share-nothing isolation units with message passing faces
these problems. They are not BEAM-specific—they are inherent to the model.

### Problem 1: Death is Silent

When an isolation unit dies, its work stops, but the system doesn't
automatically know or care. Messages sent to it vanish. State is lost.

**Without solving this**: Failures silently corrupt system behavior. Work
disappears. Clients wait forever for responses that will never come.

### Problem 2: Death is Contagious (or Invisible)

Either failures cascade uncontrollably (one death triggers others), or they're
swallowed and the system limps along in a degraded state nobody detects.

**Without solving this**: Either everything dies from any failure, or nothing
"really" dies and you accumulate zombie states, leaked resources, and silent
corruption.

### Problem 3: Startup Order Matters

Services depend on other services. The database pool must exist before the
web handlers. The configuration must be loaded before anything that reads it.

**Without solving this**: Non-deterministic boot failures. "Works on my machine."
Race conditions that only manifest under load.

### Problem 4: Shutdown is Harder Than Startup

Graceful shutdown requires:
- Reverse-dependency ordering (stop dependents before dependencies)
- Draining in-flight work (don't drop requests on the floor)
- Coordinating across units (everyone agrees it's time to stop)
- Bounded time (don't wait forever for a hung unit)

**Without solving this**: Data loss on deploy. Orphaned resources. Corrupted
state from half-finished operations. Hung shutdowns requiring SIGKILL.

### Problem 5: Naming and Discovery

"Send a message to the database connection pool" requires resolving that
intent to an actual address. But addresses change—units restart, move, scale.

**Without solving this**: Hardcoded addresses. No ability to restart or replace
services without updating all callers. Tight coupling everywhere.

### Problem 6: Distribution Multiplies Everything

All the above problems exist locally. Distribution adds:
- Network partitions (some nodes can't see others)
- Message delay, reordering, duplication
- Partial failure (some nodes up, some down)
- Clock skew (no global time)

**Without solving this**: Distributed systems that only work on good networks.
Split-brain. Data loss. Inconsistency.

---

## The Principled Layers

Given only isolation units, message passing, and death notification, these
layers address the fundamental problems in a composable way.

### Layer 0: Observation

Before anything else, you need to **detect** when an isolation unit terminates.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  OBSERVATION PRIMITIVE                                                      │
│                                                                             │
│  monitor(unit) → receive notification when unit terminates                 │
│                                                                             │
│  The notification includes:                                                 │
│    - Which unit died                                                       │
│    - Why (normal exit, error, killed)                                      │
│                                                                             │
│  This is the foundation. Without it, nothing above is possible.            │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Properties**:
- Monitoring is unidirectional (observer doesn't die when observed dies)
- Notifications are guaranteed if the monitor was established
- Multiple observers can monitor the same unit

**Ruby 4.0**: `Ractor#monitor(port)` sends `:exited` or `:aborted` to the port.

**Erlang**: `erlang:monitor(process, Pid)` sends `{'DOWN', Ref, process, Pid, Reason}`.

### Layer 1: Lifecycle Policy (Supervisor)

**Principle**: Separate the "what to do when something dies" policy from the
thing that might die.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  SUPERVISOR                                                                 │
│                                                                             │
│  An isolation unit whose only job is:                                       │
│                                                                             │
│    1. Start children according to specifications                           │
│    2. Monitor all children                                                 │
│    3. Apply a restart policy when children die                             │
│    4. Bound restart rate (don't spin on persistent failures)               │
│    5. Propagate shutdown to children in controlled order                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Restart Policies** (the supervisor decides which to apply):

| Policy | Behavior |
|--------|----------|
| Restart | Start a new instance of the dead child |
| Restart with backoff | Restart, but with increasing delays |
| Restart dependents | Restart this child and those that depend on it |
| Restart all | Restart all children (they have interdependencies) |
| Ignore | Let it stay dead (temporary/optional work) |
| Escalate | I can't handle this—tell my supervisor |

**Restart Bounding**:

```
max_restarts: 3
within_period: 5 seconds

If a child restarts more than 3 times in 5 seconds,
the supervisor gives up and escalates (dies itself).
```

This prevents infinite restart loops from consuming all resources.

**Why this is principled**: Workers shouldn't contain restart logic—they should
do their job and die cleanly if they can't. Separating policy from mechanism:
- Keeps workers simple and testable
- Allows the same worker with different failure strategies
- Makes failure handling explicit and visible

**Child Specification**:

```
{
  id: unique_identifier,
  start: how_to_start_it,
  restart: :permanent | :temporary | :transient,
  shutdown: timeout_or_brutal_kill,
  type: :worker | :supervisor
}
```

The specification is data, not code—supervisors can be configured, serialized,
introspected.

### Layer 1b: Worker Pattern (What Goes Inside a Supervised Child)

The layers above define how workers are *organized*—started, stopped, restarted,
named. But what does a worker *do internally*? This is the **communication pattern**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  WORKER (abstract)                                                          │
│                                                                             │
│  An isolation unit that:                                                    │
│    1. Maintains internal state across requests                             │
│    2. Receives messages from clients                                       │
│    3. Processes requests (possibly using pure functional "core" logic)     │
│    4. Sends responses back to clients                                      │
│    5. Loops until told to stop                                             │
│                                                                             │
│  The key questions:                                                         │
│    - How does the client indicate where to send the response?              │
│    - How does the worker dispatch different message types?                 │
│    - How does backpressure work?                                           │
│    - How are timeouts handled?                                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Erlang/Elixir (GenServer)** solves this with:
- Single mailbox + selective receive + pattern matching for dispatch
- `call` (sync) vs `cast` (async) for backpressure control
- Implicit `from` parameter for reply routing
- Built-in timeouts in `GenServer.call`

**Ruby 4.0 Ports** enable a simpler approach:
- Multiple ports for different message types (structural dispatch)
- Reply port provided by caller in the message (explicit routing)
- Client chooses whether to wait (backpressure is caller's choice)
- Timeouts via `Ractor.select` with timer port (composable)

See [GenServer Analysis](./genserver-analysis.md) for detailed comparison and
Ruby 4.0 patterns.

**Beyond request/response**: Workers aren't limited to the request/response
pattern. Common variations include:

- **Tasks**: One-shot concurrent work (fire, do other work, collect result)
- **Pools**: Bounded concurrency for expensive resources (DB connections)
- **Dynamic workers**: Processes created on demand (per-user, per-session)
- **Scheduled work**: Delayed or periodic execution

See [Worker Patterns](./worker-patterns.md) for these abstractions and Ruby 4.0
equivalents.

**Why this matters for Umi**: The worker pattern is where Ruby 4.0's Port model
offers the most significant simplification over traditional actor models. The
same supervision architecture applies, but the internal communication is cleaner.

### Layer 2: Hierarchy (Supervision Tree)

**Principle**: Structure supervision into a tree where failure propagation is
explicit and bounded.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  SUPERVISION TREE                                                           │
│                                                                             │
│  root_sup                                                                   │
│  │                                                                         │
│  ├── critical_sup (intensity=0: any child death = escalate)                │
│  │   ├── worker_a (permanent: always restart)                              │
│  │   └── worker_b (permanent: always restart)                              │
│  │                                                                         │
│  └── degradable_sup (intensity=5: tolerate some failures)                  │
│      ├── worker_c (permanent)                                              │
│      ├── worker_d (transient: only restart on abnormal exit)               │
│      └── batch_sup (nested supervisor for batch jobs)                      │
│          ├── job_1 (temporary: never restart)                              │
│          └── job_2 (temporary: never restart)                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Properties**:

| Property | Meaning |
|----------|---------|
| **Containment** | Failure in `degradable_sup` doesn't touch `critical_sup` |
| **Escalation** | `critical_sup` failure escalates to `root_sup` |
| **Nesting** | Supervisors can supervise other supervisors |
| **Root** | `root_sup` failure = system failure (defined termination point) |

**Why this is principled**: Without explicit structure, you get either
"everything affects everything" (cascade) or "nothing affects anything"
(silent failure). Trees give you:
- Understandable failure domains
- Explicit escalation paths
- Configurable blast radius

**The Tree Invariant**: Every isolation unit (except root) has exactly one
supervisor. This means:
- Clear ownership (who restarts me?)
- No orphans (everything is accounted for)
- Single escalation path (no ambiguity)

### Layer 3: Service Grouping (Application)

**Principle**: Group related supervision trees into deployable, startable
units with declared dependencies.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  APPLICATION / SERVICE                                                      │
│                                                                             │
│  A named bundle of:                                                         │
│    - A supervision tree (the running processes)                            │
│    - Configuration (how to parameterize it)                                │
│    - Dependencies (what must start before me)                              │
│    - Lifecycle callbacks (hooks at state transitions)                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Lifecycle States**:

```
         ┌──────────────────────────────────────────────────────────┐
         │                                                          │
         ▼                                                          │
    ┌─────────┐     ┌──────────┐     ┌─────────┐     ┌──────────┐  │
    │ loading │────→│ starting │────→│ running │────→│ stopping │──┘
    └─────────┘     └──────────┘     └─────────┘     └──────────┘
         │               │                                │
         │               │                                ▼
         │               │                          ┌──────────┐
         └───────────────┴─────────────────────────→│ stopped  │
                      (on failure)                  └──────────┘
```

**Callbacks** (optional hooks):

| Callback | When | Purpose |
|----------|------|---------|
| `prepare` | Before starting | Validate config, acquire resources |
| `start` | Create supervision tree | Returns top supervisor |
| `running` | After fully started | Notify dependents, open for business |
| `stopping` | Before shutdown | Drain work, notify clients |
| `stopped` | After shutdown | Release resources, cleanup |

**Dependency Ordering**:

```
Application A depends on [B, C]
Application B depends on [D]
Application C depends on []
Application D depends on []

Start order: D, C, B, A (dependencies first)
Stop order:  A, B, D, C (dependents first)
```

**Guarantees**:
- Dependencies started before dependents
- Dependents stopped before dependencies
- Atomic start (either fully started or rolled back)

**Why this is principled**: Real systems are composed of multiple subsystems.
You need a unit of composition larger than "one supervisor tree" that:
- Has a name (for humans and tooling)
- Declares its requirements (for correct ordering)
- Can be started/stopped independently (for operations)

### Layer 4: Coordination (The Root Problem)

**Principle**: Something must be first, and its lifecycle defines system lifecycle.

See [OTP Initialization: A Deep Analysis](./otp-initialization.md) for detailed
examination of how BEAM's `init` process implements these principles, including
the two-phase coordinator pattern, boot scripts as data, and the pre-supervision
layer.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  ROOT COORDINATOR                                                           │
│                                                                             │
│  Responsibilities:                                                          │
│                                                                             │
│    Bootstrap:                                                               │
│      - Read system configuration                                           │
│      - Determine application start order                                   │
│      - Start applications in dependency order                              │
│      - Wait for each application to be fully running                       │
│                                                                             │
│    Steady State:                                                            │
│      - Monitor all applications                                            │
│      - Handle application failures (restart or escalate)                   │
│      - Accept commands (start app, stop app, reconfigure)                  │
│                                                                             │
│    Shutdown:                                                                │
│      - Receive shutdown signal (SIGTERM, explicit call)                    │
│      - Stop applications in reverse dependency order                       │
│      - Wait for graceful shutdown with timeout                             │
│      - Force-kill anything still running                                   │
│      - Exit                                                                │
│                                                                             │
│  When root coordinator dies, the system is dead.                           │
│  This is the definition, not a bug.                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Why this is principled**: Someone has to be first. The choice is whether
"first" is:
- Structurally special but passive (Ruby's main Ractor)
- Functionally responsible for coordination (BEAM's init + application_controller)

Giving it coordination duties makes system behavior understandable. "The system
is running" means "root coordinator is running and happy."

**Signal Handling**:

| Signal | Response |
|--------|----------|
| SIGTERM | Initiate graceful shutdown |
| SIGINT | Initiate graceful shutdown (or force if repeated) |
| SIGHUP | Reload configuration (if supported) |
| SIGUSR1/2 | Application-defined (dump state, rotate logs, etc.) |

**The Boring Root Principle**

The coordinator's reliability is the foundation of the entire system's isolation
guarantees. "Let it crash" only works if you **trust** that crashes lead to
restarts. That trust comes from the coordinator being simple, not from hope.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  If the root is SIMPLE and RELIABLE:                                       │
│    → Everything else can fail safely                                       │
│    → Crashes are just "restarts"                                           │
│    → System is comprehensible                                              │
│                                                                             │
│  If the root is COMPLEX or FRAGILE:                                        │
│    → Any failure might be catastrophic                                     │
│    → Can't reason about isolation                                          │
│    → "Let it crash" becomes "pray it doesn't crash"                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**The root is boring on purpose.** It should have:
- Minimal responsibilities (start, stop, monitor—that's it)
- No business logic
- Simple state (just "what's running")
- No external dependencies
- Heavily tested, rarely modified code paths

**Delegate Everything, Even I/O**

BEAM takes this principle to its logical conclusion: even "simple" things like
file I/O and logging are delegated to separate actor processes:

```
file_server_2      ← All file operations
standard_error     ← stderr handling
user               ← stdin/stdout handling
logger             ← Log message handling
```

This means:
- Disk full? The file server crashes, not the coordinator.
- Slow disk? The file server queues, coordinator continues.
- Logging fails? Logger restarts, coordinator doesn't care.
- Concurrent writes? Serialized through one actor—atomic for free.

The coordinator's **only verbs** should be Ractor primitives:

```
receive()  - Wait for message
send()     - Fire and forget
spawn()    - Start a child
monitor()  - Watch a child
```

Everything else is delegated to something that *can* fail and be restarted.

**Ractors All The Way Down**

Just as Ruby is "objects all the way down," a well-designed Umi system could be
"Ractors all the way down." File I/O, logging, configuration, health checks—all
are actors that can crash independently. The coordinator is simply the one actor
that, by being maximally boring, effectively never crashes.

This gives you true isolation: any component can fail, and the failure is
contained. The system continues. The failed component restarts. Life goes on.

### Layer 5: Naming and Discovery (Local)

**Principle**: Decouple "who I want to talk to" from "what address they're at."

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  REGISTRY                                                                   │
│                                                                             │
│  Operations:                                                                │
│    register(name, address) → :ok | {:error, :already_registered}           │
│    lookup(name) → {:ok, address} | :not_found                              │
│    unregister(name) → :ok                                                  │
│    list() → [{name, address}]                                              │
│                                                                             │
│  Properties:                                                                │
│    - Names are unique within a scope                                       │
│    - Registration auto-unregisters when registrant dies                    │
│    - Lookup is fast (this is on the hot path)                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Scoping Options**:

| Scope | Meaning |
|-------|---------|
| Global | One namespace for entire node |
| Per-application | Names scoped to application (avoids collisions) |
| Per-supervisor | Names scoped to subtree (hierarchical naming) |

**Why auto-unregister matters**: Without it, you get stale registrations
pointing to dead addresses. Every lookup might return a corpse. Auto-unregister
(via monitoring) ensures names always point to live units.

**Registration Patterns**:

```
# Named singleton
register(:database_pool, my_address)

# Named with key (multiple instances)
register({:connection, connection_id}, my_address)

# Via supervisor (name part of child spec)
child_spec = {id: :db, name: :database_pool, ...}
```

**Critical for Ruby: Registry is Essential, Not Optional**

In BEAM, process identifiers (PIDs) are **serializable first-class values**:
- Can be stored in state, sent in messages, written to disk
- Can be sent across nodes
- Survive serialization/deserialization

In Ruby 4.0, Ractor references are **opaque and non-serializable**:
- Cannot be marshaled
- Cannot be stored in checkpointable state
- Lost if the referencing worker crashes and restores

This has a profound implication:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  BEAM: Registry is CONVENIENT                                              │
│        PIDs work fine in state, names are just nicer                       │
│                                                                             │
│  Ruby: Registry is ESSENTIAL                                               │
│        Ractor refs cannot be serialized                                    │
│        Names are the ONLY way to persist references to other Ractors       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

If your worker state includes "reply to this Ractor" or "my children are these
Ractors," you must store **names** (symbols, strings) not **references**:

```ruby
# Cannot checkpoint this:
state = { reply_to: some_ractor }  # NOT serializable

# Can checkpoint this:
state = { reply_to: :user_session_42 }  # Serializable name

# On restore, look it up:
reply_ractor = Registry.lookup(:user_session_42)
```

This also means that after a crash, the **name** survives even if the physical
Ractor is replaced by a new one—which is exactly the behavior you want.

See [Strategic Checkpointing](./strategic-checkpointing.md) for more on state
serialization patterns.

### Layer 6: Group Membership

**Principle**: Sometimes you need "all the things of type X" not "the one
thing named Y."

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  PROCESS GROUPS                                                             │
│                                                                             │
│  Operations:                                                                │
│    join(group, address) → :ok                                              │
│    leave(group, address) → :ok                                             │
│    members(group) → [address]                                              │
│                                                                             │
│  Messaging patterns:                                                        │
│    broadcast(group, message) → send to all members                         │
│    notify(group, message) → send to one member (random or round-robin)     │
│                                                                             │
│  Properties:                                                                │
│    - Multiple members per group                                            │
│    - Same address can join multiple groups                                 │
│    - Membership auto-removed when member dies                              │
│    - Membership is not globally ordered (eventual consistency ok)          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Use Cases**:

| Pattern | How Groups Help |
|---------|-----------------|
| Pub/sub | Subscribers join topic group, publisher broadcasts |
| Worker pool | Workers join pool group, work distributed via notify |
| Sharding | Each shard joins its shard group |
| Replication | Replicas join replica group for coordination |

**Why this is principled**: Registry gives you 1:1 (name → address). Groups
give you 1:N and N:1. Both are needed.

---

## Distribution Layers

These layers address the additional problems that arise when isolation units
span multiple machines connected by unreliable networks.

### Layer 7: Node Discovery

**Principle**: Nodes must find each other before they can communicate.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  DISCOVERY                                                                  │
│                                                                             │
│  Input: Some configuration or protocol                                     │
│  Output: Set of {node_id, address} pairs                                   │
│                                                                             │
│  Mechanisms (choose based on environment):                                  │
│                                                                             │
│    Static configuration:                                                    │
│      nodes: ["node1.example.com:4000", "node2.example.com:4000"]           │
│      Simple, but doesn't handle dynamic scaling                            │
│                                                                             │
│    DNS-based:                                                               │
│      Query SRV records or A records for service name                       │
│      Works well with Kubernetes headless services                          │
│                                                                             │
│    Registry service (Consul, etcd, EPMD):                                  │
│      Nodes register themselves, query for others                           │
│      More moving parts, but handles dynamic membership                     │
│                                                                             │
│    Gossip / peer exchange:                                                  │
│      Nodes tell each other about other nodes they know                     │
│      Decentralized, but slower to converge                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Why this is principled**: You can't skip this. Something must answer "who
else is out there?" The mechanism varies by deployment environment.

### Layer 8: Connection Management

**Principle**: Separate "establishing connectivity" from "using connectivity."

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  CONNECTION MANAGER                                                         │
│                                                                             │
│  Responsibilities:                                                          │
│                                                                             │
│    Establishment:                                                           │
│      - Open connection to discovered nodes                                 │
│      - Perform handshake (protocol version, capabilities)                  │
│      - Authenticate (prove we're allowed to connect)                       │
│                                                                             │
│    Monitoring:                                                              │
│      - Send periodic heartbeats                                            │
│      - Detect unresponsive connections                                     │
│      - Report connection state changes                                     │
│                                                                             │
│    Recovery:                                                                │
│      - Reconnect on transient failures                                     │
│      - Backoff to avoid thundering herd                                    │
│      - Give up after persistent failures                                   │
│                                                                             │
│  This is the COLD PATH. Optimized for correctness, not speed.              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Connection States**:

```
    ┌────────────────────────────────────────────────────────┐
    │                                                        │
    ▼                                                        │
┌───────────┐     ┌────────────┐     ┌───────────┐          │
│discovered │────→│ connecting │────→│ connected │──────────┤
└───────────┘     └────────────┘     └───────────┘          │
                        │                  │                 │
                        │                  │ (disconnect)    │
                        ▼                  ▼                 │
                  ┌───────────────────────────┐              │
                  │    disconnected           │──────────────┘
                  │    (retry with backoff)   │
                  └───────────────────────────┘
                        │
                        │ (max retries)
                        ▼
                  ┌───────────────────────────┐
                  │    failed                 │
                  │    (needs rediscovery)    │
                  └───────────────────────────┘
```

### Layer 9: Message Transport

**Principle**: Once connected, message delivery should be fast and
location-transparent.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  TRANSPORT                                                                  │
│                                                                             │
│  Operations:                                                                │
│    send(remote_address, message) → :ok | {:error, :not_connected}          │
│                                                                             │
│  Guarantees (choose your semantics):                                        │
│    - At-most-once: Message delivered 0 or 1 times (fire and forget)        │
│    - At-least-once: Message delivered 1+ times (with retries, may dup)     │
│    - Exactly-once: Message delivered exactly 1 time (requires tracking)    │
│                                                                             │
│  This is the HOT PATH. Optimized for throughput and latency.               │
│                                                                             │
│  Implementation concerns:                                                   │
│    - Serialization format (binary, JSON, protobuf, ETF)                    │
│    - Batching (amortize syscall overhead)                                  │
│    - Flow control (don't overwhelm slow receivers)                         │
│    - Encryption (TLS, noise protocol)                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**BEAM insight**: Message delivery is in C (the VM), not Erlang. Connection
management is in Erlang (net_kernel). This separation is principled—the
hot path should be as fast as possible.

### Layer 10: Distributed Naming

**Principle**: Extend local naming across nodes, accepting trade-offs.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  DISTRIBUTED REGISTRY                                                       │
│                                                                             │
│  The CAP theorem applies. Choose your trade-off:                           │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │  STRONG CONSISTENCY (CP)                                              │ │
│  │                                                                       │ │
│  │  - One name → one address, cluster-wide                               │ │
│  │  - Registration requires coordination (consensus or locking)          │ │
│  │  - Lookup may block or fail during partition                          │ │
│  │  - Good for: leader election, unique resources                        │ │
│  │                                                                       │ │
│  │  BEAM example: `global` module                                        │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │  EVENTUAL CONSISTENCY (AP)                                            │ │
│  │                                                                       │ │
│  │  - Each node authoritative for its own registrations                  │ │
│  │  - No coordination on write                                           │ │
│  │  - Lookup always succeeds (with local data)                           │ │
│  │  - Different nodes may see different views temporarily                │ │
│  │  - Good for: presence, discovery, load balancing                      │ │
│  │                                                                       │ │
│  │  BEAM example: Phoenix.Tracker                                        │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  Most real systems need BOTH for different use cases.                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Layer 11: Partition Handling

**Principle**: Decide what happens when the network splits, before it splits.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  PARTITION STRATEGY                                                         │
│                                                                             │
│  When nodes can't communicate, options are:                                 │
│                                                                             │
│  Optimistic (keep going):                                                   │
│    - Each partition continues operating                                    │
│    - Conflicting state must be merged later                                │
│    - Requires conflict resolution strategy (CRDTs, LWW, manual)            │
│                                                                             │
│  Pessimistic (stop):                                                        │
│    - Minority partition stops accepting writes                             │
│    - Requires quorum calculation                                           │
│    - May require fencing (STONITH) to prevent split-brain                  │
│                                                                             │
│  Hybrid:                                                                    │
│    - Some operations allowed (reads, local writes)                         │
│    - Some operations blocked (global transactions)                         │
│                                                                             │
│  BEAM's approach: Force clean partitions                                    │
│    - Detect overlapping partitions                                         │
│    - Forcibly disconnect to create non-overlapping groups                  │
│    - Each group is internally consistent                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## What's NOT Principled (BEAM-Specific)

These exist in BEAM's OTP but are implementation choices, not universal
requirements:

| Feature | Why BEAM Has It | Alternative |
|---------|-----------------|-------------|
| `code_server` | Hot code loading | Don't hot-swap (restart instead) |
| `file_server_2` | Serialized file access | Native file I/O (most languages) |
| `user` / `standard_error` | I/O routing via group leader | Direct I/O to stdout/stderr |
| `rex` (RPC server) | Synchronous cross-node calls | Request/response over messages |
| EPMD (separate daemon) | Discovery for C nodes too | Built-in discovery, DNS, etc. |
| Cookie authentication | Simple shared secret | TLS, mTLS, tokens, etc. |
| `application_master` | I/O group leader per app | Not needed without group leader model |
| Process dictionary | Per-process mutable state | Explicit state passing |
| Registered names as atoms | Efficient lookup | String names, UUIDs, etc. |

**The point**: These are reasonable choices for BEAM's context, but a Ruby or
other implementation might choose differently without violating the principles.

---

## The Minimal Principled Stack

If building OTP-like infrastructure from scratch, these are the essential layers:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Layer 1: SUPERVISOR                                                │   │
│  │                                                                     │   │
│  │  Monitor children, apply restart policy, bound restart rate.        │   │
│  │  This is the core insight. Everything else builds on it.           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Layer 2: SUPERVISION TREE                                          │   │
│  │                                                                     │   │
│  │  Hierarchy of supervisors. Defines failure domains and             │   │
│  │  escalation paths. Supervisors supervise supervisors.              │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Layer 3: APPLICATION                                               │   │
│  │                                                                     │   │
│  │  Named bundle: supervision tree + config + dependencies.           │   │
│  │  Unit of deployment and lifecycle management.                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Layer 4: REGISTRY                                                  │   │
│  │                                                                     │   │
│  │  Name → address mapping. Auto-cleanup on death.                    │   │
│  │  Decouples intent from address.                                    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Layer 5: COORDINATOR                                               │   │
│  │                                                                     │   │
│  │  Starts applications in dependency order.                          │   │
│  │  Handles system shutdown. Defines "system alive."                  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Distribution layers (7-11) are optional**—needed only if you go multi-node.

**Process groups (layer 6) are optional**—needed for pub/sub and pool patterns.

**Everything above is built on layer 0 (observation)**—the primitive that makes
failure detection possible.

---

## The Composability Insight

OTP's deepest insight isn't any single layer—it's that **the layers compose
using the same primitives**.

```
A supervisor is just an isolation unit.
  → It can be supervised by another supervisor.
  → It can be monitored.
  → It can be named in the registry.

An application is just a supervisor with metadata.
  → It's started by the coordinator, which is just an application.

The coordinator is just an application.
  → When it dies, the system dies—by definition, not by magic.
```

**The principle**: Build each layer from the primitives of the layer below.
Don't introduce new primitives at higher layers. This means:

- Everything is observable (you can monitor anything)
- Everything is restartable (supervisors all the way down)
- Everything composes (applications can depend on applications)
- Failure handling is uniform (same patterns at every level)

**The practical implication for Umi**:

If `Umi::Supervisor` is itself a Ractor that can be monitored and restarted,
and `Umi::Application` is a supervisor with additional metadata, and the
coordinator is an application—then you get the full composability for free.

No special cases. No "this layer is different." Just isolation units,
messages, and monitors, structured thoughtfully.

---

## References

- [OTP Initialization: A Deep Analysis](./otp-initialization.md) - Deep dive
  into BEAM's init process with source code analysis
- [BEAM/OTP Process Architecture Analysis](./beam-otp-analysis.md) - Detailed
  BEAM-specific analysis with source code references
- *Release It!* by Michael Nygard - The failure modes these patterns address
- *Designing for Scalability with Erlang/OTP* - OTP patterns in depth
- [Umi First Principles](./UMI_FIRST_PRINCIPLES.md) - How these principles
  apply to Ruby 4.0
