# RAC: Workers and Proctors

Workers are isolation units that do actual work. Proctors wrap external
processes as Ractor-citizens.

---

## When to Use Workers

Not everything needs to be a process. From "Designing Elixir Systems with OTP":

> "Many projects will not need any layers beyond [data, functions, tests].
> Consider processes when these use cases show up."

**Use workers when you need:**

| Need | Why a Worker Helps |
|------|-------------------|
| **Shared state** | State lives in worker, accessed via messages |
| **External service API** | Uniform interface, isolation from failures |
| **Side effect management** | Contain impurity at the boundary |
| **System-wide monitoring** | Central point to observe/measure |
| **Failure isolation** | One user's crash doesn't affect others |

**Don't use workers when:**
- Pure computation suffices (just call a function)
- State is request-scoped (pass it as arguments)
- You're adding processes "for architecture" without a concrete need

---

## Core/Boundary Separation

The principled architecture separates pure logic from process machinery:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  DATA: Structs, types, the "nouns" of your domain                          │
├─────────────────────────────────────────────────────────────────────────────┤
│  FUNCTIONAL CORE: Pure functions that transform data                        │
│  No processes, no side effects, no I/O. Easy to test.                       │
├─────────────────────────────────────────────────────────────────────────────┤
│  BOUNDARY (Workers): Wraps core in processes for state and isolation       │
│  Handles uncertainty: user input, external systems, failures               │
├─────────────────────────────────────────────────────────────────────────────┤
│  LIFECYCLE (Supervisors): Starts, stops, restarts boundaries               │
└─────────────────────────────────────────────────────────────────────────────┘
```

**The principle**: The core should be testable without starting any processes.
Workers are "optional impure integration code" that make the core "fast, robust,
and reliable."

A well-designed worker is thin—it receives messages, calls pure core functions,
and sends responses. The interesting logic lives in the core, not in message
handling.

---

## The Worker Abstraction

A worker is an isolation unit that:
1. Maintains internal state across requests
2. Receives messages from clients
3. Processes requests
4. Sends responses back
5. Loops until told to stop

The key questions:
- How does the client indicate where to send the response?
- How does the worker dispatch different message types?
- How does backpressure work?
- How are timeouts handled?

---

## Ruby 4.0 Port Model

Ruby 4.0's Port model simplifies the traditional actor pattern:

| Erlang/Elixir | Ruby 4.0 Ports |
|---------------|----------------|
| Single mailbox + selective receive | Multiple ports for different concerns |
| Implicit `from` parameter | Explicit reply port in message |
| `call` vs `cast` built-in | Caller chooses to wait or not |
| Pattern matching for dispatch | Different ports = structural dispatch |

### Why This Matters

**Erlang needs `from`**: With one mailbox, messages from different senders are
interleaved. The server must know who sent what to route responses back. GenServer
handles this by passing a `from` parameter to every `handle_call`.

**Ruby doesn't need `from`**: The caller creates a reply port and includes it in
the message. The communication pattern is explicit in the message itself:

```ruby
# Erlang: server needs `from` to know where to reply
def handle_call(request, from, state)
  GenServer.reply(from, response)

# Ruby: reply destination is explicit in the message
def handle_message([:request, data, reply_port], state)
  reply_port << response  # obvious where this goes
```

### The Four Simplifications

1. **Message routing is structural, not pattern-based** — Different ports for
   different message types, rather than pattern matching on message shapes

2. **Reply-to is explicit, not implicit** — The caller provides the reply port,
   making the communication pattern visible in the message

3. **Backpressure is a client choice, not a protocol choice** — Same server can
   serve clients that wait (sync) and clients that don't (async), without
   different message types (see Backpressure section below)

4. **Timeouts are composable** — Using `Ractor.select` with a timer port,
   timeouts become a pattern you compose, not a feature you configure

**Example:**

```ruby
class MyWorker
  def initialize
    @command_port = Ractor::Port.new  # For requests
    @timer_port = Ractor::Port.new    # For timeouts
    @state = {}
  end

  def run
    loop do
      case Ractor.select(@command_port, @timer_port)
      in [@command_port, [:get, key, reply_port]]
        reply_port << [:ok, @state[key]]
      in [@command_port, [:set, key, value, reply_port]]
        @state[key] = value
        reply_port << :ok
      in [@timer_port, :timeout]
        handle_timeout
      end
    end
  end
end
```

---

## Worker Patterns

### Task: One-Shot Concurrent Work

```ruby
# Fire, do other work, collect result
task_port = Ractor::Port.new
Ractor.new(task_port) do |port|
  result = expensive_computation()
  port << [:ok, result]
