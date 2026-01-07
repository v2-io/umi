# PRE: Ruby 4.0 Primitives

The foundation. Every pattern in Umi builds on these Ruby 4.0 primitives. Future
agents: **do not hallucinate older APIs**—this is what actually exists.

---

## Ractor Status

From Ruby 4.0 NEWS:

> "A lot of work has gone into making Ractors more stable, performant, and
> usable. These improvements bring Ractor implementation closer to leaving
> experimental status."

Still experimental but approaching production-ready. Umi is built on this.

---

## OTP Concept → Ruby 4.0 Primitive Mapping

| OTP Concept | Ruby 4.0 Primitive | Notes |
|-------------|-------------------|-------|
| Process | `Ractor` | Share-nothing isolation unit |
| Process.monitor | `Ractor#monitor(port)` | Unidirectional death notification |
| Process.link | **None** | Must coordinate manually via monitors |
| Process dictionary | `Ractor[]`, `Ractor[]=` | Ractor-local key-value storage |
| gen_server receive | `Ractor.select(*ports)` | Wait on multiple ports |
| gen_server:call | Port + reply port pattern | See Communication Patterns |
| Registry | `Ractor.store_if_absent` + Hash | Thread-safe lazy init |
| Singleton | `RactorLocalSingleton` | Per-Ractor singleton instances |
| Message passing | `Ractor::Port` | Explicit send/receive channels |
| Supervisor | `monitor` + restart logic | No built-in, must implement |
| Exit signals | **None** | Must use messages via Port |
| Hot restart | **None** | Must create new Ractor, migrate state |

**Key limitations to remember:**
- No bidirectional linking (only unidirectional monitoring)
- Cannot send "exit signals" to a Ractor—use messages via Port
- Cannot restart a Ractor in place—must spawn new one
- Ractor references are not serializable—use Registry names

---

## Observation Primitives

### `Ractor#monitor(port)` and `Ractor#unmonitor(port)`

The foundation of supervision:

```ruby
r = Ractor.new { some_work }
monitor_port = Ractor::Port.new
r.monitor(monitor_port)

case monitor_port.receive
when :exited  # Normal termination
when :aborted # Crashed with unhandled exception
end
```

