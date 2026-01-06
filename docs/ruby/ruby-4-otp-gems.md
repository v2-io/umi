# Ruby 4.0 Features Relevant to OTP Patterns

This document catalogs Ruby 4.0 features, patterns, and implementation details
discovered in the Ruby source (`tmp/ruby/`) that are relevant to building
OTP-like resilience patterns in Umi.

---

## Table of Contents

1. [Supervision Primitives](#supervision-primitives)
2. [Ractor-Local State Patterns](#ractor-local-state-patterns)
3. [Communication Primitives](#communication-primitives)
4. [Shareability Enhancements](#shareability-enhancements)
5. [Standard Library Patterns](#standard-library-patterns)
6. [Git History Insights](#git-history-insights)
7. [Implications for Umi](#implications-for-umi)
8. [Thread + Ractor Interaction](#thread--ractor-interaction)
9. [Fiber + Ractor Patterns](#fiber--ractor-patterns)
10. [JIT + Ractor Performance](#jit--ractor-performance)
11. [Non-Ractor Features](#non-ractor-features-relevant-to-otp-patterns)

---

## Supervision Primitives

### `Ractor#monitor(port)` and `Ractor#unmonitor(port)`

**This is the key primitive for supervision.** From `ractor.rb`:

```ruby
#  call-seq:
#    ractor.monitor(port) -> self
#
# Registers the port as a monitoring port for this ractor. When the ractor
# terminates, the port receives a Symbol object.
#
# * +:exited+ is sent if the ractor terminates without an unhandled exception.
# * +:aborted+ is sent if the ractor terminates by an unhandled exception.
#
#     r = Ractor.new{ some_task() }
#     r.monitor(port = Ractor::Port.new)
#     port.receive #=> :exited and r is terminated
#
#     r = Ractor.new{ raise "foo" }
#     r.monitor(port = Ractor::Port.new)
#     port.receive #=> :aborted and r is terminated by the RuntimeError "foo"
```

This mirrors BEAM's `Process.monitor/1`:
- Register to be notified when a Ractor terminates
- Receive `:exited` (normal) or `:aborted` (crashed)
- Multiple ports can monitor the same Ractor
- Can unmonitor to stop receiving notifications

**Usage pattern for supervision:**

```ruby
class Supervisor
  def initialize
    @children = {}
    @monitor_port = Ractor::Port.new
  end

  def start_child(id, &block)
    child = Ractor.new(&block)
    child.monitor(@monitor_port)
    @children[child] = id
    child
  end

  def supervision_loop
    loop do
      case @monitor_port.receive
      when :exited
        # Child exited normally - may or may not restart
      when :aborted
        # Child crashed - restart based on strategy
      end
    end
  end
end
```

### `Ractor#join` and `Ractor#value`

New in Ruby 4.0 (replacing `Ractor#take`):

```ruby
# Join: Wait for termination, propagate exceptions
r = Ractor.new{ raise "foo" }
r.join  # raises "foo (RuntimeError)"

# Value: Wait and get return value (moved to caller)
r = Ractor.new{ [1, 2, 3] }
r.value  # => [1, 2, 3]
```

These are implemented using `monitor` internally:

```ruby
def join
  port = Port.new
  self.monitor port
  if port.receive == :aborted
    __builtin_ractor_value  # raises the exception
  end
  self
ensure
  port.close
end
```

---

## Ractor-Local State Patterns

### `Ractor.store_if_absent(key) { block }`

Thread-safe lazy initialization of ractor-local values:

```ruby
# Thread-safe even with multiple threads in the same Ractor
(1..10).map {
  Thread.new(it) { |i|
    Ractor.store_if_absent(:cache) { expensive_init(); Hash.new }
    #=> returns the stored value, init block called only once
  }
}.map(&:value)
```

This solves the "double-checked locking" problem for Ractor-local state.

### `Ractor[]` and `Ractor[]=` (Ractor-Local Storage)

Per-Ractor key-value storage:

```ruby
Ractor.current[:my_key] = value
Ractor[:my_key]  # class method form (current ractor)
```

Each Ractor has its own isolated storage. Can store any value, including
unshareable objects.

### `RactorLocalSingleton` Module

Built-in Ractor-compatible Singleton (from `lib/singleton.rb`):

```ruby
require 'singleton'

class AppConfig
  include RactorLocalSingleton  # NOT Singleton!
  attr_accessor :debug
end

# Each Ractor gets its own instance
config = AppConfig.instance
```

Implementation uses `Ractor.current[key]` internally:

```ruby
module RactorLocalSingletonClassMethods
  def instance
    set_mutex(Thread::Mutex.new) if Ractor.current[mutex_key].nil?
    return Ractor.current[instance_key] if Ractor.current[instance_key]
    Ractor.current[mutex_key].synchronize {
      return Ractor.current[instance_key] if Ractor.current[instance_key]
      set_instance(new())
    }
    Ractor.current[instance_key]
  end

  private

  def set_instance(val)
    Ractor.current[instance_key] = val  # Ractor-local, not class ivar!
  end
end
```

---

## Communication Primitives

### `Ractor::Port` (New in Ruby 4.0)

Replaces `Ractor.yield`/`Ractor#take` with explicit ports:

```ruby
port = Ractor::Port.new

# Send (non-blocking)
port.send(message)
port << message

# Receive (blocking)
msg = port.receive

# Close
port.close
port.closed?
```

Key properties:
- Only the Ractor that created a port can receive from it
- Any Ractor can send to a port (if it has the reference)
- Ports are shareable (can be passed between Ractors)
- Sending to a closed port raises `Ractor::ClosedError`

### `Ractor.select(*ports_or_ractors)`

Wait on multiple ports/ractors:

```ruby
# Wait for first message from any port
port, message = Ractor.select(port1, port2, port3)

# Wait for first Ractor to terminate
ractor, value = Ractor.select(r1, r2, r3)

# Mixed
result, obj = Ractor.select(port1, r1, port2)
```

This is the primitive for implementing `gen_server`-like select loops.

### `Ractor#default_port`

Each Ractor has a default port for convenience:

```ruby
r = Ractor.new { Ractor.receive }  # receives from default_port
r.send("hello")  # sends to r.default_port
r << "hello"     # same
```

---

## Shareability Enhancements

### `Ractor.shareable_proc` and `Ractor.shareable_lambda`

Create shareable Procs without outer variable access:

```ruby
# Regular proc - not shareable if it accesses outer vars
a = 42
proc = -> { a }  # captures a, not shareable

# Shareable proc - must not access outer variables
shareable = Ractor.shareable_proc { |x| x * 2 }
Ractor.shareable?(shareable)  # => true

# Can specify self:
obj = SomeShareableObject.new
shareable = Ractor.shareable_proc(self: obj) { do_something }
```

### Method and UnboundMethod are Now Shareable (Ruby 4.0)

From git history: `f2cd772329 Method and UnboundMethod can be sharable`

```ruby
method = SomeClass.method(:some_method)
Ractor.shareable?(method)  # => true in Ruby 4.0

# Can pass methods to Ractors
Ractor.new(method) do |m|
  m.call(args)
end
```

### `Ractor.make_shareable(obj, copy: false)`

Deep-freeze an object graph to make it shareable:

```ruby
data = { users: ["alice", "bob"], settings: { debug: true } }
Ractor.make_shareable(data)
data.frozen?           # => true
data[:users].frozen?   # => true
data[:users][0].frozen? # => true
```

With `copy: true`, creates a shareable copy without modifying original.

---

## Standard Library Patterns

### Timeout Library Pattern

Shows how to use `Ractor.store_if_absent` for Ractor-safe singleton state:

```ruby
# From lib/timeout.rb
class State
  if defined?(Ractor.store_if_absent) && Ractor.shareable?(GET_TIME)
    def self.instance
      Ractor.store_if_absent :timeout_gem_state do
        State.new
      end
    end
  else
    GLOBAL_STATE = State.new
    def self.instance
      GLOBAL_STATE
    end
  end
end
```

This pattern provides:
- Thread-safe initialization
- Ractor-safe (each Ractor gets its own state)
- Fallback for older Ruby versions

### ObjectSpace::WeakMap

Useful for registries that shouldn't prevent GC:

```ruby
@@__map = ::ObjectSpace::WeakMap.new
@@__map[key] = value

# Value can be garbage collected if no other references exist
# Useful for caches, registries, etc.
```

### Thread::Monitor (Reentrant Mutex)

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

---

## Git History Insights

### Active Development Areas (2024-2025)

From git log analysis:

1. **Ractor Stability** - Many fixes for deadlocks, race conditions, GC issues
2. **Ractor::Port** - New primary communication mechanism
3. **Performance** - Lock-free hash sets, reduced locking in method cache
4. **Method shareability** - Methods can now be shared between Ractors
5. **Documentation** - Significant doc improvements for Ractor

### Key Commits

```
f2cd772329 Method and UnboundMethod can be sharable
ef2bb61018 `Ractor::Port`
4fb537b1ee Make tracepoints ractor local
bdca2a9975 [ruby/json] Ractor-shareable JSON::Coder
ec28bd75a8 [ruby/timeout] support Ractor
```

### Ractor Status

From NEWS-4.0.0.md:
> A lot of work has gone into making Ractors more stable, performant, and
> usable. These improvements bring Ractor implementation closer to leaving
> experimental status.

Still experimental but approaching production-ready.

---

## Implications for Umi

### Supervision Implementation

With `Ractor#monitor`, we can implement OTP-style supervision:

```ruby
module Umi
  class Supervisor
    def initialize(strategy: :one_for_one)
      @strategy = strategy
      @children = {}
      @monitor_port = Ractor::Port.new
    end

    def start_child(child_spec)
      ractor = spawn_child(child_spec)
      ractor.monitor(@monitor_port)
      @children[ractor] = child_spec
      ractor
    end

    def run
      loop do
        # Use Ractor.select to wait on monitor port AND any other work
        port, event = Ractor.select(@monitor_port, *other_ports)

        case port
        when @monitor_port
          handle_child_exit(event)
        else
          handle_message(port, event)
        end
      end
    end

    private

    def handle_child_exit(event)
      # Find which child exited
      dead_child = @children.keys.find { |r| !r.alive? }
      child_spec = @children.delete(dead_child)

      case event
      when :exited
        maybe_restart(child_spec, :normal)
      when :aborted
        maybe_restart(child_spec, :abnormal)
      end
    end
  end
end
```

### Registry Using Ractor-Local Storage

```ruby
module Umi
  class Registry
    STORAGE_KEY = :umi_registry

    def self.register(name, ractor)
      storage[name] = ractor
    end

    def self.lookup(name)
      storage[name]
    end

    def self.unregister(name)
      storage.delete(name)
    end

    private

    def self.storage
      Ractor.store_if_absent(STORAGE_KEY) { {} }
    end
  end
end
```

### Recommended Patterns

| OTP Concept | Ruby 4.0 Primitive |
|-------------|-------------------|
| Process.monitor | `Ractor#monitor(port)` |
| Process.link | Manual via monitor + coordination |
| gen_server receive loop | `Ractor.select` on ports |
| Registry | `Ractor.store_if_absent` + Hash |
| Singleton state | `RactorLocalSingleton` |
| Message passing | `Ractor::Port` |
| Supervisor | `monitor` + restart logic |

### Open Questions

1. **No linking primitive** - Ruby has monitor but not bidirectional linking.
   Supervision must be explicit, not automatic.

2. **No exit signals** - Can't send `:shutdown` to a Ractor like BEAM can.
   Must use messages via Port instead.

3. **No process dictionary** - `Ractor.current[]` is close but not quite the
   same semantics.

4. **Restart semantics** - Can't restart a Ractor in place. Must create new
   Ractor and migrate state.

---

## Thread + Ractor Interaction

### Threads Work Inside Ractors

Threads can be created and used normally inside Ractors:

```ruby
r = Ractor.new do
  results = []
  mutex = Mutex.new

  threads = 10.times.map do |i|
    Thread.new(i) do |n|
      mutex.synchronize { results << n * 10 }
    end
  end

  threads.each(&:join)
  results
end

r.value  # => [0, 10, 20, ..., 90]
```

**Key points:**
- Each Ractor has its own GVL (threads within a Ractor share it)
- Mutex, Queue, ConditionVariable all work inside Ractors
- Threads within a Ractor can share mutable state (with synchronization)
- Different Ractors run in true parallel (each has own GVL)

### Connection Pool Pattern

Connection pools can live inside a Ractor using threads:

```ruby
r = Ractor.new do
  class ConnectionPool
    def initialize(size)
      @available = Thread::Queue.new
      size.times { |i| @available << Connection.new(i) }
    end

    def with_connection
      conn = @available.pop  # blocks if empty
      begin
        yield conn
      ensure
        @available << conn
      end
    end
  end

  pool = ConnectionPool.new(5)

  threads = 20.times.map do |i|
    Thread.new do
      pool.with_connection { |c| c.query("SELECT #{i}") }
    end
  end

  threads.map(&:value)
end
```

### Cross-Ractor Pool Service Pattern

For multiple Ractors sharing a pool, use a Pool Ractor with message passing:

```ruby
setup_port = Ractor::Port.new

pool_ractor = Ractor.new(setup_port) do |setup|
  # Create port THIS ractor owns (can receive on)
  requests = Ractor::Port.new
  setup.send(requests)  # Share with other Ractors

  # Connection pool using Thread::Queue
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

# Get the pool's request port
pool_port = setup_port.receive

# Any Ractor can now use the pool
worker = Ractor.new(pool_port) do |pool|
  reply = Ractor::Port.new
  pool.send([:checkout, reply])
  _, conn = reply.receive

  # Use connection...

  pool.send([:checkin, conn])
end
```

### IO Objects and Ractors

IO objects (files, sockets) can be passed between Ractors:

```ruby
# IO is NOT shareable...
Ractor.shareable?(File.open("/tmp/test"))  # => false

# ...but CAN be copied/moved across Ractor boundaries
r = Ractor.new(File.open("/tmp/test", "w")) do |file|
  file.puts "Written from Ractor"
  file.close
  "done"
end
```

**Important:** The IO object is copied. Both Ractors may have handles to the
same underlying file descriptor, which requires coordination.

### Sequel/ActiveRecord Compatibility

For libraries like Sequel:

1. **Single-Ractor pattern**: Run all database work in one Ractor
   - Pool lives in that Ractor
   - Other Ractors send query requests via Port
   - Pool Ractor returns results

2. **Per-Ractor pools**: Each Ractor creates its own pool
   - More parallelism but more connections
   - No cross-Ractor coordination needed

3. **Connection-per-Ractor**: Simplest model
   - Each Ractor gets one dedicated connection
   - No pooling complexity

```ruby
# Pattern 2: Per-Ractor pool
db_worker = Ractor.new do
  require 'sequel'
  DB = Sequel.connect('postgres://...')

  # This Ractor owns the DB connection pool
  # Use Thread::Queue internally for connection management

  port = Ractor::Port.new
  Ractor.yield(port)  # Share port... wait, yield removed

  # Better: receive queries on default port
  loop do
    case Ractor.receive
    in [:query, sql, reply_port]
      result = DB[sql].all
      reply_port.send(result)
    in :shutdown
      DB.disconnect
      break
    end
  end
end
```

---

## Fiber + Ractor Patterns

Fibers provide cooperative concurrency (coroutines) within a single thread.
Combined with Ractors, they enable async-style programming within each Ractor
while Ractors provide true parallelism across CPU cores.

*Validated in `spikes/spike_h_fiber_ractor.rb` and `spikes/spike_i_fiber_ractor_scheduler.rb`*

### Fibers Are Ractor-Local

Fibers cannot be passed between Ractors, but each Ractor can create its own:

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

### Fiber Scheduler with Ractor Communication

`Ractor.select` has no built-in timeout, so we use a **timer port pattern**:

```ruby
timer_port = Ractor::Port.new
Thread.new { sleep 0.1; timer_port << :tick }

ready_port, value = Ractor.select(timer_port, *data_ports)
```

This enables building a scheduler where fibers await Ractor messages:

```ruby
class RactorFiberScheduler
  def initialize
    @waiting = {}  # port -> fiber
    @ready = []
    @results = {}
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

      # Check timeouts, move expired to ready queue
      check_timeouts

      # Wait on all ports + timer
      ports = @waiting.keys
      timer = Ractor::Port.new
      Thread.new { sleep 0.01; timer << :tick }

      ready_port, value = Ractor.select(timer, *ports)
      next if ready_port == timer

      # Wake fiber waiting on this port
      fiber = @waiting.delete(ready_port)[:fiber]
      @results[fiber] = value
      @ready << fiber
    end
  end
end
```

### Pattern: Async-Style Cross-Ractor Communication

Fibers can await responses from worker Ractors without blocking:

```ruby
coordinator = Ractor.new(workers) do |workers|
  scheduler = RactorFiberScheduler.new
  results = []

  # Spawn fibers for parallel requests
  6.times do |i|
    scheduler.spawn do
      reply_port = Ractor::Port.new
      workers[i % 3].send({ data: i, reply_to: reply_port })
      response = scheduler.await_port(reply_port, timeout: 1.0)
      results << response
    end
  end

  scheduler.run
  results
end
```

### Implications for Umi

| Use Case | Pattern |
|----------|---------|
| Proctor multiplexing | Await stdout/stderr/exit from multiple processes |
| Supervisor health checks | Fan-out to workers, collect responses |
| Request pipelines | Chain fibers, each awaits previous stage |
| Timeout handling | Deadline-based with timer ports |

**Key insight:** Fiber::Scheduler is I/O-focused. For Ractor communication,
build a parallel scheduler using `Ractor.select` + timer ports.

---

## JIT + Ractor Performance

*Validated in `spikes/spike_g_ractor_zjit.rb`*

### YJIT vs ZJIT with Ractors

Both YJIT and ZJIT work correctly with Ractors. Performance varies by workload:

| Workload | No JIT | YJIT | ZJIT |
|----------|--------|------|------|
| Simple loops | ~13ms | ~12ms | ~13ms |
| OOP-heavy (N-body sim) | 178ms | **76ms** | 177ms |

**Key findings:**
- YJIT provides ~2.3x speedup on method-call-heavy OOP code
- ZJIT compiles code but doesn't optimize as aggressively (yet)
- Simple arithmetic loops show little JIT benefit
- Parallel Ractors achieve real parallelism regardless of JIT mode

### Recommendation for CPU-Bound Work

Use `--yjit` for production workloads until ZJIT matures:

```bash
ruby --yjit your_app.rb
```

ZJIT is new in Ruby 4.0 and still developing optimizations. YJIT has been
refined since Ruby 3.1 and excels at typical Ruby OOP patterns.

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

## Non-Ractor Features Relevant to OTP Patterns

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

**Implications for Umi:**
- Use `Data.define` for message types
- Automatically frozen = safe for message passing
- Shareable when contents are shareable
- Pattern matching friendly

### Fiber Scheduler Interface

Ruby 3.0+ provides hooks for cooperative concurrency:

```ruby
class MyScheduler
  # Wait for process termination (useful for Proctor!)
  def process_wait(pid, flags)
    # Non-blocking process wait
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

  # NEW in 4.0: Interrupt a blocked fiber
  def fiber_interrupt(fiber, exception)
  end
end
```

**New in Ruby 4.0:**
- `Fiber::Scheduler#fiber_interrupt` - interrupt blocked fibers with exceptions
- `Fiber::Scheduler#yield` - yield when signals are disabled
- Better `IO#close` semantics with fibers

**Implications for Umi:**
- Could implement scheduler for Proctor's IO handling
- `process_wait` hook for non-blocking process supervision
- `fiber_interrupt` for cancellation patterns

### Process::Waiter (from Process.detach)

`Process.detach` returns a `Process::Waiter` thread:

```ruby
pid = spawn("long-running-command")
waiter = Process.detach(pid)

# Waiter is a Thread subclass
waiter.class  # => Process::Waiter

# Can join to get exit status
status = waiter.value  # => Process::Status

# Can check if still running
waiter.alive?  # => true/false
```

**Implications for Umi:**
- Proctor could use detached processes
- Waiter thread provides non-blocking wait
- Can integrate with `Ractor.select` if combined with ports

### Process.clock_gettime

High-resolution monotonic clock for timeouts:

```ruby
# Monotonic clock - immune to system time changes
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
# ... work ...
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
```

Used by timeout library for reliable timeout tracking.

### Set is Now a Core Class (Ruby 4.0)

```ruby
# No require needed in Ruby 4.0
set = Set[1, 2, 3]

# Useful for tracking registrations, dependencies, etc.
@monitored_ractors = Set.new
@monitored_ractors.add(ractor)
```

### ObjectSpace::WeakMap

Hash-like structure that doesn't prevent GC:

```ruby
cache = ObjectSpace::WeakMap.new
cache[key] = expensive_object

# Object can be GC'd if no other references
cache[key]  # => expensive_object or raises
```

**Implications for Umi:**
- Registry that doesn't prevent Ractor GC
- Caches that auto-evict on memory pressure

### Thread::Queue and Thread::SizedQueue

Built-in thread-safe queues:

```ruby
queue = Thread::Queue.new
queue << item           # non-blocking push
item = queue.pop        # blocking pop
item = queue.pop(true)  # non-blocking pop (raises if empty)

sized = Thread::SizedQueue.new(10)  # bounded queue
sized << item  # blocks if full
```

**Fiber-compatible** - works with Fiber scheduler for non-blocking behavior.

### Signal Handling

```ruby
# Trap signals
Signal.trap("TERM") { shutdown_gracefully }
Signal.trap("INT") { shutdown_gracefully }
Signal.trap("HUP") { reload_config }

# List available signals
Signal.list  # => {"EXIT"=>0, "HUP"=>1, "INT"=>2, ...}

# Signal.trap returns previous handler
old_handler = Signal.trap("TERM", "DEFAULT")
```

**Implications for Umi:**
- Coordinator should trap signals
- Convert to messages for clean handling
- Bundler's pattern: trap, do work, restore handler

### ObjectSpace.define_finalizer

Run cleanup when object is GC'd:

```ruby
class Resource
  def initialize
    @ref = File.open(...)
    release = Release.new(@ref)
    ObjectSpace.define_finalizer(self, release)
  end

  class Release
    def initialize(ref)
      @ref = ref
    end

    def call(id)
      @ref.close rescue nil
    end
  end
end
```

**Caution:** Finalizers run in arbitrary context, should be simple.

---

## References

### Ruby Source
- `tmp/ruby/ractor.rb` - Ractor implementation
- `tmp/ruby/lib/singleton.rb` - RactorLocalSingleton
- `tmp/ruby/lib/timeout.rb` - Ractor-safe timeout pattern
- `tmp/ruby/doc/NEWS/NEWS-4.0.0.md` - Ruby 4.0 changes
- `tmp/ruby/doc/language/ractor.md` - Ractor documentation
- `tmp/ruby/doc/language/fiber.md` - Fiber scheduler documentation

### Umi Spikes
- `spikes/spike_f_box_ractor.rb` - Box + Ractor interaction, workarounds for class variables
- `spikes/spike_g_ractor_zjit.rb` - Ractor + JIT performance (YJIT vs ZJIT)
- `spikes/spike_h_fiber_ractor.rb` - Fiber + Ractor interaction (13 tests)
- `spikes/spike_i_fiber_ractor_scheduler.rb` - Custom Fiber scheduler with Ractor.select
- `spikes/spike_j_signal_handler_reentrancy.rb` - Signal handler safety with Ractor::Port
- `spikes/spike_k_signal_coordinator_options.rb` - Coordinator placement options (main vs child)
