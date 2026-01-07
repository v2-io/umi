# INI: Coordination Layer

The coordinator is the "root" that makes "let it crash" possible. It is
deliberately boring so everything else can be interesting.

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

## What Solves What

| Problem | Solution | Document |
|---------|----------|----------|
| Death is Silent | Observation primitive (`Ractor#monitor`) | [sup.md](./sup.md) |
| Death is Contagious | Supervision trees with restart policies | [sup.md](./sup.md) |
| Startup Order Matters | Coordinator + Application dependencies | Here, [app.md](./app.md) |
| Shutdown is Harder | Coordinator + reverse ordering + timeouts | Here, [app.md](./app.md) |
| Naming and Discovery | Registry with auto-cleanup | [reg.md](./reg.md) |
| Distribution | Deferred—single-node first | [etc.md](./etc.md) |

---

## Why Ruby Needs a Coordinator

Ruby's main Ractor is **structurally** special (first = privileged) but
**functionally** passive. It doesn't coordinate other Ractors. When it dies,
everything dies—but that's an accident, not a design.

BEAM's `init` process is different: it actively coordinates system lifecycle.
Its simplicity is what allows everything else to safely crash and restart.

**Umi needs to build the coordination layer Ruby doesn't provide.**

---

## Core Responsibilities

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  ROOT COORDINATOR                                                           │
│                                                                             │
│  Bootstrap:                                                                 │
│    - Read system configuration                                             │
│    - Determine application start order (topological sort)                  │
│    - Start applications in dependency order                                │
│    - Wait for each application to be fully running before starting next    │
│                                                                             │
│  Steady State:                                                              │
│    - Monitor all applications (not just kernel Ractors)                    │
│    - Handle application failures (restart or escalate to system halt)      │
│    - Accept commands (start app, stop app, reconfigure)                    │
│    - Convert OS signals to messages                                        │
│    - Answer health checks                                                  │
│                                                                             │
│  Shutdown:                                                                  │
│    - Receive shutdown signal (SIGTERM, explicit call)                      │
│    - Stop applications in reverse dependency order                         │
│    - Wait for graceful shutdown with timeout                               │
│    - Force-kill anything still running                                     │
│    - Exit with appropriate code                                            │
│                                                                             │
│  When root coordinator dies, the system is dead.                           │
│  This is the definition, not a bug.                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

No business logic. No complex state. No external dependencies.

---

## The Two-Phase Pattern

```
BOOTSTRAP PHASE                      STEADY-STATE PHASE
────────────────                     ──────────────────
- Complex state tracking             - Minimal state
- Progress reporting                 - Simple message loop
- Kernel Ractor startup              - Monitor for death
- Application startup                - Handle shutdown signals
- Error = abort boot                 - Error = delegate/escalate

Transitions when boot completes      Remains until shutdown
```

From BEAM's `init.erl`: the bootstrap phase tracks loaded modules, progress,
boot script position. Steady-state just waits for death notifications and
shutdown commands.

**Principle**: The coordinator is simpler in steady state than during boot.
Design accordingly.

---

## Boot Script as Data

**Principle**: The coordinator is an interpreter of declarative boot data, not
hardcoded startup logic.

This means:
- Boot order is introspectable (just read the script)
- Boot is deterministic (same script = same order)
- Boot can be modified without changing coordinator code
- Boot scripts can be generated, validated, transmitted

### Boot Script Commands

| Command | Purpose | Why Needed |
|---------|---------|------------|
| `progress` | Status reporting | Introspection, debugging, health checks |
| `kernel_ractor` | Start critical process | Pre-supervision infrastructure |
| `application` | Start supervised app | Main workload |
| `config` | Set configuration | Parameterize behavior |

### Conceptual Ruby Boot Script

