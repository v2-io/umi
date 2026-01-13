# APP: Application Lifecycle

Applications are named bundles of supervision trees with declared dependencies.

---

## What Is an Application?

An application is larger than a supervisor but smaller than a system:

```
Application = Supervision Tree + Configuration + Dependencies + Lifecycle Hooks
```

It's the unit of:
- **Deployment**: "Ship the auth application"
- **Configuration**: "Configure the database application"
- **Dependencies**: "Web depends on database"
- **Lifecycle**: "Start auth before web"

---

## Two Types

| Type | Description | Has Supervisor? |
|------|-------------|-----------------|
| **Library** | Collection of modules only | No |
| **Runnable** | Modules + process structure | Yes |

Most Umi applications will be runnable—they have supervision trees. Library
applications are just code without runtime processes.

---

## Why Applications?

Real systems are composed of multiple subsystems. You need a unit of composition
larger than "one supervisor tree" that:

- **Has a name** (for humans and tooling)
- **Declares its requirements** (for correct ordering)
- **Can be started/stopped independently** (for operations)

Without this abstraction, you either have one giant monolithic supervisor tree,
or ad-hoc coordination of independent trees with no guarantees about ordering
or dependencies.

---

## Lifecycle States

```
         ┌──────────────────────────────────────────────────────┐
         │                                                      │
         ▼                                                      │
    ┌─────────┐     ┌──────────┐     ┌─────────┐     ┌──────────┐
    │ loading │────→│ starting │────→│ running │────→│ stopping │
    └─────────┘     └──────────┘     └─────────┘     └──────────┘
         │               │                                │
         │               │                                ▼
         │               │                          ┌──────────┐
         └───────────────┴─────────────────────────→│ stopped  │
                      (on failure)                  └──────────┘
```

**Transitions:**
- `loading → starting`: Dependencies satisfied, config valid
- `starting → running`: Supervision tree fully started
- `running → stopping`: Shutdown requested
- `stopping → stopped`: All children terminated
- `* → stopped`: Failure at any stage

---

## Lifecycle Callbacks

| Callback | When | Purpose |
|----------|------|---------|
| `prepare` | Before starting | Validate config, acquire resources |
| `start` | Create supervision tree | Returns top supervisor |
| `running` | After fully started | Notify dependents, open for business |
| `stopping` | Before shutdown | Drain work, notify clients |
| `stopped` | After shutdown | Release resources, cleanup |

All callbacks are optional. Sensible defaults for missing ones.

**Example implementation:**

```ruby
module MyApp
  class Application
    # Validate config, acquire resources, check preconditions
    # Return [:error, reason] to abort
    def prepare(config)
      :ok
    end

    # Start supervision tree, return top supervisor
    def start(config)
      MyApp::Supervisor.start_link(config)
    end

    # Called after fully started
    # Good place to announce readiness
    def running(config, supervisor)
      Logger.info("MyApp ready")
    end

    # Called before shutdown begins
    # Drain queues, notify clients
    def stopping(config, supervisor)
      MyApp::Drainer.drain_all
    end

    # Called after supervision tree stopped
    # Release external resources
    def stopped(config)
      :ok
    end
  end
end
```

---

## Dependency Ordering

Applications declare what they depend on:

```ruby
{
  name: :web_server,
  depends_on: [:database, :cache],
  config: { port: 8080 }
}
```

The coordinator (see [ini.md](./ini.md)) sorts by dependencies:

```
Application A depends on [B, C]
Application B depends on [D]
Application C depends on []
Application D depends on []

Start order: D, C, B, A (dependencies first)
Stop order:  A, B, D, C (dependents first)
```

**Guarantees:**
- Dependencies started before dependents
- Dependents stopped before dependencies
- Atomic start (either fully started or rolled back on failure)
- Circular dependencies are an error (detected at load time)

---

## The Synchronous Start Guarantee

From OTP documentation:

> "Each OTP Process started has a period during which it can do its own thing,
> preventing the entire boot sequence of its siblings and cousins to come."

This means:
- If a child crashes during startup, it's retried (per restart strategy)
- Siblings wait until previous sibling is fully started
- **Boot order is deterministic and dependencies are guaranteed**

The coordinator waits for each application to reach `running` before starting
the next one. No race conditions, no "hope the database is up" timing bugs.

---

## Application Specification

```ruby
# lib/my_app/application.rb
module MyApp
  APPLICATION = {
    name: :my_app,
    version: "1.0.0",
    depends_on: [:logger, :database],

    # Application module (implements callbacks)
    mod: MyApp::Application,

    # Configuration (can be overridden at start time)
    config: {
      pool_size: 10,
      timeout: 30
    },

    # Environment-specific overrides
    env: {
      production: { pool_size: 50 },
      test: { pool_size: 1 }
    }
  }
end
```

---

## Application vs Supervisor

Why not just use supervisors directly?

| Concern | Supervisor | Application |
|---------|------------|-------------|
| Child management | Yes | Via top supervisor |
| Configuration | No | Yes |
| Dependencies | No | Yes |
| Lifecycle hooks | No | Yes |
| Named unit | By registration | By definition |
| Start/stop order | Within tree | Across system |

An application IS a supervisor (at its root) with additional metadata.

---

## Namespace Isolation with Ruby Box

Ruby 4.0's Box feature provides namespace isolation that complements Ractor's
memory isolation. When combined, applications get **defense in depth**:

| Isolation Type | Mechanism | What It Prevents |
|----------------|-----------|------------------|
| Memory | Ractor | One app accessing/corrupting another's state |
| Namespace | Box | One app's monkey patches affecting another |
| Class definitions | Box | Constants/classes colliding between apps |
| Global state | Both | `$global` in one app affecting another |

### The Application Isolation Pattern

