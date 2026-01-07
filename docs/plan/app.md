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

## References

- [beam-otp-analysis.md](../beam-otp-analysis.md) - Application lifecycle detail
- [ini.md](./ini.md) - Coordinator (starts/stops applications)
- [sup.md](./sup.md) - Supervision (what applications contain)
