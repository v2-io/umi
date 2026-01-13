# ADR-001: Proctor Supervisor

**Status:** Draft
**Date:** 2025-12-27

## Context

`Umi::Proctor` wraps external processes as Ractor-citizens with bidirectional
messaging and death notification. However, long-running systems need processes
to stay available. When a process dies unexpectedly, something must restart it.

OTP solves this with Supervisors - processes that monitor children and restart
them according to configurable policies. The key insight: restart logic should
be separate from business logic.

We want to provide this for Proctors specifically:
- Keep external processes alive
- Handle transient failures automatically
- Prevent restart storms (max restarts within time window)
- Let consumers rely on process availability

## Decision

Introduce `Umi::Proctor::Supervisor` - a supervisor specifically for Proctors.

### API

```ruby
# Create supervisor with restart limits
supervisor = Umi::Proctor::Supervisor.start(
  max_restarts: 3,
  within_seconds: 5
)

# Register processes to supervise
supervisor.supervise(:redis, %w[redis-server --port 6379],
  restart: :permanent,
  env: { "REDIS_PASSWORD" => secret },
  on_output: ->(line) { logger.debug("redis: #{line}") }
)

supervisor.supervise(:worker, %w[./my-worker],
  restart: :transient,
  chdir: "/app"
)

# Fetch current proctor (may be new instance after restart)
redis = supervisor.fetch(:redis)
redis << "PING\r\n"
response = redis.pop_stdout!(5)

# React to lifecycle events
supervisor.on_restart(:redis) do |old_result, new_proctor|
  logger.warn "Redis restarted (was: exit #{old_result.exit_code})"
  new_proctor << "SELECT 1\r\n"  # Re-establish state
end

supervisor.on_give_up(:redis) do |restart_history|
  logger.error "Redis failed #{restart_history.size} times, giving up"
  alert_humans!
end

# Graceful shutdown
supervisor.stop  # Stops all supervised proctors
```

### Restart Policies

Following OTP semantics:

| Policy | Behavior |
|--------|----------|
| `:permanent` | Always restart, regardless of exit reason |
| `:transient` | Restart only on abnormal exit (non-zero code or signal) |
| `:temporary` | Never restart (supervisor just tracks it) |

### Restart Limiting

To prevent restart storms, track restarts in a sliding time window:

```ruby
max_restarts: 3,
within_seconds: 5
```

If a process restarts 3 times within 5 seconds, stop trying and invoke
`on_give_up`. This prevents infinite loops when a process is fundamentally
broken (missing dependency, bad config, etc.).

The window is per-process, not global. Redis failing doesn't affect worker's
restart budget.

### Consumer Access Pattern

Consumers call `fetch(:name)` to get the current Proctor instance. If the
process died and was restarted, they get the new instance.

```ruby
loop do
  redis = supervisor.fetch(:redis)
  redis << request

  case redis.pop_stdout(5)
  in [:ok, response]
    handle(response)
  in [:closed, result]
    # Process died - supervisor will restart it
    # Next fetch() returns new instance
    logger.warn "Redis died mid-request, retrying"
    next
  in nil
    raise "Timeout"
  end
end
```

This is explicit: consumers know they might get a different instance. This
matters because:
- Process state is lost on restart (Redis SELECT, working directory, etc.)
- In-flight operations fail on the old instance
- Consumers may need to re-establish state on the new instance

### Why Not a Transparent Proxy?

We considered a proxy that forwards to the current Proctor and switches
transparently after restart. Rejected because:

1. **Hides important state changes** - Consumer might have established state
   (Redis SELECT, negotiated protocol version) that's lost on restart
2. **Ambiguous failure semantics** - If operation fails, was it before or
   after restart? Should it retry?
3. **Ruby philosophy** - Explicit over implicit

The `on_restart` callback provides a hook to re-establish state when needed.

### Implementation Sketch

