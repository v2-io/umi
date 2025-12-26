# ROTP: Ruby OTP - Building Actor Infrastructure on Ruby 4.0

## Executive Summary

Ruby 4.0 (released December 25, 2025) introduces significant improvements to Ractors
that make building OTP-like patterns genuinely viable for the first time:

- **Ractor::Port** - A true Actor Model mailbox abstraction
- **Improved isolation** - `Ruby Box` for module/definition isolation
- **Better parallelism** - Reduced GVL contention, less CPU cache contention
- **Cleaner API** - `Ractor#join`, `Ractor#value`, removed `yield`/`take`

This document maps the OTP (Elixir/Erlang) primitives to Ruby 4.0 constructs and
proposes a layered architecture for building a Ruby OTP equivalent.

---

## Part 1: Primitive Mapping

### Core Process Abstraction

| OTP Concept | Ruby 4.0 Equivalent | Notes |
|-------------|---------------------|-------|
| Erlang Process | `Ractor` | True parallelism, isolated memory |
| Process Mailbox | `Ractor::Port` | New in 4.0 - major improvement |
| `spawn/1` | `Ractor.new { }` | Block becomes process body |
| `self()` | `Ractor.current` | Reference to current ractor |
| `send/2` | `ractor.send(msg)` or `port << msg` | Non-blocking, queued |
| `receive` | `Ractor.receive` or `port.receive` | Blocking wait for message |
| Process linking | `Ractor#join` | Waits for termination |
| Process value | `Ractor#value` | Gets return value on exit |

### Message Passing

```ruby
# OTP (Elixir)
send(pid, {:hello, "world"})
receive do
  {:hello, msg} -> msg
end

# Ruby 4.0
pid << [:hello, "world"]  # or pid.send([:hello, "world"])
msg = Ractor.receive       # blocks until message arrives
case msg
in [:hello, content] then content
end
```

### What Ruby 4.0 Has