Properties:
- Multiple ports can monitor the same Ractor
- Monitoring is unidirectional (observer doesn't die when observed dies)
- Notifications are guaranteed if monitor was established before termination
- Use `unmonitor(port)` to stop receiving notifications

### `Ractor#join` and `Ractor#value`

New in Ruby 4.0, replacing `Ractor#take`:

```ruby
# Join: Wait for termination, propagate exceptions
r = Ractor.new { raise "failed" }
r.join  # raises "failed (RuntimeError)"

# Value: Wait and get return value (moved to caller)
r = Ractor.new { [1, 2, 3] }
r.value  # => [1, 2, 3]
```

These are implemented using `monitor` internally:

```ruby
def join
  port = Port.new
  self.monitor(port)
  if port.receive == :aborted
    __builtin_ractor_value  # raises the exception
  end
  self
ensure
  port.close
end
```

### `Ractor#alive?`

Check if a Ractor is still running:

```ruby
r = Ractor.new { sleep 10 }
r.alive?  # => true
```

---

## Communication Primitives

### `Ractor::Port`

The primary communication mechanism in Ruby 4.0:

```ruby
port = Ractor::Port.new

# Send (non-blocking, any Ractor can send)
port.send(message)
port << message  # alias

# Receive (blocking, only creator can receive)
msg = port.receive

# Close
port.close
port.closed?  # => true/false
```

**Key properties:**
- Only the Ractor that created a port can call `receive` on it
- Any Ractor with a reference can `send` to a port
- Ports are shareable (can be passed between Ractors)
- Sending to a closed port raises `Ractor::ClosedError`

### `Ractor#default_port`

Each Ractor has a built-in default port for convenience:

```ruby
r = Ractor.new { Ractor.receive }  # receives from default_port
r.send("hello")  # sends to r.default_port
r << "hello"     # same
```

### `Ractor.select(*ports_or_ractors)`

Wait on multiple sources:

```ruby
# Wait for first message from any port
ready_port, message = Ractor.select(port1, port2, port3)

# Wait for first Ractor to terminate (via its default port)
ready_ractor, value = Ractor.select(r1, r2, r3)

# Mixed ports and ractors
ready, obj = Ractor.select(port1, r1, port2)
```

**Critical limitation:** `Ractor.select` has no native timeout. Use timer port
pattern (see Timeout Patterns below).

---

## Timeout Patterns

### Timer Port Pattern

Since `Ractor.select` has no timeout, use a timer thread:

```ruby
def select_with_timeout(*ports, timeout:)
  timer_port = Ractor::Port.new
  timer_thread = Thread.new do
    sleep(timeout)
    timer_port << :timeout rescue nil
  end

  ready, value = Ractor.select(timer_port, *ports)

  if ready == timer_port
    timer_thread.kill
    nil  # or raise Timeout::Error
  else
    timer_thread.kill
    [ready, value]
  end
end
```

### Monotonic Clock for Deadlines

Use monotonic clock for reliable timeout tracking (immune to system time changes):

```ruby
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds

# Check remaining time
remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
if remaining <= 0
  # Timed out
end
```

---

## Ractor-Local Storage

### `Ractor[]` and `Ractor[]=`

Per-Ractor key-value storage:

```ruby
# Store value in current Ractor
Ractor.current[:my_key] = value
Ractor[:my_key]  # class method form (current Ractor)

# Each Ractor has isolated storage
r1 = Ractor.new { Ractor[:foo] = 1; Ractor[:foo] }
r2 = Ractor.new { Ractor[:foo] = 2; Ractor[:foo] }
r1.value  # => 1
r2.value  # => 2
```

Can store any value, including unshareable objects.

### `Ractor.store_if_absent(key) { block }`

Thread-safe lazy initialization of Ractor-local values:

```ruby
# Thread-safe even with multiple threads in the same Ractor
(1..10).map {
  Thread.new {
    Ractor.store_if_absent(:cache) { expensive_init; Hash.new }
    # Block called only once, all threads get same value
  }
}.map(&:value)
```

This solves double-checked locking for Ractor-local state. Use this for
Registry implementation.

### `RactorLocalSingleton` Module

Built-in Ractor-compatible Singleton (from `lib/singleton.rb`):

```ruby
require 'singleton'

class AppConfig
  include RactorLocalSingleton  # NOT regular Singleton!
  attr_accessor :debug
end

# Each Ractor gets its own instance
config = AppConfig.instance
```

Implementation uses `Ractor.current[key]` internally with proper locking.

---

## Shareability

### What Is Shareable?

Objects that can be passed between Ractors without copying:

```ruby
Ractor.shareable?(obj)  # => true/false
```

**Automatically shareable:**
- Frozen immutable objects (strings, arrays, hashes with frozen contents)
- `true`, `false`, `nil`
- Symbols
- Numeric types (Integer, Float, Rational, Complex)
- `Ractor::Port` instances
- Classes and Modules (with caveats)

**New in Ruby 4.0:**
- `Method` and `UnboundMethod` objects are now shareable

### `Ractor.make_shareable(obj, copy: false)`

Deep-freeze an object graph:

```ruby
data = { users: ["alice", "bob"], settings: { debug: true } }
Ractor.make_shareable(data)
data.frozen?            # => true
data[:users].frozen?    # => true
data[:users][0].frozen? # => true
```

With `copy: true`, creates a shareable copy without modifying original.

### `Ractor.shareable_proc` and `Ractor.shareable_lambda`

Create shareable Procs that don't capture outer variables:

```ruby
# Regular proc - NOT shareable if it captures outer vars
a = 42
proc = -> { a }  # captures a, not shareable

# Shareable proc - must not access outer variables
shareable = Ractor.shareable_proc { |x| x * 2 }
Ractor.shareable?(shareable)  # => true

# Can specify self:
obj = SomeShareableObject.new
shareable = Ractor.shareable_proc(self: obj) { do_something }
```

### Method and UnboundMethod Shareability (Ruby 4.0)

Methods can now be shared between Ractors:

```ruby
method = SomeClass.method(:some_method)
Ractor.shareable?(method)  # => true in Ruby 4.0

# Pass methods to Ractors
Ractor.new(method) do |m|
  m.call(args)
end
```

---

## Thread + Ractor Interaction

### GVL Architecture

Each Ractor has its own GVL (Global VM Lock):

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  Ractor 1   │  │  Ractor 2   │  │  Ractor 3   │
│  (GVL 1)    │  │  (GVL 2)    │  │  (GVL 3)    │
│  Thread A   │  │  Thread D   │  │  Thread G   │
│  Thread B   │  │  Thread E   │  │             │
│  Thread C   │  │             │  │             │
└─────────────┘  └─────────────┘  └─────────────┘
     ↓↑               ↓↑               ↓↑
  Threads share    Threads share    Threads share
  GVL within       GVL within       GVL within
  their Ractor     their Ractor     their Ractor

  ←────────── True parallelism across Ractors ──────────→
```

**Key points:**
- Threads within a Ractor share its GVL (can't run in parallel)
- Different Ractors run in true parallel (each has own GVL)
- Mutex, Queue, ConditionVariable all work inside Ractors
- Threads within a Ractor can share mutable state (with synchronization)

### `Thread::Queue` and `Thread::SizedQueue`

Built-in thread-safe queues (work inside Ractors):

```ruby
queue = Thread::Queue.new
queue << item           # non-blocking push
item = queue.pop        # blocking pop
item = queue.pop(true)  # non-blocking pop (raises if empty)

sized = Thread::SizedQueue.new(10)  # bounded queue
sized << item  # blocks if full (backpressure!)
```

Essential for connection pooling inside a Ractor.

### `Thread::Monitor` (Reentrant Mutex)

Not to be confused with `Ractor#monitor`. This is a reentrant mutex:

```ruby
require 'monitor'

class Counter
  include MonitorMixin

  def initialize
    super  # initialize MonitorMixin
    @count = 0
  end

  def increment
    synchronize do
      @count += 1
      # Can call other synchronized methods without deadlock
    end
  end
end
```

### Connection Pool Pattern (Inside Ractor)

```ruby
pool_ractor = Ractor.new do
  # Pool lives inside this Ractor
  available = Thread::Queue.new
  5.times { |i| available << Connection.new(i) }

  port = Ractor::Port.new
  Ractor.yield(port)  # Share port... wait, yield is gone

  # Better: use setup port pattern
  loop do
    case Ractor.receive
    in [:checkout, reply_port]
      conn = available.pop  # blocks if empty
      reply_port << [:ok, conn]
    in [:checkin, conn]
      available << conn
    in :shutdown
      break
    end
  end
end
```

### Cross-Ractor Pool Service Pattern

For multiple Ractors sharing a pool:

```ruby
setup_port = Ractor::Port.new

pool_ractor = Ractor.new(setup_port) do |setup|
  requests = Ractor::Port.new
  setup.send(requests)  # Share request port

  available = Thread::Queue.new
  5.times { |i| available << "Connection-#{i}" }

  loop do
    case requests.receive
    in [:checkout, reply_port]
      conn = available.pop
      reply_port.send([:ok, conn])
    in [:checkin, conn]
      available << conn
    in :shutdown
      break
    end
  end
end

pool_port = setup_port.receive

# Any Ractor can now use the pool:
worker = Ractor.new(pool_port) do |pool|
  reply = Ractor::Port.new
  pool.send([:checkout, reply])
  _, conn = reply.receive
  # Use connection...
  pool.send([:checkin, conn])
end
```

---

## Fiber + Ractor Interaction

### Fibers Are Ractor-Local

Fibers cannot cross Ractor boundaries, but work normally inside:

```ruby
result = Ractor.new do
  f = Fiber.new { "Hello from Fiber inside Ractor" }
  f.resume
end.value  # => "Hello from Fiber inside Ractor"
```

**What works inside Ractors:**
- `Fiber.new`, `resume`, `yield`
- `Fiber.transfer` (symmetric coroutines)
- `Fiber.current`
- `Fiber[:key]` storage (fiber-local variables)
- Enumerators (internally Fiber-based)
- Multiple fibers per Ractor
- Fibers in spawned Threads inside Ractors

### Architecture: Parallelism + Structured Concurrency

```
┌─────────────────────────────────────────────────────────────┐
│  Ractor 1          │  Ractor 2          │  Ractor 3        │
│  ┌──────────────┐  │  ┌──────────────┐  │  ┌────────────┐  │
│  │ Fiber A      │  │  │ Fiber D      │  │  │ Fiber G    │  │
│  │ Fiber B      │  │  │ Fiber E      │  │  │ Fiber H    │  │
│  │ Fiber C      │  │  │ Fiber F      │  │  │ Fiber I    │  │
│  └──────────────┘  │  └──────────────┘  │  └────────────┘  │
└─────────────────────────────────────────────────────────────┘
      Parallel execution across Ractors (bypass GVL)
      Cooperative concurrency within each Ractor (Fibers)
```

### Fiber Scheduler with Ractor.select

For async-style cross-Ractor communication using Fibers:

```ruby
class RactorFiberScheduler
  def initialize
    @waiting = {}  # port -> fiber
    @ready = []
    @results = {}
  end

  def spawn(&block)
    fiber = Fiber.new(&block)
    @ready << fiber
  end

  def await_port(port, timeout: nil)
    fiber = Fiber.current
    deadline = timeout ? Time.now + timeout : nil
    @waiting[port] = { fiber: fiber, deadline: deadline }
    Fiber.yield
    @results.delete(fiber)
  end

  def run
    loop do
      # Run ready fibers
      while (fiber = @ready.shift)
        fiber.resume if fiber.alive?
      end

      break if @waiting.empty?

      # Wait on all ports + timer
      ports = @waiting.keys
      timer = Ractor::Port.new
      Thread.new { sleep 0.01; timer << :tick rescue nil }

      ready_port, value = Ractor.select(timer, *ports)
      next if ready_port == timer

      # Wake fiber waiting on this port
      entry = @waiting.delete(ready_port)
      @results[entry[:fiber]] = value
      @ready << entry[:fiber]
    end
  end
end
```

**Use cases:**
- Proctor multiplexing (await stdout/stderr/exit from multiple processes)
- Supervisor health checks (fan-out to workers, collect responses)
- Request pipelines (chain fibers, each awaits previous stage)
- Timeout handling (deadline-based with timer ports)

---

## IO and Process Utilities

### IO Objects and Ractors

IO objects can be passed between Ractors:

```ruby
Ractor.shareable?(File.open("/tmp/test"))  # => false

# But CAN be copied/moved across Ractor boundaries
r = Ractor.new(File.open("/tmp/test", "w")) do |file|
  file.puts "Written from Ractor"
  file.close
end
```

**Important:** The IO object is copied. Both Ractors may have handles to the
same underlying file descriptor—requires coordination.

### `Process::Waiter` from `Process.detach`

Non-blocking process wait:

```ruby
pid = spawn("long-running-command")
waiter = Process.detach(pid)

waiter.class    # => Process::Waiter (Thread subclass)
waiter.alive?   # => true/false
status = waiter.value  # => Process::Status (blocks until done)
```

**Implications for Proctor:** Can detach processes and check status without
blocking.

### Fiber Scheduler Interface Hooks

Ruby 3.0+ provides hooks for cooperative concurrency:

```ruby
class MyScheduler
  # Wait for process termination (useful for Proctor!)
  def process_wait(pid, flags)
    # Non-blocking process wait implementation
  end

  # IO readiness
  def io_wait(io, events, timeout)
  end

  # Timeout support
  def timeout_after(duration, klass, *arguments, &block)
  end

  # Block/unblock fibers
  def block(blocker, timeout = nil)
  end

  def unblock(blocker, fiber)
  end

  # NEW in Ruby 4.0: Interrupt a blocked fiber
  def fiber_interrupt(fiber, exception)
  end
end
```

**New in Ruby 4.0:**
- `Fiber::Scheduler#fiber_interrupt` - interrupt blocked fibers with exceptions
- Better `IO#close` semantics with fibers

---

## Data Types for Messages

### `Data.define` - Immutable Value Objects

Ruby 3.2+ provides `Data.define` for creating immutable value types:

```ruby
Message = Data.define(:type, :payload, :timestamp)

msg = Message.new(:request, {id: 1}, Time.now)
msg.frozen?  # => true

# With frozen contents, Data objects are shareable!
Point = Data.define(:x, :y)
p = Point.new(1, 2)
Ractor.shareable?(p)  # => true
```

**Use for Umi message types:**
- Automatically frozen = safe for message passing
- Shareable when contents are shareable
- Pattern matching friendly

### Set Is Now Core (Ruby 4.0)

No require needed:

```ruby
set = Set[1, 2, 3]
@monitored_ractors = Set.new
@monitored_ractors.add(ractor)
```

---

## Weak References and Cleanup

### `ObjectSpace::WeakMap`

Hash-like structure that doesn't prevent GC:

```ruby
cache = ObjectSpace::WeakMap.new
cache[key] = expensive_object

# Object can be GC'd if no other references
cache[key]  # => expensive_object or raises KeyError
```

**Use cases:**
- Registry that doesn't prevent Ractor GC
- Caches that auto-evict on memory pressure

### `ObjectSpace.define_finalizer`

Run cleanup when object is GC'd:

```ruby
class Resource
  def initialize
    @handle = acquire_resource
    release = Release.new(@handle)
    ObjectSpace.define_finalizer(self, release)
  end

  class Release
    def initialize(handle)
      @handle = handle
    end

    def call(id)
      release_resource(@handle) rescue nil
    end
  end
end
```

**Caution:** Finalizers run in arbitrary context, should be simple.

---

## JIT Performance with Ractors

### YJIT vs ZJIT

Both work correctly with Ractors. Performance varies:

| Workload | No JIT | YJIT | ZJIT |
|----------|--------|------|------|
| Simple loops | ~13ms | ~12ms | ~13ms |
| OOP-heavy (method calls) | 178ms | **76ms** | 177ms |

**Recommendation:** Use `--yjit` for production until ZJIT matures:

```bash
ruby --yjit your_app.rb
```

ZJIT is new in Ruby 4.0. YJIT has been refined since Ruby 3.1 and excels at
typical Ruby OOP patterns.

### JIT Stats APIs

```ruby
# ZJIT
RubyVM::ZJIT.enabled?
RubyVM::ZJIT.stats  # => {compiled_iseq_count: N, ...}

# YJIT
RubyVM::YJIT.enabled?
RubyVM::YJIT.runtime_stats  # => {compiled_block_count: N, ...}
```

---

## Signal Handling

Signals become messages. Handler safety tested in spikes:

```ruby
Signal.trap("TERM") { @signal_port << [:shutdown, :sigterm] rescue nil }
Signal.trap("INT")  { @signal_port << [:shutdown, :sigint] rescue nil }
Signal.trap("HUP")  { @signal_port << [:reload_config] rescue nil }
Signal.trap("PIPE", "IGNORE")
```

**Key findings from spike testing:**
- `port <<` is signal-safe (tested under stress: 1000 concurrent sends)
- Signals may coalesce under rapid signaling (design for "at least one")
- Use `rescue nil` in handlers (ports may be closed during shutdown)
- `Thread::Queue#push` is documented signal-safe (alternative relay mechanism)

See [ini.md](./ini.md) for coordinator placement options (A/B/C pattern).

---

## Spike Findings Summary

All primitives documented here were validated in spikes:

| Spike | Validated |
|-------|-----------|
| `spike_f_box_ractor.rb` | Box + Ractor interaction, class variable workarounds |
| `spike_g_ractor_zjit.rb` | JIT + Ractor performance (YJIT vs ZJIT) |
| `spike_h_fiber_ractor.rb` | Fiber + Ractor interaction (13 tests) |
| `spike_i_fiber_ractor_scheduler.rb` | Custom Fiber scheduler with Ractor.select |
| `spike_j_signal_handler_reentrancy.rb` | Signal handler safety with Ractor::Port |
| `spike_k_signal_coordinator_options.rb` | Coordinator placement options |

---

## References

- `tmp/ruby/ractor.rb` - Ractor implementation
- `tmp/ruby/lib/singleton.rb` - RactorLocalSingleton
- `tmp/ruby/lib/timeout.rb` - Ractor-safe timeout pattern
- `tmp/ruby/doc/NEWS/NEWS-4.0.0.md` - Ruby 4.0 changes
- [ruby-4-otp-gems.md](../ruby-4-otp-gems.md) - Full primitive catalog
- [ini.md](./ini.md) - Coordinator (uses these primitives)
- [sup.md](./sup.md) - Supervision (builds on monitor primitive)
- [reg.md](./reg.md) - Registry (uses store_if_absent)
- [rac.md](./rac.md) - Workers (uses Port, select, timer patterns)
