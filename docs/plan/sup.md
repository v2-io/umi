# SUP: Supervision

Supervisors apply restart policies to children. They are the core of fault
tolerance.

---

## The Foundation: Observation

Before anything else, you need to **detect** when an isolation unit terminates.
This is the primitive everything else builds on.

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

**Properties:**
- Monitoring is unidirectional (observer doesn't die when observed dies)
- Notifications are guaranteed if the monitor was established
- Multiple observers can monitor the same unit

**Ruby 4.0**: `Ractor#monitor(port)` sends `:exited` or `:aborted` to the port.

Everything in Umi—supervisors, registry auto-cleanup, coordinator death
detection—builds on this single primitive.

---

## The Core Insight

Workers shouldn't contain restart logic. They should do their job and die
cleanly if they can't. Separating policy from mechanism:

- Keeps workers simple and testable
- Allows the same worker with different failure strategies
- Makes failure handling explicit and visible

A supervisor's job:
1. Start children according to specifications
2. Monitor all children
3. Apply a restart policy when children die
4. Bound restart rate (don't spin on persistent failures)
5. Propagate shutdown to children in controlled order

---

## Restart Policies

When a child dies, the supervisor decides what to do. At the abstract level:

| Policy | Behavior |
|--------|----------|
| Restart | Start a new instance of the dead child |
| Restart with backoff | Restart, but with increasing delays |
| Restart dependents | Restart this child and those that depend on it |
| Restart all | Restart all children (they have interdependencies) |
| Ignore | Let it stay dead (temporary/optional work) |
| Escalate | I can't handle this—tell my supervisor |

**OTP terminology** (maps to the above):

| Policy | Behavior | When to Use |
|--------|----------|-------------|
| `:one_for_one` | Restart only the dead child | Independent workers |
| `:one_for_all` | Restart all children | Interdependent workers |
| `:rest_for_one` | Restart dead child + those started after | Sequential dependencies |

**Child restart types** (per-child, not per-supervisor):

| Type | Behavior |
|------|----------|
| `:permanent` | Always restart |
| `:temporary` | Never restart (Ignore policy) |
| `:transient` | Restart only on abnormal exit |

---

## Restart Bounding and Escalation

Without bounds, a crashing child creates an infinite restart loop:

```ruby
max_restarts: 3
within_period: 5  # seconds

# If child restarts more than 3 times in 5 seconds,
# supervisor gives up and escalates (dies itself).
```

**Escalation** is the key insight: when a supervisor can't keep its children
alive, it doesn't keep trying forever—it dies. This signals to ITS supervisor
that something is fundamentally wrong.

This turns "child that can't stay alive" into "supervisor that dies," which
escalates to the next level up. Eventually, if nothing can handle the failure,
it reaches the coordinator and the system halts—which is the correct behavior
for an unrecoverable failure.

---

## The Blast Radius Pattern

From BEAM's `kernel.erl`:

> "All supervisors except for kernel_safe_sup terminates the entire erlang node
> if any of their children dies."

This is **explicit blast radius control**:

```
root_sup
│
├── critical_sup (intensity=0: any child death = escalate)
│   ├── worker_a (permanent)
│   └── worker_b (permanent)
│
└── degradable_sup (intensity=5: tolerate some failures)
    ├── worker_c (permanent)
    └── batch_sup (nested supervisor)
        ├── job_1 (temporary)
        └── job_2 (temporary)
```

- `critical_sup` children are essential—one death crashes the supervisor
- `degradable_sup` children can fail some before escalating
- `batch_sup` jobs are temporary—never restarted, no escalation

**Design question for each service**: "If this dies, how far should failure
propagate?"

---

## Child Specification

```ruby
{
  id: :database_pool,           # Unique identifier
  start: -> { Pool.start_link(config) },  # How to start
  restart: :permanent,          # permanent | temporary | transient
  shutdown: 5000,               # milliseconds, or :brutal_kill
  type: :worker,                # :worker | :supervisor
  name: :database_pool          # Optional registry name
}
```

The specification is **data, not code**. Supervisors can be configured,
serialized, introspected.

---

## Supervision Trees

Supervisors can supervise other supervisors:

```
             root_sup
             /      \
       app_sup      infra_sup
       /    \           |
   web_sup  api_sup   cache_pool
    /   \
  conn  conn
```

**Properties:**
- **Containment**: Failure in `web_sup` doesn't touch `infra_sup`
- **Escalation**: `web_sup` failure escalates to `app_sup`
- **Nesting**: Unlimited depth
- **Root**: `root_sup` failure = system failure

**The Tree Invariant**: Every child has exactly one supervisor. No orphans, no
ambiguity about "who restarts me?"

---

## Static vs Dynamic Supervisors

**Static Supervisor**: Children defined at start time.

```ruby
Supervisor.new([
  { id: :a, start: -> { A.start } },
  { id: :b, start: -> { B.start } },
])
```

**Dynamic Supervisor**: Children added at runtime.

```ruby
dyn_sup = DynamicSupervisor.new
dyn_sup.start_child { Session.new(user_id) }
dyn_sup.start_child { Session.new(other_user) }
```

Dynamic supervisors are for per-user, per-session, per-connection processes.

---

## DynamicSupervisor in Detail

### The Problem

Some processes are created based on user actions:
- A process per user session
- A process per game room
- A process per file upload

You don't know at startup how many you'll need.

### Operations

```ruby
class Umi::DynamicSupervisor
  # Start a new supervised child
  start_child(id, spec) → [:ok, ractor] | [:error, reason]

  # Stop a specific child
  terminate_child(id) → :ok | [:error, :not_found]

  # List all children
  which_children() → [{id, ractor, spec}]

  # Count children
  count_children() → Integer
end
```

### Restart Behavior

- Child crashes → restarted per its spec (`:permanent`, `:transient`, `:temporary`)
- Supervisor crashes → all children lost (unless state is persisted)
- Same restart bounding applies (max restarts within period)

### Implementation Sketch

DynamicSupervisor must select on both commands AND all child monitors:

```ruby
class Umi::DynamicSupervisor
  def initialize(restart_policy: :permanent)
    @command_port = Ractor::Port.new
    @monitor_port = Ractor::Port.new

    @ractor = Ractor.new(@command_port, @monitor_port, restart_policy) do |cmd, mon, policy|
      children = {}  # id → {ractor, spec}

      loop do
        case Ractor.select(cmd, mon)
        in [^cmd, [:start_child, id, spec, reply_port]]
          ractor = spec[:start].call
          ractor.monitor(mon)
          children[id] = { ractor: ractor, spec: spec }
          reply_port << [:ok, ractor]

        in [^cmd, [:terminate_child, id, reply_port]]
          if child = children.delete(id)
            child[:ractor].send([:shutdown, 5000])
            reply_port << :ok
          else
            reply_port << [:error, :not_found]
          end

        in [^mon, status] # :exited or :aborted
          # NOTE: Ractor#monitor sends just :exited or :aborted, not tuples.
          # Must find which child died by checking alive? status.
          id, child = children.find { |_, c| !c[:ractor].alive? }
          next unless id

          case [policy, child[:spec][:restart], status]
          in [_, :permanent, _] | [_, :transient, :aborted]
            # Restart (permanent always, transient on abnormal)
            new_ractor = child[:spec][:start].call
            new_ractor.monitor(mon)
            children[id] = { ractor: new_ractor, spec: child[:spec] }
          else
            # Don't restart
            children.delete(id)
          end
        end
      end
    end
  end
end
```

### Combined with Registry

Dynamic children are typically found by name, not tracked by caller. See
[reg.md](./reg.md) for the Registry + DynamicSupervisor pattern.

---

## Shutdown Sequence

When a supervisor stops:

1. Stop children in reverse start order
2. Each child gets `[:shutdown, timeout]` message
3. Wait for clean exit (up to timeout)
4. Force-kill anything remaining
5. Then supervisor itself exits

**Why reverse order?** Later children may depend on earlier ones. Stop
dependents before dependencies.

---

## Supervisor as Ractor

In Umi, a supervisor is itself a Ractor. This means:

- It can be supervised by another supervisor
- It can be monitored
- It can be named in the registry
- Failure handling is uniform at every level

### The Composability Insight

OTP's deepest insight isn't any single pattern—it's that **everything composes
using the same primitives**:

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

**The principle**: Build each component from the primitives below. Don't
introduce new primitives at higher levels. This means:

- Everything is observable (you can monitor anything)
- Everything is restartable (supervisors all the way down)
- Everything composes (applications can depend on applications)
- Failure handling is uniform (same patterns at every level)

No special cases. No "this component is different." Just isolation units,
messages, and monitors, structured thoughtfully.

```ruby
class Umi::Supervisor
  def run
    start_children(@specs)

    loop do
      case Ractor.select(@monitor_port, @command_port)
      in [@monitor_port, status] # :exited or :aborted
        # Find dead child by checking alive? (monitor sends symbol, not tuple)
        dead = @children.keys.find { |r| !r.alive? }
        handle_child_death(dead, status) if dead
      in [@command_port, [:shutdown, timeout]]
        shutdown_children(timeout)
        break
      end
    end
  end
end
```

---

## Integration with Registry

Supervisors can register children by name (see [reg.md](./reg.md)):

```ruby
def start_child(spec)
  ractor = spec[:start].call
  ractor.monitor(@monitor_port)

  if spec[:name]
    Registry.register(spec[:name], ractor)
  end

  @children[spec[:id]] = { ractor: ractor, spec: spec }
end
```

On child death, re-registration happens automatically on restart.

---

## Integration with Coordinator

The coordinator (see [ini.md](./ini.md)) starts application supervisors and
monitors them. A top-level supervisor death is escalated to the coordinator,
which may restart the entire application or halt the system.

---

## Key Ruby 4.0 Limitations

Unlike BEAM/OTP, Ruby 4.0 has these constraints (see [pre.md](./pre.md)):

| Limitation | Implication for Supervision |
|------------|----------------------------|
| **No linking primitive** | Only unidirectional monitoring; supervisors must explicitly monitor each child |
| **No exit signals** | Cannot send `:shutdown` to a Ractor—must use message via Port |
| **Cannot restart in place** | Must spawn new Ractor and migrate state; old Ractor reference becomes invalid |
| **Ractor refs not serializable** | Use Registry names for persistent references to children |

**Restart semantics**: When a child dies and is restarted, it's a completely new
Ractor. Callers holding the old reference will fail. This is why Registry
integration is essential—callers use names, not Ractor references.

---

## Open Questions

1. **Restart strategy complexity**: Do we need `:rest_for_one`? Or is
   `:one_for_one` + `:one_for_all` sufficient?

2. **Supervision of Proctors**: Proctor already has internal watcher. How does
   that compose with supervision?

3. **Dynamic to static**: Can a dynamically-added child become permanent?

4. **Restart backoff implementation**: The policy is recognized (see table above),
   but what's the right default backoff curve? Exponential? Fibonacci? Capped?

---

## References

- [pre.md](./pre.md) - Ruby 4.0 primitives (monitor sends :exited/:aborted, not tuples)
- [beam-otp-analysis.md](../beam-otp-analysis.md) - kernel_sup detail
- [ini.md](./ini.md) - Coordinator (supervises applications)
- [app.md](./app.md) - Applications (contain supervision trees)
- [rac.md](./rac.md) - Workers (supervised by supervisors)
- [reg.md](./reg.md) - Registry + DynamicSupervisor pattern
