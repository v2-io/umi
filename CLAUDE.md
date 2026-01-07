# CLAUDE.md - Context for AI Agents

This file provides context for AI agents working on the Umi codebase.

## What Is Umi?

Umi (海, "sea/deep water") brings OTP-like resilience patterns to Ruby 4.0. It is
**not** a port of Erlang/Elixir OTP. It solves the same problems—cascading failures,
blocked threads, crack propagation—using Ruby-native idioms.

Read `UMI_FIRST_PRINCIPLES.md` for the full philosophy. The key insight:

> "The goal is not to make Ruby act like Erlang. The goal is to solve the same
> problems in a way that feels natural to Rubyists."

## Current State

**Implemented:**
- `Umi::Proctor` - Wraps external processes as Ractor-citizens
- `Umi::MCPClient` - MCP (Model Context Protocol) client built on Proctor
- `Umi::Registry` - Name-based Ractor lookup with auto-cleanup on death
- `Umi::Worker` - Ractor wrapper with call/cast messaging and lifecycle
- `Umi::Supervisor` - one_for_one restart strategy with restart bounding

**Not yet implemented:**
- Resilience patterns (circuit breaker, retry, bulkhead)
- Coordinator (application boot sequencing)
- Additional supervision strategies (one_for_all, rest_for_one)

## Project Structure

```
lib/
  umi.rb                 # Entry point, VERSION constant
  umi/
    proctor.rb           # External process wrapper (854 lines, well-documented)
    mcp_client.rb        # MCP protocol client

test/
  proctor_test.rb        # Basic functionality (16 tests)
  proctor_api_test.rb    # API contract tests (53 tests)
  proctor_stress_test.rb # Stress tests, edge cases (extensive)
  mcp_*.rb               # MCP client tests
  fixtures/              # Test fixtures (echo, counter, etc.)

spikes/                  # Exploratory code that informed the design
  FINDINGS.md            # Summary of what we learned
  FINDINGS-DETAILS.md    # Detailed test results
  spike_*.rb             # Individual explorations
```

## Key Design Decisions

### 1. OTP-style Tagged Tuples

All Proctor methods return tagged tuples for pattern matching:

```ruby
case proctor.pop_stdout(timeout)
in [:ok, data]    # Success
in nil            # Timeout (normal, not an error)
in [:closed, result]  # Process exited
end
```

Timeouts return `nil`, not exceptions. This enables OTP-style polling where
timeout is expected control flow, not an error condition.

### 2. Process Spawned Inside Ractor

The external process is spawned **inside** a Watcher Ractor, not passed in.
This was discovered during spikes - passing IO objects across Ractor boundaries
caused hangs for bidirectional pipes.

### 3. Death Detection via Ractor.monitor

Ruby 4.0 added `Ractor#monitor(port)` which sends `:exited` or `:aborted` to
the specified port when the Ractor terminates. This provides the liveness
detection primitive we need.

### 4. Timer Thread Pattern

`Ractor.select` has no native timeout. We use a timer Thread that sends
`:timeout` to a port, then select on both the inbox and timer port.

## Ruby 4.0 Ractor Notes

Key APIs we use:
- `Ractor::Port.new` - Create a mailbox
- `port.send(msg)` / `port << msg` - Send to port
- `port.receive` - Blocking receive
- `Ractor.select(port1, port2, ...)` - Wait on multiple ports
- `ractor.monitor(port)` - Get notified when Ractor dies (sends `:exited` or `:aborted`)
- `ractor.value` - Get return value (replaces old `ractor.take`)

**CRITICAL - Shareable Procs:**

Regular Procs/lambdas **cannot cross Ractor boundaries**. Use `Ractor.shareable_proc`:

```ruby
# WRONG - will fail with "allocator undefined for Proc"
start_fn = -> { Worker.start_link }
Ractor.new(start_fn) { |fn| fn.call }

# CORRECT - shareable_proc is isolated from outer scope
start_fn = Ractor.shareable_proc { Worker.start_link }
Ractor.new(start_fn) { |fn| fn.call }
```

The block passed to `shareable_proc` **cannot access outer variables** - it's fully
isolated. Pass data via Ractor.new arguments instead.

**What IS shareable:**
- Frozen immutable objects, Symbols, Numerics, `true`/`false`/`nil`
- `Ractor::Port` instances
- **Class and Module objects** (so you can pass `WorkerClass` and call methods on it)
- Procs created with `Ractor.shareable_proc`

**Constraints:**
- Only port creator can call `receive` on it
- `monitor` sends just `:exited` or `:aborted` - NOT which Ractor died (use per-registration ports)
- `Ractor.select` has **no timeout** - use timer Thread + port pattern
- Threads work inside Ractors (essential for async I/O)

## Development Commands (devex)

This project uses [devex](~/src/_gems/devex/) for development tasks:

```bash
dx test              # Run minitest + standalone tests (skip chaos/stress)
dx test --quick      # Run only minitest (fastest)
dx test -a           # Run ALL tests including chaos and stress (slow!)
dx test -s           # Run standalone tests only
dx test --stress     # Run stress tests

dx lint              # Run RuboCop
dx lint --fix        # Auto-fix linting issues
dx gem build         # Build the gem
dx gem install       # Build and install locally
```

**Note:** The chaos and stress tests take a long time. Use `--quick` for fast feedback.

## Testing

```bash
# Preferred: use devex
dx test

# Run individual test files
ruby test/proctor_test.rb
ruby test/registry_test.rb
ruby test/worker_test.rb
ruby test/supervisor_test.rb

# Stress tests (can take a while)
ruby test/proctor_stress_test.rb

# Reproduce a specific failure
SEED=12345 ruby test/proctor_stress_test.rb
```

The stress tests have a watchdog that dumps thread traces if tests hang.

## Common Patterns

### Reading from a process with timeout

```ruby
case proctor.pop_stdout(5.0)
in [:ok, line]
  process(line)
in nil
  # Timeout - check health, do other work, retry
in [:closed, result]
  handle_exit(result)
end
```

### Request-response pattern

```ruby
proctor << "REQUEST\n"
case proctor.pop_stdout(30)
in [:ok, response]
  parse(response)
in nil
  raise "Request timed out"
in [:closed, _]
  raise "Process died"
end
```

### Block form with cleanup

```ruby
Umi::Proctor.open("long-running-server") do |server|
  server << command
  server.pop_stdout!
end  # Automatically cleaned up
```

## Known Issues

See `KNOWN_ISSUES.md` for documented edge cases and their fixes.

## When Extending Umi

1. **Read `UMI_FIRST_PRINCIPLES.md` first** - Understand the problems being solved
2. **Prefer composition over inheritance** - Ruby loves composition
3. **Timeouts everywhere** - "Hope is not a design method"
4. **Pattern matching for control flow** - Use tagged tuples
5. **Let it crash, but contain it** - Ractors are natural bulkheads
6. **Document the why** - Future agents need context, not just code

## References

- `UMI_FIRST_PRINCIPLES.md` - Philosophy and roadmap
- `phase-1-pilot-proctor.md` - Proctor design and implementation plan
- `spikes/FINDINGS.md` - Ruby 4.0 Ractor discoveries
- *Release It!* by Michael Nygard - The problems we're solving
- *Designing Elixir Systems with OTP* - One solution (not ours to copy)
