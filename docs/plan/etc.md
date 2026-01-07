# ETC: Future Enhancements

Patterns and capabilities that build on top of the core architecture. Not
required for a working system, but valuable for production robustness.

---

## Strategic Checkpointing

OTP's "let it crash" means losing in-flight state—the process restarts fresh.
For many use cases this is fine. But production systems often need:

- **Retry capability**: Don't lose the request that was in progress
- **Idempotency**: Don't redo work that already succeeded
- **Debuggability**: Understand what state led to a crash

### The Core Insight

Ruby can achieve capturable/restorable state without Erlang-style immutability:

- State typically lives in instance variables (not scattered randomly)
- Ruby has reflection (`instance_variables`, `instance_variable_get/set`)
- Marshal can serialize most pure-data objects
- Strategic checkpointing avoids continuous overhead

The question isn't "how do we capture all state changes" but **"when does a
snapshot have high value?"**

### Risk-Stratified Checkpointing

Not all code is equally dangerous:

**High-risk operations** (checkpoint around these):
- External HTTP/database calls
- Subprocess interaction (Proctor's domain)
- File I/O, network operations
- Parsing untrusted input

**Low-risk operations** (no checkpoint needed):
- Waiting for messages (idle)
- Pure computation on in-memory state
- Pattern matching, dispatching

### Strategic Checkpoint Moments

```
  Message arrives
       │
       ▼
   ┌───────┐
   │ [CP1] │  Before processing - enables clean abandon on failure
   └───────┘
       │
       ▼
   ┌───────┐
   │ [CP2] │  Before risky operation - enables retry if call fails
   └───────┘
       │
       ▼
   ═══════════ DANGER ZONE (external call) ═══════════
       │
       ▼
   ┌───────┐
   │ [CP3] │  After success - prevents redoing completed work
   └───────┘
       │
       ▼
  Back to idle
```

### Two Types of Snapshots

**Recovery Snapshots ("Last Known Good")**

Taken at strategic success points. Used to restore a restarted worker.

```ruby
result = risky_external_call()
checkpoint!(:recovery)  # We succeeded—don't redo this on restart
update_state_with(result)
```

Properties:
- State is consistent and valid
- Safe to resume from here
- Taken AFTER successful operations

**Diagnostic Snapshots ("Failure State")**

Taken at moment of failure. Used for debugging, not recovery.

```ruby
rescue => e
  checkpoint!(:diagnostic)  # What was state when we crashed?
  raise
end
```

Properties:
- State may be inconsistent or corrupted
- Useful for debugging, not for restarting
- Taken IN exception handlers

**Why both?** If we only had diagnostic, we might restore to corrupted state.
If we only had recovery, we'd lose insight into what failed.

### Is Exception-Handler Checkpointing Too Heavy?

Usually no, for typical workers:

| Factor | Concern | Typical Reality |
|--------|---------|-----------------|
| State size | Big state = slow | Most workers have small state (KB, not MB) |
| Serialization | Marshal overhead | Microseconds for simple objects |
| Storage | Disk I/O | Can store in memory (supervisor holds it) |
| Frequency | Every exception? | Exceptions should be rare in healthy systems |

For very large state, capture selectively:

```ruby
rescue => e
  @failure_context = {
    exception: e.class.name,
    message: e.message,
    backtrace: e.backtrace.first(10),
    request_id: @current_request_id,
    operation: @current_operation
  }
  raise
end
```

### Implementation Sketch

**Explicit checkpointing:**

```ruby
class Umi::Worker
  def checkpoint!(type = :recovery)
    snapshot = capture_state
    case type
    when :recovery
      @supervisor_port << [:checkpoint, self.id, snapshot]
    when :diagnostic
      @last_diagnostic = snapshot
    end
  end

  def capture_state
    instance_variables.each_with_object({}) do |var, hash|
      value = instance_variable_get(var)
      next if var.to_s.start_with?('@_')  # Skip internal
      next unless marshalable?(value)
      hash[var] = value
    end
  end
end
```

**Declarative risky operations:**

```ruby
class MyWorker < Umi::Worker
  extend Umi::RiskyOperation

  risky def call_external_api(data)
    # Auto-checkpoints before, after, and on exception
    http.post(url, data)
  end
end
```

**Supervisor-side handling:**

```ruby
def handle_child_exit(child_id, reason, diagnostic_snapshot)
  recovery_snapshot = @last_recovery_snapshots[child_id]

  # Restart from last known good state
  new_child = start_child(child_id, from: recovery_snapshot)

  # Log diagnostic for debugging
  if diagnostic_snapshot
    Logger.error("Child #{child_id} failed", state: diagnostic_snapshot)
  end
end
```

### Implications for Proctor

Every Proctor interaction is a risky operation:

| Moment | Checkpoint Value |
|--------|------------------|
| Process spawned | Initial state captured |
| Before stdin write | Can retry send on failure |
| After stdin write | Know what was sent |
| After stdout read | Have the response |
| Process exits | Capture exit status + buffered output |

---

## Process Groups

Registry gives 1:1 (name → ractor). Sometimes you need 1:N (name → [ractors]).

```ruby
# All workers in a pool
Groups.members(:worker_pool) → [ractor1, ractor2, ractor3]

# Broadcast to all
Groups.broadcast(:worker_pool, message)

# Send to one (round-robin or random)
Groups.notify(:worker_pool, message)
```

This builds on Registry—a separate abstraction for group membership and
messaging patterns.

---

## Adaptive Backpressure

Beyond simple "wait for response" backpressure, Elixir's Logger demonstrates
adaptive mode switching:

```
messages >= discard_threshold → :discard (drop messages)
messages >= sync_threshold   → :sync    (wait for response)
otherwise                    → :async   (fire-and-forget)
```

This lets high-throughput components stay fast under normal load but
automatically slow down (or shed load) when overwhelmed.

Implementation would involve:
- Queue depth monitoring
- Mode switching thresholds
- Graceful transitions between modes

---

## Distribution

The analysis in `beam-otp-analysis.md` covers BEAM's distribution architecture:
- Discovery (EPMD)
- Connection setup (net_kernel)
- Message transport (VM runtime)
- Full mesh topology
- Phoenix Tracker's CRDT-based presence

This is complex machinery. Single-process resilience should be solid before
considering multi-node distribution.

If/when distribution becomes relevant:
- Start with simple patterns (explicit connections, not auto-mesh)
- Consider CRDTs for eventually-consistent shared state
- Study Phoenix Tracker's delta-replication approach

---

## Complete Implementation Examples

These are extended examples showing how the pieces fit together. They're
reference implementations—not production code—meant to illustrate patterns.

### Coordinator Boot Sequence

A complete coordinator skeleton showing the two-phase pattern (bootstrap →
steady-state), signal handling, and kernel Ractor management:

```ruby
# lib/umi/coordinator.rb
#
# The coordinator IS the main Ractor. It creates ports it can receive on,
# sets up signal handlers, and runs the main event loop.

module Umi
  class Coordinator
    def boot(config)
      # Phase 0: Set up signal handling (before anything else)
      @signal_port = Ractor::Port.new
      @monitor_port = Ractor::Port.new
      setup_signal_handlers

      # Phase 1: Parse configuration
      @config = parse_config(config)
      @status = :starting

      # Phase 2: Start kernel Ractors (halt on death)
      @kernel = {}
      @kernel[:registry] = start_kernel_ractor(Umi::Registry)
      @kernel[:logger] = start_kernel_ractor(Umi::Logger)
      report_progress(:kernel_started)

      # Check for shutdown between major phases
      check_for_shutdown

      # Phase 3: Start applications in dependency order
      @applications = []
      sorted_apps(@config[:applications]).each do |app_spec|
        app = start_application(app_spec)
        @applications << app
        report_progress(:"#{app.name}_started")
        check_for_shutdown
      end

      # Phase 4: Transition to steady state
      @status = :running
      report_progress(:started)
      steady_state_loop
    end

    private

    def setup_signal_handlers
      Signal.trap("TERM") { @signal_port << [:shutdown, :sigterm] rescue nil }
      Signal.trap("INT")  { @signal_port << [:shutdown, :sigint] rescue nil }
      Signal.trap("HUP")  { @signal_port << [:reload_config] rescue nil }
      Signal.trap("PIPE", "IGNORE")
    end

    def start_kernel_ractor(mod)
      ractor = mod.start_link
      ractor.monitor(@monitor_port)
      ractor
    end

    def start_application(spec)
      Ractor.new(spec, @monitor_port) do |app_spec, mon_port|
        # Optional: Create isolated Box for namespace protection
        # app_box = Ruby::Box.new
        # app_box.require(app_spec[:entry_point])
        # supervisor = app_box.const_get(app_spec[:supervisor]).new

        supervisor = app_spec[:mod].new
        supervisor.start(app_spec[:config])
      end
    end

    def check_for_shutdown
      loop do
        # Non-blocking check for pending signals
        ready, value = Ractor.select(@signal_port, yield_value: nil, timeout: 0)
        break unless ready

        case value
        in [:shutdown, reason]
          abort_boot(reason)
        else
          # Ignore other signals during boot
        end
      end
    end

    def steady_state_loop
      loop do
        ready, value = Ractor.select(@signal_port, @monitor_port)

        case [ready, value]
        # --- Kernel death = system death ---
        in [@monitor_port, [:exited, ractor, reason]]
          if kernel_ractor?(ractor)
            crash("Kernel Ractor terminated", ractor, reason)
          end

        # --- Shutdown signals ---
        in [@signal_port, [:shutdown, reason]]
          shutdown(reason)
          break

        # --- Config reload ---
        in [@signal_port, [:reload_config]]
          @config = reload_configuration
          broadcast_to_apps([:config_reloaded, @config])
        end
      end
    end

    def shutdown(reason)
      @status = :stopping

      # Stop applications in reverse dependency order
      @applications.reverse.each do |app|
        shutdown_with_timeout(app, @config[:shutdown_timeout] || 5000)
      end

      # Stop kernel Ractors (except logger)
      @kernel.each do |name, ractor|
        next if name == :logger
        shutdown_with_timeout(ractor, 1000)
      end

      # Logger last
      shutdown_with_timeout(@kernel[:logger], 1000) if @kernel[:logger]

      # Exit with appropriate code
      case reason
      when :stop then exit(0)
      when :sigterm, :sigint then exit(0)
      else exit(1)
      end
    end

    def shutdown_with_timeout(ractor, timeout_ms)
      ractor.send([:shutdown, timeout_ms]) rescue nil
      # Wait for exit with timeout, force-kill if needed
      # (implementation depends on Ractor.select timeout semantics)
    end

    def kernel_ractor?(ractor)
      @kernel.values.include?(ractor)
    end

    def broadcast_to_apps(message)
      @applications.each do |app|
        app.send(message) rescue nil
      end
    end

    def crash(reason, *details)
      # Log error, then halt
      @kernel[:logger]&.send([:error, reason, details]) rescue nil
      sleep(0.5)  # Let error messages flush
      exit(1)
    end
  end
end
```

### External Supervision Patterns

The coordinator cannot supervise itself. External systems handle restarts:

**systemd unit file:**

```ini
[Unit]
Description=Umi Application
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/ruby /path/to/app/boot.rb
Restart=on-failure
RestartSec=1
# Exit 0 = intentional stop, don't restart
# Exit non-zero = crash, do restart

# Health check
ExecStartPost=/bin/sh -c 'until curl -s http://localhost:8080/health; do sleep 1; done'

[Install]
WantedBy=multi-user.target
```

**Kubernetes liveness probe:**

```yaml
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: app
    livenessProbe:
      httpGet:
        path: /health
        port: 8080
      initialDelaySeconds: 10
      periodSeconds: 5
    readinessProbe:
      httpGet:
        path: /ready
        port: 8080
```

**Docker Compose:**

```yaml
services:
  app:
    build: .
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 3
```

---

## References

- [strategic-checkpointing.md](../strategic-checkpointing.md) - Full checkpointing analysis
- [beam-otp-analysis.md](../beam-otp-analysis.md) - Distribution architecture
- [otp-initialization.md](../otp-initialization.md) - Source for coordinator examples
- [ini.md](./ini.md) - Coordinator design principles