rescue => e
  port << [:error, e.message]
end

# Meanwhile...
other_work()

# Collect
case task_port.receive
in [:ok, result] then use(result)
in [:error, msg] then handle_error(msg)
end
```

**Bounded parallel processing:**

```ruby
def parallel_map(items, max: Etc.nprocessors)
  items.each_slice(max).flat_map do |batch|
    ports = batch.map do |item|
      port = Ractor::Port.new
      Ractor.new(port, item) { |p, i| p << yield(i) }
      port
    end
    ports.map(&:receive)
  end
end
```

### Pool: Bounded Concurrency for Expensive Resources

```ruby
class Umi::Pool
  def initialize(size:, overflow: 0, &factory)
    # Pool manager Ractor tracks available workers
    # Checkout blocks if none available (backpressure)
  end

  def transaction(timeout: 5.0)
    worker = checkout(timeout)
    yield(worker)
  ensure
    checkin(worker)
  end
end

# Usage
pool = Umi::Pool.new(size: 5) { DatabaseConnection.new }
pool.transaction { |conn| conn.query("SELECT ...") }
```

### DynamicSupervisor: On-Demand Processes

For per-user, per-session, per-connection workers. This is a supervision
pattern—see [sup.md](./sup.md) for details on DynamicSupervisor. See
[reg.md](./reg.md) for the Registry + DynamicSupervisor pattern for finding
dynamic processes by name.

---

## Proctor: External Process Wrapper

Proctor wraps external OS processes as Ractor-citizens. It already exists and
is well-tested.

**Key properties:**
- External process spawned inside a Watcher Ractor
- I/O handled via threads inside the Watcher
- Death notification via `Ractor#monitor`
- Tagged tuples for all operations

```ruby
Umi::Proctor.open("my-server") do |server|
  server << "REQUEST\n"
  case server.pop_stdout(timeout: 30)
  in [:ok, response] then parse(response)
  in nil then raise "timeout"
  in [:closed, result] then handle_exit(result)
  end
end
```

**Supervision question**: Proctor has internal death detection. How does this
compose with supervisor monitoring? Options:

1. Supervisor monitors the Proctor Ractor (not the OS process)
2. Proctor notifies supervisor when OS process dies
3. Both—defense in depth

---

## Timer Patterns

**One-shot timer:**

```ruby
def schedule_after(seconds, port, message)
  Thread.new do
    sleep(seconds)
    port << message rescue nil
  end
end

# Usage
schedule_after(60, @timer_port, [:quiz_end, quiz_id])
```

**Periodic timer:**

```ruby
def start_interval(seconds, port, message)
  Thread.new do
    loop do
      sleep(seconds)
      port << message rescue break
    end
  end
end

# Usage
start_interval(5, @health_port, :check)
```

The Port advantage: timers arrive on dedicated ports, no need to distinguish
from other messages via pattern matching.

### Idle Timeout Pattern

From "Designing Elixir Systems with OTP":

> "GenServer timeouts are one of the most underused features in OTP. Loosely
> stated, a timeout says 'If nothing is happening in x milliseconds, I'll make
> it happen.'"

This is different from "do X after Y seconds"—it's "if idle for Y seconds, do X":

```ruby
def run
  idle_timeout = 30  # seconds

  loop do
    # Reset timer on each iteration
    timer = schedule_after(idle_timeout, @timer_port, :idle_timeout)

    case Ractor.select(@command_port, @timer_port)
    in [@command_port, msg]
      timer.kill  # Cancel the idle timer—we got work
      handle(msg)
    in [@timer_port, :idle_timeout]
      # Nothing happened for 30 seconds
      perform_idle_maintenance
    end
  end
end
```

Use cases:
- Flush buffers if no new data arrives
- Close idle connections
- Checkpoint state after activity settles
- Trigger GC or cleanup during quiet periods

---

## Backpressure: Prefer Waiting

From "Designing Elixir Systems with OTP":

> "Intuitively, you might think that it's best to use fire-and-forget to send
> messages that don't need responses... Interestingly, fire-and-forget is rarely
> the best option."

**The problem**: If clients send faster than the server processes, the message
queue grows unboundedly, eventually exhausting memory.

**The solution**: Wait for responses. This creates natural backpressure—clients
can only send as fast as the server can handle.

### The Logger Pattern

Elixir's Logger demonstrates adaptive backpressure with three modes:

