# BEAM/OTP Process Architecture Analysis

This document analyzes how BEAM/OTP organizes processes, handles distribution, and
manages applications—with comparison to Ruby 4.0's main Ractor concept.

## Table of Contents

1. [Ruby 4.0: The Main Ractor](#ruby-40-the-main-ractor)
2. [BEAM/OTP: Layered Process Hierarchy](#beamotp-layered-process-hierarchy)
3. [The Kernel Application in Detail](#the-kernel-application-in-detail)
4. [Node Distribution Mechanism](#node-distribution-mechanism)
5. [Network Topology and Partitions](#network-topology-and-partitions)
6. [Application Lifecycle](#application-lifecycle)
7. [Higher-Level Distributed Patterns: Phoenix Tracker](#higher-level-distributed-patterns-phoenix-tracker)
8. [Comparison Table](#comparison-table)

---

## Ruby 4.0: The Main Ractor

The **main Ractor** is the first Ractor created when the Ruby interpreter starts.

### Identification

```ruby
Ractor.main      # Returns the main Ractor
Ractor.main?     # Returns true if current Ractor is main
Ractor.current   # Returns current Ractor (may or may not be main)
```

### Special Privileges

| Capability                              | Main Ractor | Other Ractors |
|-----------------------------------------|-------------|---------------|
| Access global variables                 | ✓           | ✗             |
| Access non-shareable constants          | ✓           | ✗             |
| Set instance vars on classes/modules    | ✓           | ✗ (even shareable values) |
| Get instance vars with unshareable vals | ✓           | ✗             |

### Termination Semantics

When the main Ractor terminates, **all other Ractors receive terminate requests**.
This mirrors how Threads behave when the main Thread exits. The main Ractor's
lifecycle governs the entire runtime—there is no mechanism to "promote" another
Ractor to main status.

### Key Limitation

Ruby's main Ractor is a **structural** distinction (first = special), not a
**functional** one. It doesn't coordinate other Ractors—it simply has special
access privileges by virtue of being first.

---

## BEAM/OTP: Layered Process Hierarchy

Unlike Ruby's flat main/other distinction, BEAM/OTP has a deeply layered hierarchy
with distinct responsibilities at each level.

### Complete Boot Hierarchy

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           BEAM Virtual Machine                              │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ init (pid 0)                                                           │ │
│  │   The first Erlang process. Reads boot scripts, coordinates system    │ │
│  │   startup and shutdown. Registered as 'init'.                         │ │
│  │                                                                        │ │
│  │   ├── erl_prim_loader                                                  │ │
│  │   │     Primitive code loader (started very early, before kernel)      │ │
│  │   │                                                                    │ │
│  │   └── application_controller (singleton, registered)                   │ │
│  │         All application start/stop goes through this process.          │ │
│  │         Started by kernel, but logically "above" applications.         │ │
│  │                                                                        │ │
│  │         ├── kernel_master (application master for kernel)              │ │
│  │         │     └── kernel_sup (top supervisor) ──────────────────────┐  │ │
│  │         │                                        [see detail below] │  │ │
│  │         │                                                           │  │ │
│  │         ├── stdlib_master (application master for stdlib)           │  │ │
│  │         │     └── (stdlib is a library app - no supervisor)         │  │ │
│  │         │                                                           │  │ │
│  │         ├── sasl_master (if sasl started)                           │  │ │
│  │         │     └── sasl_sup                                          │  │ │
│  │         │           ├── alarm_handler                               │  │ │
│  │         │           ├── release_handler                             │  │ │
│  │         │           └── ...                                         │  │ │
│  │         │                                                           │  │ │
│  │         └── [your_app]_master                                       │  │ │
│  │               └── [your_app]_sup                                    │  │ │
│  │                     └── ...your supervision tree...                 │  │ │
│  │                                                                     │  │ │
│  └─────────────────────────────────────────────────────────────────────┘  │ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Process Roles

| Process | Role | Started By |
|---------|------|------------|
| `init` | First process, boot coordination, system shutdown | VM directly |
| `erl_prim_loader` | Primitive code loading before kernel exists | `init` |
| `application_controller` | Singleton coordinator for all applications | kernel app |
| `*_master` | Per-application lifecycle manager, group leader | `application_controller` |
| `*_sup` | Top supervisor of each application's process tree | `*_master` via callback |

---

## The Kernel Application in Detail

The kernel application is the foundation. This tree is derived directly from
`lib/kernel/src/kernel.erl` in OTP source.

### Kernel Supervisor Tree

```
kernel_sup (one_for_all, intensity=0)
│
│  ─── Core Services (permanent, critical) ───
│
├── code_server
│     Code loading and path management
│
├── file_server_2
│     File operations (may be delayed if master node configured)
│
├── standard_error (supervisor, temporary)
│     stderr handling
│
├── erl_signal_server (gen_event)
│     OS signal handling
│
├── on_load (transient)
│     Runs on_load handlers for preloaded modules
│
├── inet_db
│     Network configuration database
│
│  ─── Distribution Services (if enabled) ───
│
├── rex
│     RPC server - handles rpc:call/4 requests
│
├── global_name_server
│     Global process registry across nodes
│
├── [dist_ac]  (optional)
│     Distributed application controller
│
├── net_sup (supervisor, one_for_all) ──────────────────┐
│     Distribution supervisor                           │
│     ├── erl_epmd (or custom epmd module)              │
│     │     EPMD client - node registration             │
│     ├── auth                                          │
│     │     Cookie-based authentication                 │
│     └── net_kernel                                    │
│           Distribution coordination, connection mgmt  │
│                                                       │
├── global_group                                        │
│     Global group management                           │
│                                                       │
│  ─── User Interface ───                               │
│                                                       │
├── user (supervisor, temporary)                        │
│     User I/O handling                                 │
│                                                       │
│  ─── Logging ───                                      │
│                                                       │
├── logger_sup (supervisor) ────────────────────────────┤
│     ├── logger_handler_watcher                        │
│     ├── logger_proxy                                  │
│     └── [logger handlers...]                          │
│                                                       │
│  ─── Configuration ───                                │
│                                                       │
├── kernel_config                                       │
│     Configuration management                          │
│                                                       │
├── kernel_refc                                         │
│     Reference counting for kernel resources           │
│                                                       │
│  ─── Safe Supervisor (one_for_one, restartable) ───   │
│                                                       │
└── kernel_safe_sup (supervisor) ───────────────────────┤
      Children here CAN be restarted without           │
      bringing down the node:                          │
      ├── [boot_server]  (optional)                    │
      ├── [disk_log_server + disk_log_sup]  (optional) │
      └── [pg]  (optional, process groups)             │
```

### Supervisor Strategy Notes

From `kernel.erl` comments:

> "All supervisors except for kernel_safe_sup terminates the entire erlang node
> if any of their children dies. Any child that can't be restarted in case of
> failure must be placed under one of these supervisors. Any other child must
> be placed under safe_sup."

This is the "let it crash, but contain the blast radius" philosophy:
- Critical services (`code_server`, `net_kernel`): death = node death
- Optional services (`pg`, `disk_log`): can restart without affecting node

---

## Node Distribution Mechanism

### The Three Layers

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Layer 1: DISCOVERY (EPMD - External Daemon)                                │
│                                                                             │
│  EPMD runs as a separate OS process on each machine, port 4369.             │
│  It maps node names to TCP ports.                                           │
│                                                                             │
│  Machine A                              Machine B                           │
│  ┌─────────────────┐                   ┌─────────────────┐                  │
│  │ EPMD :4369      │                   │ EPMD :4369      │                  │
│  │  "foo@A" → 45123│                   │  "bar@B" → 52341│                  │
│  │  "baz@A" → 45678│                   │                 │                  │
│  └─────────────────┘                   └─────────────────┘                  │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  Layer 2: CONNECTION SETUP (net_kernel - Erlang Process)                    │
│                                                                             │
│  When node A wants to connect to bar@B:                                     │
│                                                                             │
│     A                      EPMD@B                    B                      │
│     │                         │                      │                      │
│     │── PORT_PLEASE2_REQ ────→│                      │                      │
│     │   "where is bar@B?"     │                      │                      │
│     │←── port 52341 ─────────│                      │                      │
│     │                         │                      │                      │
│     │──────────── TCP connect to port 52341 ────────→│                      │
│     │                                                │                      │
│     │←─────────── handshake (challenge/response) ───→│                      │
│     │              cookie-based authentication       │                      │
│     │                                                │                      │
│     │              CONNECTION ESTABLISHED            │                      │
│                                                                             │
│  net_kernel handles: connection setup, monitoring, disconnection detection  │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  Layer 3: MESSAGE TRANSPORT (VM Runtime - C Code)                           │
│                                                                             │
│  Once connected, the BEAM VM itself handles message routing.                │
│  This is NOT an Erlang process—it's native C code in the runtime.           │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                         BEAM VM                                     │    │
│  │  ┌─────────┐    ┌────────────────────┐    ┌─────────────────────┐   │    │
│  │  │ Process │───→│ Distribution       │───→│ TCP socket to       │   │    │
│  │  │ mailbox │    │ subsystem (C)      │    │ remote node         │   │    │
│  │  └─────────┘    │                    │    └─────────────────────┘   │    │
│  │                 │ - Serialization    │                              │    │
│  │                 │ - External Term    │                              │    │
│  │                 │   Format           │                              │    │
│  │                 │ - Flow control     │                              │    │
│  │                 └────────────────────┘                              │    │
│  │                          ↑                                          │    │
│  │                  net_kernel monitors                                │    │
│  │                  (setup/teardown only)                              │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  Key insight: The hot path (every message) is handled in C.                 │
│  The cold path (connection management) is handled in Erlang.                │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Node Registration Protocol

When a node starts with `-name foo@host` or `-sname foo`:

1. Node binds to a random TCP port for inter-node communication
2. Node sends `ALIVE2_REQ` to local EPMD: "I'm `foo`, listening on port N"
3. EPMD responds with `ALIVE2_X_RESP` including a "creation" number
4. Connection to EPMD is kept open—drop = automatic deregistration

### Connection Initiation Protocol

```
Initiating Node (A)                                    Target Node (B)
       │                                                         │
       │─── 1. Query EPMD@B: PORT_PLEASE2_REQ("bar") ───────────>│
       │                                                         │
       │<── 2. EPMD responds: port 52341 ────────────────────────│
       │                                                         │
       │─── 3. TCP connect to B:52341 ──────────────────────────>│
       │─── 4. send_name (my name, flags, version) ─────────────>│
       │                                                         │
       │<── 5. recv_status ("ok" or "not_allowed") ──────────────│
       │<── 6. recv_challenge (random number) ───────────────────│
       │                                                         │
       │─── 7. send_challenge_reply (digest(cookie+challenge))──>│
       │                                                         │
       │<── 8. recv_challenge_ack ───────────────────────────────│
       │                                                         │
       │         CONNECTION ESTABLISHED                          │
```

The cookie is never transmitted—only a digest proving knowledge of it.

### The `rex` Process: RPC Server

For `rpc:call(Node, M, F, A)`, there's a dedicated gen_server called `rex`:

```erlang
%% On calling node:
rpc:call(bar@B, lists, reverse, [[1,2,3]]).

%% This sends a message to rex on bar@B, which:
%% 1. Spawns a process to execute lists:reverse([1,2,3])
%% 2. Waits for the result
%% 3. Sends result back to caller
```

The `rex` process is a **serial bottleneck** for RPC—hence `erpc` (enhanced RPC)
was added in OTP 23 for better parallelism.

---

## Network Topology and Partitions

### Default: Full Mesh (Not Gossip)

BEAM's default distributed model is a **fully connected mesh**:

```
connect_all = true (default)

    A ←──────→ B
    ↑ ╲      ╱ ↑
    │   ╲  ╱   │
    │    ╲╱    │
    │    ╱╲    │
    │  ╱    ╲  │
    ↓ ╱      ╲ ↓
    C ←──────→ D

Every node maintains a direct TCP connection to every other node.
Connections are transitive: if A connects to B, and B knows C, A connects to C.
```

This is **not** a gossip protocol—it's direct point-to-point TCP connections between
all nodes. The `global` module maintains strong consistency for registered names
across this mesh.

### Partition Handling: `prevent_overlapping_partitions`

BEAM doesn't prevent partitions—it **manages them** by forcing clean splits.

As of OTP 25, `prevent_overlapping_partitions` is enabled by default. When node A
loses connection to node B, it tells other nodes. If node C still sees B but A
doesn't, the system **forcibly disconnects** to create clean, non-overlapping
partitions:

```
Before partition:      Network issue:         After forced disconnect:
   A ── B                 A    B                  A         B
   │ ╲╱ │                 │    │                  │         │
   │ ╱╲ │                 │    │                  │         │
   C ── D                 C ── D                  C         D

                    C can still see A and B
                    → "overlapping partition"
                    → C forcibly disconnects from B
                    → clean partitions: {A,C} and {B,D}
```

From `lib/kernel/src/global.erl:34-37`:

> "global will by default prevent overlapping partitions due to network issues by
> actively disconnecting from nodes that reports that they have lost connections
> to other nodes. This will cause fully connected partitions to form instead of
> leaving the network in a state with overlapping partitions."

**This is reactive partition management, not prevention.** The goal is to maintain
consistency for `global` name registration and `mnesia` distributed database.

### Breaking the Mesh: Hidden Nodes

Hidden nodes don't participate in the transitive mesh:

```erlang
erl -hidden -name debug@host
```

| Behavior | Normal Node | Hidden Node |
|----------|-------------|-------------|
| Transitive connect | Yes | No |
| Shows in `nodes/0` | Yes | No (use `nodes(hidden)`) |
| Tracked by `global` | Yes | No |

Use case: Monitoring/debugging tools that shouldn't affect cluster topology.

### Namespace Partitioning: Global Groups

Global groups partition the **namespace**, not the network:

```erlang
%% In sys.config:
{kernel, [
  {global_groups, [
    {group_a, [node1@host, node2@host]},
    {group_b, [node3@host, node4@host]}
  ]}
]}
```

```
┌─── Group A ────┐     ┌─── Group B ────┐
│  node1 ── node2│ ··· │ node3 ── node4 │
│  (full mesh)   │     │  (full mesh)   │
│  own namespace │     │  own namespace │
└────────────────┘     └────────────────┘
          ↑                   ↑
          └──hidden connect───┘
```

Each group has its own `global` namespace. Inter-group connections are hidden.
The main advantage is reducing the update load when manipulating globally
registered names—fewer nodes to synchronize with.

### Scaling Limitations

Full mesh works well for small clusters but becomes expensive as N grows:

- N nodes = N×(N-1)/2 connections
- Every connection = TCP overhead, heartbeats
- `prevent_overlapping_partitions` generates O(N) messages on connection loss

From OTP GitHub issues, users report problems with 60+ node clusters. For larger
deployments, common approaches include:

- **Clustering libraries** like `libcluster` (Elixir) that manage discovery
- **`pg`** (process groups) instead of `global` for pub/sub patterns
- **Application-level sharding** (consistent hashing, partitioned services)
- **Global groups** to reduce synchronization scope

### Summary: Topology Mechanisms

| Mechanism | Purpose | Trade-off |
|-----------|---------|-----------|
| `connect_all=true` | Full mesh, strong consistency | O(N²) connections |
| `prevent_overlapping_partitions` | Clean partitions on failure | Aggressive disconnection |
| Hidden nodes | Break transitivity | Manual connection management |
| Global groups | Namespace partitioning | Cross-group calls more complex |
| `pg` | Process groups, eventual consistency | No global names |

---

## Application Lifecycle

### Two Types of Applications

| Type | Description | Has Supervisor? |
|------|-------------|-----------------|
| **Library** | Collection of modules only | No |
| **Runnable** | Modules + process structure | Yes |

`stdlib` is a library application—it has no supervisor, just modules.
`kernel` is a runnable application—it has `kernel_sup` and many processes.

### Application Start Sequence

```
application:start(myapp)
        │
        ▼
┌───────────────────────────────┐
│   application_controller      │
│                               │
│ 1. Load myapp.app spec        │
│ 2. Validate dependencies      │
│ 3. Check all deps started     │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│   Create application_master   │
│                               │
│ - Becomes group_leader for    │
│   all processes in myapp      │
│ - I/O forwarded through it    │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│   myapp_master calls:         │
│   myapp:start(normal, Args)   │
│                               │
│ - This starts myapp_sup       │
│ - Returns {ok, TopSupPid}     │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│   Supervision tree running    │
│                               │
│   myapp_sup                   │
│   ├── worker_1                │
│   ├── worker_2                │
│   └── child_sup               │
│       └── worker_3            │
└───────────────────────────────┘
```

### Application Stop Sequence

```
application:stop(myapp)
        │
        ▼
┌───────────────────────────────┐
│   application_controller      │
│   tells myapp_master to stop  │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│   myapp_master calls:         │
│   myapp:prep_stop(State)      │  ← Optional cleanup hook
│                               │
│   Then tells myapp_sup to     │
│   shutdown (brutal_kill or    │
│   timeout-based)              │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│   Supervisor shutdown:        │
│                               │
│   1. Stop children in reverse │
│      start order              │
│   2. Each child gets          │
│      terminate/2 callback     │
│   3. Wait for shutdown or     │
│      kill after timeout       │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│   myapp_master calls:         │
│   myapp:stop(State)           │  ← Final cleanup hook
└───────────────────────────────┘
```

### The Synchronous Start Guarantee

From OTP documentation:

> "One very important part of Erlang supervisors and their supervision trees is
> that their start phase is synchronous. Each OTP Process started has a period
> during which it can do its own thing, preventing the entire boot sequence of
> its siblings and cousins to come."

This means:
- If a child crashes during startup, it's retried (per restart strategy)
- Siblings wait until previous sibling is fully started
- **Boot order is deterministic and dependencies are guaranteed**

---

## Higher-Level Distributed Patterns: Phoenix Tracker

While OTP provides low-level distribution primitives (`global`, `pg`, `rpc`),
real applications often need higher-level patterns. **Phoenix.Tracker** (and its
user-facing wrapper **Phoenix.Presence**) demonstrates a sophisticated approach
to distributed state using CRDTs.

### The Problem: "Who's Online?"

Every chat, collaboration, or real-time app needs to track presence. The naive
approaches have problems:

| Approach | Problem |
|----------|---------|
| Central database | Single point of failure, bottleneck |
| `pg` process groups | No metadata, no history, no diffs |
| `global` registration | One name per process, not designed for this |

Phoenix Tracker solves this with a **CRDT-based replicated state** system.

### Architecture: What Each Layer Does

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  libcluster                                                                 │
│    "How do nodes find each other?"                                          │
│    - Cluster formation (Kubernetes, DNS, etc.)                              │
│    - No state management                                                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│  pg (Erlang process groups)                                                 │
│    "Which processes are in this group?"                                     │
│    - Binary membership: in or out                                           │
│    - No metadata, no history, no diffs                                      │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│  Phoenix.PubSub                                                             │
│    "Broadcast messages to subscribers"                                      │
│    - Uses pg under the hood                                                 │
│    - Fire-and-forget: no tracking of delivery                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│  Phoenix.Tracker / Phoenix.Presence                                         │
│    "What is the distributed state, with metadata and diffs?"                │
│    - CRDT-based state replication                                           │
│    - Arbitrary metadata per presence                                        │
│    - Join/leave diffs (not just current state)                              │
│    - Self-healing after partitions                                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

### The CRDT: ORSWOT (Observed-Remove Set Without Tombstones)

Phoenix Tracker uses an **ORSWOT** CRDT. From `lib/phoenix/tracker/state.ex`:

```elixir
defstruct replica: nil,      # This node's identity
          context: %{},      # Causal context (like vector clock)
          clouds: %{},       # "Observed" tags per replica
          values: nil,       # ETS table of {topic, pid, key} → {meta, tag}
          mode: :normal,     # :normal or :delta
          delta: :unset,     # Accumulated changes since last broadcast
          replicas: %{},     # Known replicas and their status (:up/:down)
          range: {%{}, %{}}  # Delta range for contiguity checking
```

**Key properties:**

| Property | How it works |
|----------|--------------|
| **Add** | Element tagged with `{replica, clock}` |
| **Remove** | Only removes elements you've "observed" (in your context) |
| **Merge** | Union of elements, max of causal contexts |
| **No tombstones** | Causal context tracks what's been seen, not deletions |

### Causal Context (Vector Clock Variant)

From `lib/phoenix/tracker/clock.ex`:

```elixir
# Context is a map of replica → clock
@type context :: %{replica_name => pos_integer}

# Dominance check: does c1 causally dominate c2?
def dominates?(c1, c2) do
  Enum.reduce_while(c2, true, fn {replica, clock}, true ->
    if Map.get(c1, replica, 0) >= clock do
      {:cont, true}
    else
      {:halt, false}
    end
  end)
end

# Merge: take max of each replica's clock
def upperbound(c1, c2) do
  Map.merge(c1, c2, fn _, v1, v2 -> max(v1, v2) end)
end
```

This allows nodes to determine:
- Whether they've "seen" a particular update
- Whether a delta is contiguous with their current state
- When to request a full state transfer

### Delta Replication Protocol

From `lib/phoenix/tracker/shard.ex`, the heartbeat loop:

```
Every broadcast_period (default 1.5s):
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   if has_delta?(presences) do                                               │
│     # Send delta to all nodes via PubSub                                    │
│     broadcast({:heartbeat, my_ref, delta, my_clocks})                       │
│     reset_delta()                                                           │
│   else if silent_periods >= max_silent_periods do                           │
│     # Heartbeat even with no changes (liveness signal)                      │
│     broadcast({:heartbeat, my_ref, :empty, my_clocks})                      │
│   end                                                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

On receiving a heartbeat:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   1. Mark sender as "up" (reset down timer)                                 │
│   2. Merge delta into local state → produces joins/leaves diff              │
│   3. Call handle_diff callback with {topic → {joins, leaves}}               │
│   4. Store delta in generation list for other nodes that need it            │
│   5. Check if any replica's clock dominates ours → request transfer         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Delta Generations (Efficient Catch-up)

From `lib/phoenix/tracker/delta_generation.ex`, the system maintains multiple
delta "generations" of different sizes:

```elixir
max_delta_sizes: [100, 1000, 10_000]  # default
```

```
Generation 0: Most recent, ≤100 elements
Generation 1: Merged from 0, ≤1000 elements
Generation 2: Merged from 1, ≤10000 elements
```

When a node requests state (it missed some deltas), the system finds the smallest
generation that covers the gap. If no delta is sufficient, it falls back to full
state transfer.

### Failure Detection: Three States

From `lib/phoenix/tracker/shard.ex:384-399`:

```
            ┌──────────────────────────────────────────────────────────────┐
            │                                                              │
            │   :up ──(no heartbeat for down_period)──→ :down              │
            │         (default 30s)                                        │
            │         Presences hidden but retained                        │
            │                                                              │
            │   :down ──(no heartbeat for permdown_period)──→ :permdown    │
            │          (default 20min)                                     │
            │          State discarded, replica forgotten                  │
            │                                                              │
            │   :down ──(heartbeat received)──→ :up                        │
            │          Presences restored, diff sent                       │
            │                                                              │
            └──────────────────────────────────────────────────────────────┘
```

With `permdown_on_shutdown: true`, graceful shutdown broadcasts permdown
immediately (no 20min wait).

### What This Gives You (vs pg)

```elixir
# pg: just PIDs
:pg.get_members(:my_scope, "room:123")
#=> [#PID<0.123.0>, #PID<0.456.0>]

# Phoenix.Presence: replicated state with metadata
Presence.list("room:123")
#=> %{
#     "user_42" => %{metas: [%{device: "mobile", status: "active"}]},
#     "user_99" => %{metas: [%{device: "desktop"}, %{device: "tablet"}]}
#   }

# Plus: diffs on change
def handle_info(%{event: "presence_diff", payload: diff}, socket) do
  # diff = %{joins: %{"user_42" => ...}, leaves: %{"user_99" => ...}}
end
```

### Trade-offs (CAP Theorem)

Phoenix Tracker chooses **Availability + Partition Tolerance** over Consistency:

| Property | Behavior |
|----------|----------|
| **Available** | Always accepts reads/writes, even during partition |
| **Partition tolerant** | Continues operating across network splits |
| **Eventually consistent** | Different nodes may have different views temporarily |

From the source: "there is no single source of truth or global process"—every node
is authoritative for its own presences, and convergence happens through CRDT merge.

### Source Files (tmp/phoenix_pubsub/)

| File | Purpose |
|------|---------|
| `lib/phoenix/tracker.ex` | Public API, sharding facade |
| `lib/phoenix/tracker/state.ex` | ORSWOT CRDT implementation |
| `lib/phoenix/tracker/clock.ex` | Causal context (vector clock) operations |
| `lib/phoenix/tracker/shard.ex` | GenServer with heartbeat loop, merge logic |
| `lib/phoenix/tracker/delta_generation.ex` | Delta compression and catch-up |
| `lib/phoenix/tracker/replica.ex` | Replica state tracking (up/down/permdown) |

---

## Comparison Table

| Aspect | Ruby Main Ractor | BEAM/OTP |
|--------|------------------|----------|
| **First Process** | Main Ractor (structural) | `init` (functional coordinator) |
| **Privilege Model** | Binary (main vs other) | Layered (init → app_controller → apps) |
| **App Coordination** | None | `application_controller` singleton |
| **Distribution** | None (single OS process) | Multi-node with transparent messaging |
| **Discovery** | N/A | EPMD (external daemon) |
| **Connection Mgmt** | N/A | `net_kernel` (Erlang process) |
| **Message Transport** | Ractor boundaries | VM runtime (C code, fast path) |
| **Supervision** | None built-in | Hierarchical supervision trees |
| **Shutdown** | Main dies = all die | Cascading: apps stop in reverse dep order |
| **Identity** | Structural (first Ractor) | Named (registered process names) |

### Key Architectural Differences

1. **Ruby**: Flat model. Main Ractor has special privileges but no coordination role.

2. **BEAM**: Layered model with separation of concerns:
   - `init`: System lifecycle
   - `application_controller`: Application lifecycle
   - `net_kernel`: Network connections
   - VM runtime: Message passing (hot path)

3. **Distribution**: BEAM separates discovery (EPMD), connection (net_kernel), and
   transport (VM). This allows the hot path to bypass Erlang processes entirely.

4. **Failure Isolation**: BEAM's supervisor trees provide explicit blast radius
   control. Ruby Ractors provide isolation but no coordination or recovery.

---

## References

### Ruby 4.0
- [Ruby 4.0 Ractor Documentation](https://docs.ruby-lang.org/en/master/Ractor.html)
- [Ruby 4.0 Changes](https://rubyreferences.github.io/rubychanges/4.0.html)
- [What's New in Ruby 4.0 - Saeloun](https://blog.saeloun.com/2025/12/24/what-is-new-in-ruby-4/)

### BEAM/OTP
- [Distribution Protocol — erts](https://www.erlang.org/doc/apps/erts/erl_dist_protocol.html)
- [Distributed Erlang](https://www.erlang.org/doc/system/distributed.html)
- [net_kernel — kernel](https://www.erlang.org/doc/apps/kernel/net_kernel.html)
- [Kernel Application](https://www.erlang.org/doc/apps/kernel/kernel_app.html)
- [erl_epmd — kernel](https://www.erlang.org/doc/apps/kernel/erl_epmd.html)
- [OTP Design Principles](https://www.erlang.org/doc/system/design_principles.html)
- [Supervision Trees - Adopting Erlang](https://adoptingerlang.org/docs/development/supervision_trees/)
- [Distribunomicon - Learn You Some Erlang](https://learnyousomeerlang.com/distribunomicon)
- [EEF Security - Distribution Protocol](https://security.erlef.org/secure_coding_and_deployment_hardening/distribution.html)

### OTP Source (tmp/otp/)
- `erts/preloaded/src/init.erl` - The init process
- `lib/kernel/src/kernel.erl` - Kernel supervisor tree (includes ASCII diagram)
- `lib/kernel/src/application_controller.erl` - Application lifecycle
- `lib/kernel/src/erl_distribution.erl` - Distribution supervisor (net_sup)
- `lib/kernel/src/net_kernel.erl` - Connection management
- `lib/kernel/src/global.erl` - Global name registry, partition handling
- `lib/kernel/src/global_group.erl` - Global groups for namespace partitioning

### Phoenix/Elixir
- [Phoenix.Tracker — Phoenix.PubSub](https://hexdocs.pm/phoenix_pubsub/Phoenix.Tracker.html)
- [What makes Phoenix Presence special - DockYard](https://dockyard.com/blog/2016/03/25/what-makes-phoenix-presence-special-sneak-peek)
- [On Guarantees of Phoenix Presence](https://medium.com/appunite-edu-collection/on-guarantees-of-phoenix-presence-a4a23c24667f)
- [global_group — kernel](https://www.erlang.org/doc/apps/kernel/global_group.html)
- [OTP issue #6214 - prevent_overlapping_partitions](https://github.com/erlang/otp/issues/6214)

### Phoenix.Tracker Source (tmp/phoenix_pubsub/)
- `lib/phoenix/tracker.ex` - Public API
- `lib/phoenix/tracker/state.ex` - ORSWOT CRDT implementation
- `lib/phoenix/tracker/clock.ex` - Causal context operations
- `lib/phoenix/tracker/shard.ex` - GenServer with heartbeat and merge
- `lib/phoenix/tracker/delta_generation.ex` - Delta compression