```ruby
{
  progress: :initializing,

  # Pre-supervision layer: halt on death
  kernel_ractors: [
    { name: :registry, start: -> { Umi::Registry.start_link } },
    { name: :logger,   start: -> { Umi::Logger.start_link } },
  ],

  progress: :kernel_started,

  # Applications: supervised, restart on death
  applications: [
    { name: :database,   depends_on: [],          config: {...} },
    { name: :web_server, depends_on: [:database], config: {...} },
  ],

  progress: :started
}
```

See [etc.md](./etc.md) for complete boot sequence implementation example.

---

## The Boring Root Principle

The coordinator's reliability is the foundation of the entire system's isolation
guarantees. "Let it crash" only works if you trust that crashes lead to
restarts. That trust comes from the coordinator being simple.

```
If coordinator is SIMPLE and RELIABLE:
  - Everything else can fail safely
  - Crashes become "restarts"
  - System is comprehensible

If coordinator is COMPLEX or FRAGILE:
  - Any failure might be catastrophic
  - Can't reason about isolation
  - "Let it crash" becomes "pray it doesn't crash"
```

**The root is boring on purpose.** It should have:
- Minimal responsibilities (start, stop, monitor—that's it)
- No business logic
- Simple state (just "what's running")
- No external dependencies
- Heavily tested, rarely modified code paths

**The coordinator's only verbs should be Ractor primitives:**

```ruby
Ractor.select()  # Wait for message
port.send()      # Fire and forget
Ractor.new()     # Start a child
ractor.monitor() # Watch a child
```

Everything else is delegated to something that CAN fail and be restarted.

### Delegate Everything, Even I/O

BEAM takes this to its logical conclusion: even "simple" things like file I/O
and logging are delegated to separate processes:

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

**Ractors all the way down**: A well-designed Umi system delegates everything
that could fail. File I/O, logging, configuration—all Ractors that can crash
independently. The coordinator is the one Ractor that, by being maximally
boring, effectively never crashes.

This gives true isolation: any component can fail, and the failure is contained.
The system continues. The failed component restarts. Life goes on.

---

## Pre-Supervision Layer (Kernel Ractors)

Some processes must exist before supervision is possible. They form a layer
below the supervision infrastructure:

| Ractor | Purpose | Why Pre-Supervision |
|--------|---------|---------------------|
| Registry | Name lookup | Supervisors need to find children |
| Logger | Error reporting | Must log supervisor failures |

**Kernel Ractor contract:**
- Linked to coordinator (death = halt)
- Must handle `[:shutdown]` message gracefully
- Must be simple enough to rarely fail
- Must have no dependencies on supervised processes

When a kernel Ractor dies, the coordinator doesn't try to restart it. It halts
the entire system and lets external supervision (systemd, k8s) restart.

---

## Signal Handling

Signals become messages. The coordinator doesn't care where `[:shutdown]` came
from—it just acts on it.

```ruby
def setup_signal_handlers
  Signal.trap("TERM") { @signal_port << [:shutdown, :sigterm] rescue nil }
  Signal.trap("INT")  { @signal_port << [:shutdown, :sigint] rescue nil }
  Signal.trap("HUP")  { @signal_port << [:reload_config] rescue nil }
  Signal.trap("PIPE", "IGNORE")
end
```

**Signal ownership:**

| Signal | Handler | Action |
|--------|---------|--------|
| SIGTERM | Coordinator | Graceful shutdown |
| SIGINT | Coordinator | Same as SIGTERM |
| SIGHUP | Coordinator | Reload config, notify apps |
| SIGUSR1/2 | Broadcast | Apps decide |
| SIGPIPE | Ignored | Standard server behavior |

Applications don't call `Signal.trap`. They receive messages from coordinator.

### Signal Handler Safety

From spike testing (`spike_j_signal_handler_reentrancy.rb`):

- **`port <<` is signal-safe**: Tested under stress (1000 concurrent main sends
  + 1000 signal sends), no messages lost, no deadlocks
- **Signals may coalesce**: Under rapid signaling, the OS may coalesce multiple
  instances. Design for "at least one" semantics, not "exactly N"
- **Use `rescue nil`**: Signals can arrive during shutdown when ports are closed

**Best practice**: Keep handlers minimal—just send a message. All complex logic
belongs in the coordinator's event loop.

### Coordinator Placement Options

Three viable patterns for where the coordinator runs (all tested in spikes):

**Option A: Coordinator IS Main Ractor** (Recommended)

```ruby
# Main Ractor runs coordinator directly
@signal_port = Ractor::Port.new
Signal.trap("TERM") { @signal_port << [:shutdown] rescue nil }

loop do
  ready, val = Ractor.select(@signal_port, @monitor_port)
  # ...
end
```

**Option B: Child Coordinator, Queue Relay**

```ruby
# Main relays via Thread::Queue (documented signal-safe)
signal_queue = Thread::Queue.new
Signal.trap("TERM") { signal_queue << [:shutdown] }

coord_inbox = start_coordinator_ractor
Thread.new { loop { coord_inbox << signal_queue.pop } }  # Relay
```

**Option C: Child Coordinator, Direct Port Send**

```ruby
# Signal handler sends directly to child's port
coord_inbox = start_coordinator_ractor
Signal.trap("TERM") { coord_inbox << [:shutdown] rescue nil }
```

| Aspect | A: Main | B: Queue Relay | C: Direct Port |
|--------|---------|----------------|----------------|
| Complexity | Lowest | Medium | Low |
| Signal safety | Trivial | Documented | Tested |
| Relay overhead | None | Thread + Queue | None |
| Coordinator isolation | None | Full | Full |

**Recommendation**: Use Option A (coordinator IS main) unless you need to isolate
the coordinator from main Ractor concerns.

### Bootstrap vs Steady-State Signal Handling

**Bootstrap phase**: Coordinator is actively starting things, not in select loop.
Signals queue automatically. Check between major steps:

```ruby
def boot(config)
  setup_signal_handlers

  start_kernel_ractors
  check_for_shutdown  # Non-blocking check, abort if SIGTERM received

  start_applications
  check_for_shutdown

  steady_state_loop
end

def check_for_shutdown
  loop do
    result = try_receive(@signal_port, timeout: 0)
    break if result.nil?
    case result
    in [:shutdown, reason] then abort_boot(reason)
    else # Ignore other signals during boot
    end
  end
end
```

**Steady-state phase**: Coordinator is in select loop, handles signals as they
arrive alongside other messages.

---

## Shutdown Modes

BEAM distinguishes three ways to stop, and Umi should too:

| Mode | OS Process | Runtime | When to Use |
|------|------------|---------|-------------|
| `stop` | Exits | Stays dead | Intentional shutdown |
| `reboot` | Exits | Restarts via external | Clean restart, upgrade |
| `restart` | Stays running | Re-bootstraps | Hot config reload (if supported) |

**For Ruby**: The `restart` mode (re-bootstrap in same process) requires clean
code unloading. Ruby Box may enable this—see Ruby Box section below. Without
Box, always use `reboot` (exit and let external supervisor restart).

---

## Shutdown Sequence

Order matters. From BEAM's `init.erl`:

```
1. Set status to :stopping
2. Stop applications in reverse dependency order
   - Send [:shutdown, timeout] to each
   - Wait for clean exit (with timeout)
3. Stop kernel Ractors (except logger)
4. Force-kill anything remaining
5. Stop logger (last, needed for error reporting)
6. Exit with appropriate code
```

**Exit codes:**
- `exit(0)` for intentional stop (don't restart)
- `exit(1)` for crash (do restart)

**Shutdown timeout**: Graceful shutdown can hang. Set a deadline—if processes
don't exit gracefully in time, force-kill them. Don't wait forever.

---

## External Supervision

The coordinator cannot supervise itself. Something external must watch it:

| System | How |
|--------|-----|
| systemd | `Restart=always`, health checks |
| Kubernetes | Liveness probes, pod restart |
| Docker | `--restart=always`, health checks |

The coordinator should:
- Exit cleanly so external supervisor knows intent
- Respond to health checks
- Not attempt self-resurrection

---

## Ruby Box: Namespace Isolation

Ruby 4.0 introduces **Ruby Box** (`RUBY_BOX=1`), providing namespace isolation
within a single process. Combined with Ractors and Ports, this gives Ruby a
powerful isolation story comparable to BEAM.

### What Box + Ractor Provides

| Concern | Ractor | Box | Together |
|---------|--------|-----|----------|
| Memory isolation | Yes (share-nothing) | No | Yes |
| Parallel execution | Yes | No | Yes |
| Namespace isolation | No | Yes | Yes |
| Monkey-patch containment | No | Yes | Yes |

**Defense in depth**: Applications can't corrupt each other's memory (Ractor)
OR class definitions (Box).

### Box Hierarchy

```
Root Box (Ruby bootstrap)
  │
  ├── Main Box (user's main program)
  │
  ├── App Box 1 (created inside App 1's Ractor)
  │     └── Isolated: monkey patches, globals, constants
  │
  └── App Box 2 (created inside App 2's Ractor)
        └── Isolated: monkey patches, globals, constants
```

### The Coordinator Protection Pattern

```ruby
module Umi
  class Coordinator
    def start_application(app_spec)
      Ractor.new(app_spec, @inbox) do |spec, coord_port|
        # Create isolated box for this application
        app_box = Ruby::Box.new
        app_box.require(spec[:entry_point])

        # App's monkey patches stay in app_box
        # Even if app does: class Ractor::Port; def send(*) = nil; end
        # ...coordinator's Ractor::Port is unaffected

        supervisor = app_box.const_get(spec[:supervisor]).new
        supervisor.start(coord_port)
      end
    end
  end
end
```

### Hot Code Reload via Box

Ruby Box may enable the `restart` shutdown mode (re-bootstrap without process
exit):

1. Create new Boxes for updated applications
2. Start new application instances in new Boxes
3. Drain traffic from old instances
4. Shut down old instances (old Boxes become garbage)
5. Old code is effectively "unloaded" when Box is collected

This mirrors BEAM's hot code swap but uses Box's namespace isolation rather
than VM-level module replacement.

### Spike Results

From `spike_f_box_ractor.rb`:

- Both mechanisms function together without conflicts
- Ractor inherits creator's Box context
- For true isolation, create Box INSIDE Ractor
- Coordinator protection works—app monkey patches don't affect coordinator
- Box references are shareable across Ractor boundaries

### Caveats

Ruby Box is experimental:
- Requires `RUBY_BOX=1` environment variable
- Some gems may not work (e.g., `active_support/core_ext`)
- Performance penalty for `rb_funcall()` with Box enabled
- Native extensions may have issues

See [app.md](./app.md) for application-level namespace isolation patterns and
[etc.md](./etc.md) for the complete coordinator implementation example showing
Box integration.

---

## Open Questions

1. **Boot script format**: Ruby DSL? YAML? Pure Ruby data structures?

2. **Health check mechanism**: HTTP endpoint? File touch? Socket?

3. **Hot reload scope**: With Ruby Box, what can change without full restart?
   Application code seems feasible. Kernel Ractors probably not.

4. **Box adoption**: When is Box overhead acceptable? Always? Only for
   untrusted application code?

---

## References

- [pre.md](./pre.md) - **Ruby 4.0 primitives** (start here for API details)
- [otp-initialization.md](../otp-initialization.md) - Detailed `init.erl` analysis
- [reg.md](./reg.md) - Registry (kernel Ractor, must exist before supervision)
- [app.md](./app.md) - Application lifecycle (what coordinator coordinates)
- [sup.md](./sup.md) - Supervision (what applications contain)
- [etc.md](./etc.md) - Complete coordinator implementation example