```
messages >= discard_threshold → :discard (drop messages)
messages >= sync_threshold   → :sync    (wait for response)
otherwise                    → :async   (fire-and-forget)
```

This lets high-throughput logging stay fast under normal load, but automatically
slows down (or sheds load) when overwhelmed.

### In Ruby 4.0 Ports

The same server can serve both patterns—client decides:

```ruby
# With backpressure: wait for response
reply_port = Ractor::Port.new
server_port << [:request, data, reply_port]
response = reply_port.receive  # blocks until server responds

# Without backpressure: fire-and-forget
server_port << [:notify, data, nil]
# continue immediately (server may queue up)
```

**The principle**: Default to waiting. Only use fire-and-forget when:
- You're broadcasting notifications
- You're starting work you'll check on later
- You have explicit load-shedding (like Logger's discard mode)

---

## API Layer: Hide the Protocol

Even with Ports simplifying the wire format, wrap raw message passing in a
clean API:

```ruby
class QuizManager
  def initialize(command_port)
    @command_port = command_port
  end

  # Clean API - callers don't know the message format
  def build_quiz(fields, timeout: 5.0)
    call([:build_quiz, fields], timeout: timeout)
  end

  def lookup(title, timeout: 5.0)
    call([:lookup, title], timeout: timeout)
  end

  private

  # Internal protocol hidden here
  def call(request, timeout:)
    reply_port = Ractor::Port.new
    @command_port << [request, reply_port]
    # ... timeout handling ...
    reply_port.receive
  end
end
```

**Why this matters**: Without an API layer, "we leak through the exact format of
each call message, unnecessarily coupling our worker to any code that invokes it."

The API layer:
- Hides message format (can change without breaking callers)
- Provides natural place for timeout defaults
- Documents the operations (method signatures > message patterns)
- Enables validation before sending

---

## Request/Response with Timeout

The standard pattern for synchronous calls:

```ruby
def call(worker_port, request, timeout: 5.0)
  reply_port = Ractor::Port.new
  timer_port = Ractor::Port.new

  # Start timeout
  Thread.new { sleep(timeout); timer_port << :timeout rescue nil }

  # Send request
  worker_port << [request, reply_port]

  # Wait for reply or timeout
  case Ractor.select(reply_port, timer_port)
  in [^reply_port, response] then response
  in [^timer_port, :timeout] then raise Timeout::Error
  end
end
```

---

## Worker Lifecycle

A supervised worker follows this pattern:

```ruby
class MyWorker
  def self.start_link(args)
    Ractor.new(args) do |config|
      worker = new(config)
      worker.init
      worker.run
    rescue => e
      # Crash will be detected by supervisor
      raise
    end
  end

  def init
    # Setup, possibly register with Registry
    Registry.register(@name, Ractor.current) if @name
  end

  def run
    loop do
      case receive_with_timeout
      in [:shutdown, timeout]
        graceful_stop(timeout)
        break
      in message
        handle(message)
      end
    end
  end

  def graceful_stop(timeout)
    # Drain queues, release resources
  end
end
```

---

## State Checkpointing

Basic supervision restarts workers fresh—in-flight state is lost. For many use
cases this is fine. But when you need retry capability, idempotency, or crash
debugging, strategic checkpointing helps.

The key insight: checkpoint around **risky operations** (external calls,
subprocess I/O), not continuously. Two snapshot types serve different purposes:
- **Recovery snapshots**: Last known good state, safe to restore from
- **Diagnostic snapshots**: Failure state, useful for debugging

See [etc.md](./etc.md) for the full pattern including implementation sketches.

---

## Open Questions

1. **Worker DSL**: Should there be a declarative way to define workers? The Port
   model may be simple enough that a DSL adds more complexity than it removes.

2. **Linking vs monitoring**: When should workers link (mutual death) vs
   monitor (one-way notification)? General guidance: supervisors monitor,
   collaborating workers may link.

3. **Adaptive backpressure**: Should Umi provide a Logger-style pattern that
   automatically switches between async/sync/discard based on queue depth?
   (See [etc.md](./etc.md) for context.)

---

## References

- [sup.md](./sup.md) - Supervision (manages workers, DynamicSupervisor)
- [reg.md](./reg.md) - Registry (finds workers, Registry + DynamicSupervisor pattern)
- [etc.md](./etc.md) - Future enhancements (checkpointing, adaptive backpressure)
- Proctor source: `lib/umi/proctor.rb`
- *Designing Elixir Systems with OTP* by Tate & Gray - Source for Core/Boundary
  separation, backpressure, idle-timeout, and API layer principles