```ruby
module Umi
  class Proctor
    class Supervisor
      Child = Data.define(:name, :command, :options, :policy, :proctor, :restarts)

      def initialize(max_restarts:, within_seconds:)
        @max_restarts = max_restarts
        @within_seconds = within_seconds
        @children = {}
        @callbacks = { restart: {}, give_up: {} }
        @mutex = Mutex.new
      end

      def supervise(name, command, restart:, **options)
        @mutex.synchronize do
          proctor = start_proctor(name, command, options)
          @children[name] = Child.new(
            name: name,
            command: command,
            options: options,
            policy: restart,
            proctor: proctor,
            restarts: []  # timestamps of recent restarts
          )
        end
      end

      def fetch(name)
        @mutex.synchronize { @children[name]&.proctor }
      end

      private

      def start_proctor(name, command, options)
        proctor = Proctor.new(*command, **options.slice(:env, :chdir, :stderr))

        proctor.on_exit do |result|
          handle_exit(name, result)
        end

        proctor
      end

      def handle_exit(name, result)
        @mutex.synchronize do
          child = @children[name] or return

          return unless should_restart?(child, result)

          # Prune old restart timestamps
          cutoff = Time.now - @within_seconds
          recent = child.restarts.select { |t| t > cutoff }

          if recent.size >= @max_restarts
            invoke_give_up(name, recent)
            return
          end

          # Restart
          new_proctor = start_proctor(name, child.command, child.options)
          new_restarts = recent + [Time.now]

          @children[name] = child.with(
            proctor: new_proctor,
            restarts: new_restarts
          )

          invoke_restart(name, result, new_proctor)
        end
      end

      def should_restart?(child, result)
        case child.policy
        when :permanent then true
        when :transient then !result.success?
        when :temporary then false
        end
      end
    end
  end
end
```

### Thread Safety

The supervisor uses a Mutex to protect child state. This is simpler than a
full Ractor-based design and sufficient for the use case: supervision
operations are infrequent compared to actual Proctor I/O.

A future version could use a dedicated Ractor if contention becomes an issue.

## Consequences

### Positive

- **Reliability** - Processes stay available despite transient failures
- **Separation of concerns** - Restart logic lives in supervisor, not consumer
- **Explicit semantics** - Consumers know when they're getting a new instance
- **OTP-familiar** - Developers who know OTP will recognize the patterns
- **Foundation for more** - Same patterns apply to supervising Ractors later

### Negative

- **Complexity** - Another abstraction to understand
- **Callback threading** - `on_restart`/`on_give_up` run in death handler context;
  users must be careful about blocking or raising
- **No proxy convenience** - Consumers must handle `fetch()` returning different
  instances; can't just hold a reference forever

### Neutral

- **Proctor-specific** - This is intentionally scoped to Proctors. A general
  Ractor supervisor would be a separate component, though it would share patterns.

## Alternatives Considered

### 1. Supervision Inside Proctor

Add restart logic directly to Proctor: `Proctor.new(cmd, restart: :permanent)`.

Rejected: Violates separation of concerns. Proctor wraps a process; it shouldn't
also manage restart policy. Combining them makes both harder to reason about.

### 2. General Supervisor First

Build a general `Umi::Supervisor` that works with any "supervisable" thing.

Rejected for now: We'd be designing abstractions without concrete use cases.
Starting with Proctor supervision gives us real constraints. A general
supervisor can follow once patterns are proven.

### 3. Transparent Proxy

Return a proxy object from `supervise()` that forwards to current Proctor.

Rejected: Hides state changes that consumers often need to know about. See
"Why Not a Transparent Proxy?" above.

## Open Questions

1. **Should `fetch` block during restart?** Currently it would return `nil` or
   the dead proctor briefly. Options:
   - Return `nil`, consumer retries
   - Block until new proctor is ready
   - Return dead proctor, let consumer discover via `[:closed]`

2. **Health checks?** Should supervisor proactively check process health, or
   only react to death? Proactive checks catch hung processes but add complexity.

3. **Supervisor-of-supervisors?** If supervisor itself fails, who restarts it?
   For now, assume supervisor is reliable (it's just Ruby code, no external deps).
   Application-level restart would use process managers (systemd, etc.).

## References

- [OTP Supervisor Behaviour](https://www.erlang.org/doc/design_principles/sup_princ.html)
- `UMI_FIRST_PRINCIPLES.md` - "Let it crash" philosophy
- `phase-1-pilot-proctor.md` - Proctor design