1. **Ractor** - Isolated parallel execution unit
2. **Ractor::Port** - Named mailbox, can have multiple per Ractor
3. **Ractor.select** - Wait on multiple ractors (like Erlang's selective receive)
4. **Ractor.make_shareable** - Freeze objects for safe sharing
5. **Ractor isolation** - No access to outer scope variables

### What We Must Build

1. **GenServer** - Stateful server abstraction (call/cast/info)
2. **Supervisor** - Process monitoring and restart strategies
3. **Registry** - Process naming and discovery
4. **Application** - Lifecycle management
5. **DynamicSupervisor** - Runtime process spawning
6. **Task** - One-shot async operations

---

## Part 2: The OTP Book's Layered Architecture (Applied to Ruby)

The "Designing Elixir Systems with OTP" book presents a layered approach:

```
┌─────────────────────────────────────────┐
│           API Layer                      │  <- Clean public interface
├─────────────────────────────────────────┤
│           Boundary Layer                 │  <- GenServer, process management
├─────────────────────────────────────────┤
│           Lifecycle Layer                │  <- Supervisors, restart policies
├─────────────────────────────────────────┤
│           Functional Core                │  <- Pure Ruby, no concurrency
└─────────────────────────────────────────┘
```

### Layer 1: Functional Core (Data + Pure Functions)

This is pure Ruby - no Ractors, no concurrency concerns. Following the book's
guidance, we keep business logic in composable, testable pure functions.

```ruby
# Example: Quiz Core (from OTP book, translated to Ruby)
module Mastery
  module Core
    class Quiz
      attr_reader :title, :mastery, :templates, :current_question

      def self.new(fields)
        # Pure constructor
      end

      def add_template(template_fields)
        # Returns new Quiz with template added
      end

      def select_question
        # Returns new Quiz with question selected
      end
    end
  end
end
```

### Layer 2: Boundary Layer (GenServer Pattern)

This is where we wrap the functional core in Ractor-based servers.

```ruby
# ROTP GenServer equivalent
module ROTP
  class GenServer
    # Callbacks the user implements:
    # - init(args) -> {:ok, state} | {:stop, reason}
    # - handle_call(request, from, state) -> {:reply, response, new_state}
    # - handle_cast(request, state) -> {:noreply, new_state}
    # - handle_info(msg, state) -> {:noreply, new_state}

    def self.start_link(mod, args, opts = {})
      name = opts[:name]
      reply_port = Ractor::Port.new

      ractor = Ractor.new(mod, args, reply_port, name) do |mod, args, reply_port, name|
        case mod.init(args)
        in [:ok, state]
          reply_port << [:started, Ractor.current.default_port]
          run_loop(mod, state)
        in [:stop, reason]
          reply_port << [:error, reason]
        end
      end

      case reply_port.receive
      in [:started, port]
        Registry.register(name, port) if name
        [:ok, port]
      in [:error, reason]
        [:error, reason]
      end
    end

    private

    def self.run_loop(mod, state)
      loop do
        msg = Ractor.receive
        case msg
        in [:call, request, reply_port]
          result = mod.handle_call(request, reply_port, state)
          case result
          in [:reply, response, new_state]
            reply_port << response
            state = new_state
          in [:stop, reason, response, _]
            reply_port << response
            break
          end

        in [:cast, request]
          result = mod.handle_cast(request, state)
          case result
          in [:noreply, new_state]
            state = new_state
          in [:stop, reason, _]
            break
          end

        else
          # handle_info for unexpected messages
          result = mod.handle_info(msg, state)
          case result
          in [:noreply, new_state]
            state = new_state
          end
        end
      end
    end
  end

  # Client-side helpers
  module GenServer
    def self.call(server, request, timeout: 5000)
      reply_port = Ractor::Port.new
      server << [:call, request, reply_port]
      # TODO: timeout handling with Ractor.select
      reply_port.receive
    end

    def self.cast(server, request)
      server << [:cast, request]
      :ok
    end
  end
end
```

### Layer 3: Lifecycle Layer (Supervisor Pattern)

The key insight from the OTP book: Supervisors use `spawn_link` + `trap_exit`
to monitor children. In Ruby 4.0, we need to simulate this with Ractors.

**Challenge**: Ruby Ractors don't have built-in linking/monitoring like Erlang.
We must build it ourselves using a supervisory Ractor that polls or receives
exit notifications.

```ruby
module ROTP
  class Supervisor
    STRATEGIES = {
      one_for_one: :one_for_one,      # Only restart failed child
      one_for_all: :one_for_all,      # Restart all if one fails
      rest_for_one: :rest_for_one     # Restart failed + those started after
    }

    ChildSpec = Data.define(:id, :start, :restart, :shutdown, :type)

    def self.start_link(mod, args, opts = {})
      # The supervisor itself is a GenServer-like Ractor
      # that monitors its children
    end

    # Example child spec
    def self.child_spec(mod, args = [])
      ChildSpec.new(
        id: mod,
        start: -> { mod.start_link(args) },
        restart: :permanent,  # :permanent | :transient | :temporary
        shutdown: 5000,
        type: :worker         # :worker | :supervisor
      )
    end
  end
end
```

**Key Supervision Insight from OTP Book**:
> "When a process uses `start_link/2` to create a child, the Erlang BEAM will
> notify the parent process when the child dies. Supervisors use a combination
> of these techniques to manage failures. They link to all processes they start,
> so those processes will go down if the supervisor goes down. However, they set
> a special `trap_exit` flag, so that child processes going down just send
> messages to the supervisors."

**Ruby 4.0 Approach**:
Since Ractors don't have native linking, we have options:

1. **Polling approach**: Supervisor periodically checks `ractor.alive?`
2. **Heartbeat approach**: Children send periodic heartbeats to supervisor
3. **Wrapper approach**: Wrap child ractors in a monitoring ractor that
   catches exceptions and notifies supervisor

Option 3 is most faithful to OTP semantics:

```ruby
def self.start_child_with_monitoring(child_spec, supervisor_port)
  Ractor.new(child_spec, supervisor_port) do |spec, sup_port|
    begin
      result = spec.start.call  # Start the actual child
      case result
      in [:ok, child_port]
        sup_port << [:child_started, spec.id, child_port, Ractor.current]
        Ractor.current.join  # Keep this wrapper alive while child runs
      end
    rescue => e
      sup_port << [:child_exit, spec.id, :error, e]
    end
  end
end
```

---

## Part 3: Design Decisions

### 3.1 Registry (Process Naming)

OTP has several registry mechanisms. For Ruby, we need:

```ruby
module ROTP
  class Registry
    # Global registry is itself a Ractor
    @registry_port = nil

    def self.start
      @registry_port = Ractor.new do
        names = {}
        loop do
          case Ractor.receive
          in [:register, name, port, reply_port]
            names[name] = port
            reply_port << :ok
          in [:lookup, name, reply_port]
            reply_port << names[name]
          in [:unregister, name, reply_port]
            names.delete(name)
            reply_port << :ok
          end
        end
      end.default_port
    end

    def self.register(name, port)
      reply_port = Ractor::Port.new
      @registry_port << [:register, name, port, reply_port]
      reply_port.receive
    end

    def self.whereis(name)
      reply_port = Ractor::Port.new
      @registry_port << [:lookup, name, reply_port]
      reply_port.receive
    end
  end
end
```

### 3.2 Application Lifecycle

Following the OTP book's `Application` pattern:

```ruby
module ROTP
  class Application
    def self.start
      # Start the root supervisor
      children = [
        ROTP::Registry.child_spec,
        # ... other core services
      ]
      ROTP::Supervisor.start_link(children, strategy: :one_for_one)
    end
  end
end
```

### 3.3 Task (One-shot Async)

OTP's Task is useful for fire-and-forget or await patterns:

```ruby
module ROTP
  class Task
    def self.async(callable)
      reply_port = Ractor::Port.new
      ractor = Ractor.new(callable, reply_port) do |work, port|
        result = work.call
        port << [:ok, result]
      rescue => e
        port << [:error, e]
      end
      { ractor: ractor, port: reply_port }
    end

    def self.await(task, timeout: 5000)
      # TODO: timeout with Ractor.select
      case task[:port].receive
      in [:ok, result] then result
      in [:error, e] then raise e
      end
    end

    def self.async_stream(enumerable, &block)
      # Like Elixir's Task.async_stream
      # Runs block for each item, up to System.schedulers_online
      max_concurrent = Etc.nprocessors
      # ... implement with bounded parallelism
    end
  end
end
```

---

## Part 4: Challenges and Considerations

### 4.1 No Native Process Linking

Erlang's killer feature is `spawn_link` + `trap_exit`. Ruby Ractors don't have this.
We must build monitoring ourselves, which adds overhead.

**Mitigation**: Create a `MonitoredRactor` wrapper that handles this pattern.

### 4.2 No Pattern Matching in Receive

Elixir's `receive` can pattern match and leave non-matching messages in the mailbox.
Ruby's `Ractor.receive` takes the first message.

**Mitigation**: Use multiple `Ractor::Port`s for different message types, or
implement a message buffering layer.

### 4.3 Shareable Object Constraints

Ractor isolation is strict. Objects passed between Ractors must be:
- Immutable (frozen)
- Or explicitly moved (then unavailable to sender)

**Mitigation**: Design APIs around immutable data structures. Consider
using `Data.define` for value objects (Ruby 3.2+).

### 4.4 No Hot Code Reloading

OTP supports hot code reloading. Ruby doesn't have this capability.

**Mitigation**: Not addressed in initial design. Could explore with
`Ruby Box` isolation in future.

### 4.5 Error Handling Philosophy

OTP's "let it crash" philosophy requires supervisors that restart processes.
Without native linking, we need careful design.

**Mitigation**: Build robust supervisor with multiple monitoring strategies.

---

## Part 5: Implementation Roadmap

### Phase 1: Shellac (Current Focus)

Before building internal Ractor abstractions, we're starting with external process
management. **Shellac** wraps a long-lived OS process as a Ractor-citizen with
bidirectional messaging and death notification. This solves the "liveness detection"
problem in a concrete, testable context.

See: `phase-1-pilot-shellac.md` and `ROTP_FIRST_PRINCIPLES.md`

### Phase 2: Core Primitives
- [ ] `ROTP::GenServer` - Basic call/cast/info pattern
- [ ] `ROTP::Registry` - Simple name registration
- [ ] Apply Shellac patterns to Ractor supervision
- [ ] Basic tests demonstrating the pattern

### Phase 3: Supervision
- [ ] `ROTP::Supervisor` - one_for_one strategy
- [ ] Child specifications
- [ ] Restart counting and max_restarts

### Phase 4: Extended Patterns
- [ ] `ROTP::DynamicSupervisor` - Runtime child spawning
- [ ] `ROTP::Task` - Async/await pattern
- [ ] `ROTP::Application` - Lifecycle management

### Phase 5: Production Hardening
- [ ] Timeout handling throughout
- [ ] Backpressure mechanisms
- [ ] Telemetry/observability hooks
- [ ] Comprehensive error handling

---

## Part 6: Example Usage (Vision)

Following the OTP book's Mastery example, here's how ROTP would look:

```ruby
# lib/mastery/boundary/quiz_manager.rb
module Mastery
  module Boundary
    class QuizManager
      include ROTP::GenServer

      def init(_args)
        [:ok, {}]  # Initial state: empty quiz map
      end

      def handle_call([:build_quiz, fields], _from, quizzes)
        quiz = Core::Quiz.new(fields)
        [:reply, :ok, quizzes.merge(quiz.title => quiz)]
      end

      def handle_call([:lookup, title], _from, quizzes)
        [:reply, quizzes[title], quizzes]
      end

      def handle_cast([:add_template, title, fields], quizzes)
        updated = quizzes[title].add_template(fields)
        [:noreply, quizzes.merge(title => updated)]
      end

      # Client API
      def self.build_quiz(fields)
        ROTP::GenServer.call(whereis(:quiz_manager), [:build_quiz, fields])
      end

      def self.lookup(title)
        ROTP::GenServer.call(whereis(:quiz_manager), [:lookup, title])
      end

      private

      def self.whereis(name)
        ROTP::Registry.whereis(name)
      end
    end
  end
end

# lib/mastery/application.rb
module Mastery
  class Application
    def self.start
      children = [
        { id: :quiz_manager,
          start: -> { QuizManager.start_link(name: :quiz_manager) } }
      ]
      ROTP::Supervisor.start_link(children, strategy: :one_for_one)
    end
  end
end

# Usage
Mastery::Application.start
Mastery::Boundary::QuizManager.build_quiz(title: :math, mastery: 2)
quiz = Mastery::Boundary::QuizManager.lookup(:math)
```

---

## Conclusion

Ruby 4.0's Ractor::Port and improved Ractor stability make building OTP-like
patterns genuinely viable. The key insight from the OTP book applies directly:

> "Your project may never need to create its own processes... When your project
> does need processes, it will often use the OTP architecture."

The same layering applies to Ruby:
1. Build a **functional core** of pure Ruby logic
2. Wrap it in **boundary** Ractors using GenServer patterns
3. Manage **lifecycle** with Supervisors
4. Expose clean **APIs**

The main challenges are:
- No native process linking (must build monitoring)
- Strict shareability rules (embrace immutability)
- No hot code reloading (accept this limitation for now)

This is ambitious work, but Ruby 4.0 finally provides the primitives to make it real.

---

## Sources

- [Ruby 4.0.0 Released](https://www.ruby-lang.org/en/news/2025/12/25/ruby-4-0-0-released/)
- [Ruby 4.0 LWN.net coverage](https://lwn.net/Articles/1051953/)
- [Linuxiac Ruby 4.0 overview](https://linuxiac.com/ruby-4-0-released-with-ruby-box-isolation-and-new-zjit-compiler/)
- Programming Ruby 4th Edition (6th Edition of the book), Pragmatic Programmers 2025
- Designing Elixir Systems with OTP, Pragmatic Programmers 2019