Each application gets its own Ractor AND its own Box:

```ruby
# Coordinator starts each application in isolated Ractor + Box
def start_application(app_spec)
  Ractor.new(app_spec, @inbox) do |spec, coord_port|
    # Create isolated namespace for this application
    app_box = Ruby::Box.new
    app_box.require(spec[:entry_point])

    # App's monkey patches stay contained in app_box
    # Even if the app does:
    #   class String; def blank? = empty?; end
    # ...other apps and the coordinator don't see it

    supervisor = app_box.const_get(spec[:supervisor]).new
    supervisor.start(coord_port)
  end
end
```

### What This Enables

**Contained monkey patching**: An application can use gems that patch core
classes (like ActiveSupport) without affecting other applications.

**Gem version isolation**: Two applications can theoretically use different
versions of the same gem if loaded in separate boxes.

**Coordinator protection**: Application code cannot affect the coordinator's
primitives. Even malicious `class Ractor::Port; def send(*) = nil; end` in an
app doesn't break the coordinator's communication.

### Hot Code Reload

Ruby Box may enable hot code reload without full process restart:

```
1. Create new Box for updated application
2. Start new application instance in new Box (new Ractor)
3. Drain traffic from old instance
4. Shut down old instance (old Ractor exits, old Box becomes garbage)
5. Old code is effectively "unloaded" when Box is collected
```

This mirrors BEAM's hot code swap but uses Box's namespace isolation rather
than VM-level module replacement. See [ini.md](./ini.md) for coordinator-level
details on this pattern.

### Caveats

Ruby Box is experimental (Ruby 4.0):

- Requires `RUBY_BOX=1` environment variable
- Some gems may not work (native extensions, certain metaprogramming)
- Performance overhead exists for cross-box calls
- Not all code patterns are Box-compatible

**Umi should function without Box**, using Ractor isolation alone. Box is a
defense-in-depth enhancement for environments where application code may be
untrusted or poorly-behaved.

---

## Shutdown Semantics

When stopping an application:

1. Call `stopping` callback (drain, notify)
2. Send `[:shutdown, timeout]` to top supervisor
3. Supervisor stops children in reverse start order
4. Each child gets chance to clean up (within timeout)
5. Force-kill anything remaining after timeout
6. Call `stopped` callback (release resources)

**Timeout is real**: If an application doesn't stop gracefully, it gets killed.
Design for graceful shutdown, but don't block the system on a hung process.

---

## Relationship to Coordinator

The coordinator (see [ini.md](./ini.md)) manages applications:

```ruby
class Coordinator
  def start_applications(specs)
    sorted = topological_sort(specs)
    sorted.each do |spec|
      app = start_application(spec)
      wait_for_running(app)
      @applications << app
    end
  end

  def stop_applications
    @applications.reverse.each do |app|
      stop_application(app, timeout: @shutdown_timeout)
    end
  end
end
```

The coordinator doesn't know what applications do—only how to start, stop, and
monitor them.

---

## Open Questions

1. **Specification format**: Ruby module? YAML? Both?

2. **Hot configuration**: Can config change without restart?

3. **Partial restart**: Can one application restart without affecting others?
   (Yes for independent apps, tricky for dependents.)

4. **Health reporting**: How does an application signal degraded state vs
   failure?

5. **Dependency types**: Hard (must exist) vs soft (nice to have)?

---

## Review Concerns

_Added during review — these should be resolved before implementation._

1. **Box content duplicated with ini.md** — Both documents have substantial,
   nearly-identical Box sections (hot reload, isolation pattern). Should be
   consolidated into one location with cross-references to avoid drift.

2. **Application-to-Ractor mapping unclear** — Line 236 says "Each application
   gets its own Ractor AND its own Box" but the architecture suggests supervisors
   are the Ractor boundary, and applications are a metadata/lifecycle container.
   Is it 1:1? Can one Ractor host multiple applications? Clarify the relationship.

3. **`wait_for_running` mechanism undefined** — Coordinator calls
   `wait_for_running(app)` but how does the application signal it's running?
   Through a port? A specific message protocol? The handshake between application
   and coordinator needs specification.

4. **Rollback semantics unexplained** — Line 153: "Atomic start (either fully
   started or rolled back on failure)" but what is rollback? If app B fails to
   start, what happens to already-started app A? Stopped? Left running? This has
   operational implications.

5. **Callback timeouts unspecified** — The `stopping` callback happens before
   supervisor shutdown. What if draining takes too long? Is there a separate
   timeout for callbacks vs. child shutdown? Or one shared timeout split between
   them?

6. **`prepare` error handling** — Shows `[:error, reason]` to abort but doesn't
   explain consequences. Is the error logged? Does boot abort immediately? Are
   already-started apps rolled back per concern #4?

7. **Environment detection mechanism** — Spec shows `env: { production: {...} }`
   but how does the system know which environment? `CONFIG_ENV`? `RUBY_ENV`?
   `RACK_ENV`? Should be explicit.

8. **Logger dependency inconsistency** — Example shows
   `depends_on: [:logger, :database]` but ini.md says logger is a kernel Ractor,
   not an application. Can applications depend on kernel Ractors? Is that a
   different dependency type? Clarify.

9. **"Contained monkey patching" claim may be optimistic** — Claims ActiveSupport
   patches stay contained, but gem loading in Ruby is complex. If two apps in
   separate Boxes require the same gem differently, what actually happens? This
   needs empirical validation or caveats.

---

## References

- [pre.md](./pre.md) - Ruby 4.0 primitives (Ractor, Port, Box)
- [beam-otp-analysis.md](../beam-otp-analysis.md) - Application lifecycle detail
- [ini.md](./ini.md) - Coordinator (starts/stops applications)
- [sup.md](./sup.md) - Supervision (what applications contain)
