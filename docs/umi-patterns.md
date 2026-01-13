# Umi Patterns

*Authoritative reference for implementing Umi abstractions.*

This document is deliberately short. It captures what we've settled and what's
still being designed.

---

## The Mental Model: What Makes Umi Different

Four concepts form the foundation of OTP-style thinking in Ruby:

### 1. Isolated Concurrency with Message Passing

Each Serveron runs in its own Ractor — an isolated memory space. No shared
mutable state. Communication only through message passing.

This isn't a performance optimization. It's a **failure boundary**. When a
Serveron crashes, it can't corrupt another Serveron's state. The isolation
is what makes "let it crash" safe.

```ruby
# Normal Ruby: shared state, implicit coupling
counter = Counter.new
thread1 = Thread.new { counter.increment }
thread2 = Thread.new { counter.increment }
# Race conditions, mutex needed, crash in one can corrupt other's view

# Umi: isolated state, explicit messages
counter = Counter.start_link
counter.call(:increment)  # Message crosses boundary, response comes back
# Counter crash can't corrupt caller's state
```

**The boundary is the point.** Crossing it is explicit (message passing),
observable (can timeout), and safe (isolation prevents corruption).

### 2. Four Layers of Identity

In normal Ruby, if you have a reference, the thing exists. In Umi, identity has
four distinct layers:

| Layer | What it answers | Lifetime | Example |
|-------|-----------------|----------|---------|
| **Type** | "What kind of thing am I?" | Permanent (it's code) | `Counter`, `Umi::Exeron` |
| **Role** | "What's my job in this tree?" | Supervisor lifetime | `:primary`, `:pool_worker_1` |
| **Instance** | "Which specific living thing?" | Ephemeral | `handle.instance_id` |
| **Name** | "Stable identity across restarts?" | Application lifetime | `:main_counter` |

**Why this matters:** The gap between Name and Instance is where all the
interesting resilience patterns live.

```ruby
# You have a Name...
:main_counter

# But the Instance behind it could be:
# - Alive and healthy
# - Alive but degraded
# - Dead, restart in progress
# - Dead, max restarts exceeded
# - Responding but slow
# - Not responding (timed out)
```

This is **temporary unavailability** — a concept Ruby's object model has no
vocabulary for. In normal Ruby, references are binary: exists or doesn't. In
Umi, a Name is a stable pointer to something that might be transiently unavailable.

### 3. Result Tuples with Pattern Matching

Operations return tagged tuples, enabling explicit handling of all outcomes:

```ruby
case serveron.call(:work, timeout: 5.0)
in [:ok, value]     then process(value)
in [:error, reason] then handle_error(reason)
in nil              then handle_timeout()
end
```

This isn't functional programming aesthetics — it's making failure modes visible.
Every call site explicitly decides what to do with success, error, and timeout.

### 4. Timeout as Control Flow

Timeout is not an exception. It's a normal outcome, slightly less common than
success. Code that times out isn't broken — it's encountering expected behavior
in distributed systems.

```ruby
# Timeout is a peer of success, not a rescue clause
case result
in [:ok, value] then ...
in nil          then ...   # Not exceptional — expected
end
```

**Default timeouts are mandatory.** Blocking forever requires explicit opt-in.
Every wait is an opportunity to notice, report, and adapt.

---

These four concepts — isolated concurrency, layered identity, result tuples,
timeout as control flow — are the mental model. Everything else follows from them.

---

## API Conventions

These conventions apply across Umi abstractions.

### Tagged Tuples

All operations return tagged tuples for pattern matching:

```ruby
[:ok, value]        # Success with value
[:error, reason]    # Failure with reason
[:closed, result]   # Entity died/exited, here's the death info
```

Use Ruby's `case/in` for handling:

```ruby
case thing.operation(timeout: 5.0)
in [:ok, value]     then handle_success(value)
in [:error, reason] then handle_error(reason)
in [:closed, info]  then handle_death(info)
in nil              then handle_timeout()
end
```

### Timeout Returns Nil

Timeout is **control flow**, not an exception. It's a peer of success:

```ruby
result = serveron.call(:work, timeout: 5.0)
# Returns [:ok, value], [:error, reason], or nil

if result.nil?
  # Timeout — not rescued, just another branch
  log.warn "Operation timed out, retrying..."
end
```

**Default timeouts are mandatory.** Blocking forever requires explicit opt-in:

```ruby
serveron.call(:work)                    # Uses reasonable default (e.g., 5s)
serveron.call(:work, timeout: 30)       # Explicit timeout
serveron.call(:work, timeout: :forever) # Deliberate infinite wait
```

### Bang Methods *(under discussion)*

Exeron uses bang for "unwrap or raise" (`pop_stdout!`). Whether Serveron follows
the same convention or uses bang for "fire and forget" (original Ruby meaning)
is still being designed. See "Design Questions Under Discussion" below.

For now, Exeron's convention:
- `method` → returns tagged tuple or nil
- `method!` → returns unwrapped value or raises

### Lifecycle Consistency

Every Umi entity has the same lifecycle interface:

```ruby
entity.alive?       # Is it running?
entity.dead?        # Has it terminated? (opposite of alive?)

entity.death_info   # After death: DeathInfo or Result object
                    # nil if still alive

entity.on_death { |info| cleanup(info) }  # Callback when entity dies
```

### Block Form Cleanup

Resource cleanup via block form:

```ruby
Umi::Exeron.open("command") do |ex|
  ex << "input"
  ex.pop_stdout!
end  # Always cleaned up, even on exception

Umi::Serveron.open(MyServeron, args) do |s|
  s.call!(:work)
end  # Always stopped
```

---

## The One Internal: Timer Thread

`Ractor.select` has no native timeout. All timeout behavior uses this pattern:

```ruby
def receive_with_timeout(port, timeout)
  return port.receive if timeout == :forever

  timer_port = Ractor::Port.new
  timer = Thread.new do
    sleep(timeout)
    timer_port << :timeout rescue nil
  end

  begin
    source, msg = Ractor.select(port, timer_port)
    return nil if source == timer_port  # Timeout
    msg
  ensure
    timer.kill
  end
end
```

This is encapsulated—users never see it. But implementers need to know it exists.

---

## Exeron: First Proof of Concept

Exeron (external process wrapper) was the first working implementation. Its
patterns informed this document, but it predates some of our design decisions
and may not reflect final conventions.

**What it wraps:** OS processes (stdin/stdout/stderr)

**Key APIs:**
```ruby
ex = Umi::Exeron.new("command", "arg1", "arg2")

# Reading (returns tagged tuple or nil)
ex.pop_stdout(5.0)  # => [:ok, "line\n"], nil, or [:closed, result]
ex.pop(5.0)         # => [:stdout, data], [:stderr, data], nil, [:closed, result]

# Reading (raises)
ex.pop_stdout!      # => "line\n" or raises Timeout/ProcessExited

# Writing
ex << "data"
ex.puts "line"
ex.close_stdin

# Lifecycle
ex.alive?
ex.exited?
ex.result           # => Result(pid, exit_code, signal, duration)
ex.on_exit { |r| }

# Control
ex.kill(:TERM)
ex.stop(timeout: 5) # TERM, wait, KILL if needed
ex.join(timeout: 10)

# Block form
Umi::Exeron.open("cmd") { |ex| ex.pop_stdout! }

# Multiplexing
Umi::Exeron.select(ex1, ex2, timeout: 5)  # => [ex, message] or nil
```

---

## Serveron: Ruby Code in Isolation

Serveron wraps Ruby code in a Ractor with message-passing semantics.

### What Users Write

```ruby
class Counter < Umi::Serveron
  def init(args)
    @count = args[:start] || 0
  end

  def terminate(reason)
    # Cleanup on shutdown
  end

  # Methods become callable via messages
  def get = @count
  def add(n) = @count += n
end
```

### How It's Used

```ruby
counter = Counter.new(start: 10)

# Synchronous call (returns tuple or nil)
case counter.call(:get, timeout: 5.0)
in [:ok, value] then puts value
in [:error, r]  then handle_error(r)
in nil          then handle_timeout()
end

# Synchronous call (raises)
value = counter.call!(:get)

# Asynchronous cast (fire and forget)
counter.cast(:add, [5])

# Lifecycle
counter.alive?
counter.shutdown
counter.death_info
counter.on_death { |info| }

# Block form
Counter.open(start: 10) do |c|
  c.call!(:add, [5])
  c.call!(:get)
end
```

### What Framework Provides

The Serveron base class handles:
- Ractor creation with isolated block
- Command port for receiving messages
- Message loop dispatching to methods
- Timeout handling (timer thread pattern)
- Reply port management for calls
- Death detection and info collection

Users write plain Ruby methods. Framework handles the plumbing.

---

## Tendon: Supervision

Tendon supervises Serverons (and other Tendons) with restart policies.

### What Users Write

```ruby
tendon = Umi::Tendon.new(
  children: [
    { id: :counter, module: Counter, args: {start: 0} },
    { id: :cache,   module: Cache,   args: {} }
  ],
  strategy: :one_for_one,
  max_restarts: 3,
  max_seconds: 5
)
```

### Child Specification

```ruby
{
  id: :name,              # Unique identifier (required)
  module: SomeServeron,   # Class to instantiate (required)
  args: {},               # Arguments for init (default: {})
  restart: :permanent,    # :permanent, :transient, :temporary
}
```

Restart types:
- `:permanent` — always restart
- `:transient` — restart only on crash (`:aborted`), not clean exit
- `:temporary` — never restart

### Strategies

- `:one_for_one` — only restart the failed child
- `:one_for_all` — restart all children if one fails
- `:rest_for_one` — restart failed child and all started after it

### How It's Used

```ruby
tendon = Umi::Tendon.new(children: [...])

# Lifecycle
tendon.alive?
tendon.shutdown(timeout: 5000)

# Inspection
tendon.children        # => [:counter, :cache]
tendon.child(:counter) # => the Serveron proxy

# Dynamic children
tendon.start_child(id: :new, module: NewServeron, args: {})
tendon.terminate_child(:new)
tendon.restart_child(:counter)
```

### What Framework Provides

- Per-child monitor ports (to know which child died)
- Death info extraction (`:exited` vs `:aborted`, exception details)
- Restart counting with time window
- Escalation (Tendon dies if restarts exceed limit)
- Ordered startup and shutdown

---

## Death Information

When a Ractor dies, monitor sends `:exited` or `:aborted`. To get details:

```ruby
case monitor_port.receive
in :exited
  return_value = ractor.value  # Clean exit, get return value
  DeathInfo.new(type: :normal, value: return_value)

in :aborted
  begin
    ractor.value
  rescue Ractor::RemoteError => e
    DeathInfo.new(type: :error, exception: e.cause)
  rescue Ractor::ClosedError
    DeathInfo.new(type: :killed)
  end
end
```

DeathInfo/Result should include:
- `type` — `:normal`, `:error`, `:killed`
- `exception` — the cause (if `:error`)
- `value` — return value (if `:normal`)
- `duration` — how long it ran

---

## Suggestions

**Don't block forever by default.**
```ruby
# Wrong: no timeout
port.receive

# Right: always have a timeout
receive_with_timeout(port, 5.0)
```

**Don't raise on timeout.**
```ruby
# Wrong: timeout is exceptional
raise Timeout::Error if result.nil?

# Right: timeout is control flow
return handle_timeout() if result.nil?
```

**Don't hide failure modes behind proxy magic.**
```ruby
# Questionable: looks like normal method call
counter.increment  # What if it times out? Crashes?

# Better: explicit about message passing
counter.call(:increment, timeout: 5.0)
```

**Explicitly share immutable data.**
```ruby
# shareable_proc works — just pass data as args, don't capture
start_fn = Ractor.shareable_proc { |klass, args| klass.new(args) }
Ractor.new(start_fn, Counter, {start: 0}) { |fn, k, a| fn.call(k, a) }

# Data classes are naturally shareable (immutable value objects)
UserResult = Data.define(:id, :name, :email)
port << UserResult.new(id: 1, name: "Jo", email: "jo@example.com")

# Frozen objects, symbols, numbers — all shareable
```

**Don't monitor multiple Ractors with one port.**
```ruby
# Wrong: can't tell which died
children.each { |c| c.monitor(shared_port) }

# Right: per-child ports
children.each do |c|
  port = Ractor::Port.new
  c.monitor(port)
  @monitors[port] = c
end
```

---

## Design Questions Under Discussion

The patterns above are settled. These questions are still open:

### Bang Convention for Serveron

Exeron uses bang for "unwrap or raise" (`pop_stdout!`). This makes sense because
Exeron has no async reads—every operation waits for data.

For Serveron, we have two options:

| Convention | `method` | `method!` |
|------------|----------|-----------|
| Rails-style | Returns tuple | Unwraps or raises |
| Original Ruby | Sync (waits for reply) | Async (fire-and-forget) |

The original Ruby meaning (bang = side effects / mutation) maps naturally to
"fire and forget" semantics. But this creates inconsistency with Exeron.

**Open question:** Should Serveron use a different pattern entirely?
```ruby
serveron.request(:work)        # Sync, returns tuple
serveron.fire(:work)           # Async, no reply
```

### call/cast Terminology

The document uses `call` and `cast` (borrowed from OTP). We've questioned whether
these are the right verbs for Ruby:

- **call/cast** — OTP-native, but unfamiliar to Rubyists
- **ask/tell** — Akka terms, possibly more intuitive
- **request/fire** — Explicit about what's happening
- **method names** — Let actorness come through semantics, not verbs

**Key insight:** The actor model's power comes from isolation and failure
semantics, not from specific verb choices. If pattern matching on tagged tuples
is idiomatic, the verbs matter less.

### Multi-Port Patterns

Ruby 4.0's `Ractor::Port` enables patterns beyond OTP's single mailbox:

```ruby
# Subscription: give me a port, send events to it
my_events = Ractor::Port.new
serveron.subscribe(:user_events, my_events)

# Streaming: multiple responses to one request
stream_port = Ractor::Port.new
serveron.stream_all_users(reply_to: stream_port)
loop do
  case stream_port.receive
  in [:item, user] then process(user)
  in [:done] then break
  end
end

# Reply redirection: don't reply to me, reply elsewhere
serveron.do_work(data, reply_to: other_serveron.inbox)
```

**Open question:** How much of this to expose in the core API vs. leave as
advanced/internal capability?

### Internal Fiber Concurrency

Spikes showed that fibers can multiplex across ports within a Serveron:

```ruby
# Inside a Serveron handler, concurrent operations via fiber scheduler
def handle_complex_request(data)
  port_a = dep_a.request(:fetch)
  port_b = dep_b.request(:fetch)

  # Both awaits run "concurrently" via fiber multiplexing
  result_a = await(port_a, timeout: 5)
  result_b = await(port_b, timeout: 5)

  combine(result_a, result_b)
end
```

This is more like Go channels or Elixir's `Task.async/await` than OTP's call/cast.

**Open question:** Is this internal implementation detail, or does it shape
the external API?

### dry-monads Compatibility

Tagged tuples are deliberately primitive. Wrapping with dry-monads is trivial:

```ruby
def to_monad(result)
  case result
  in [:ok, value]     then Success(value)
  in [:error, reason] then Failure(reason)
  in nil              then Failure(:timeout)
  end
end
```

This could be a separate gem (`umi-dry-monads`) for those who want it.

**Design principle:** Umi returns the simplest correct representation. Higher-level
abstractions can wrap as needed.

---

## Summary

**Settled conventions:**
- Tagged tuples: `[:ok, v]`, `[:error, r]`, `[:closed, info]`
- Timeout returns `nil`, not exception
- Internals: timer thread for timeout, per-child monitor ports

**Under discussion:**
- Bang methods: unwrap-or-raise vs fire-and-forget
- Sync/async verbs: `call`/`cast` vs alternatives
- Creation convention: `new` vs `start_link` vs something else
- Lifecycle interface and naming (Exeron uses `result`/`on_exit`, patterns say `death_info`/`on_death`)
- Block form cleanup patterns
- Registry integration with identity layers
- Supervisable protocol (what makes something supervisable by Tendon)
- Identity layer API: how to expose Type/Role/Instance/Name on handles
- Stale handle behavior: error vs auto-redirect via Registry
- Multi-port patterns: subscription, streaming, reply redirection — core API or advanced?
- Internal fiber concurrency: implementation detail or API-shaping?

Exeron was the first proof of concept. It informed these patterns but may not
reflect all final conventions.

---

*This document supersedes docs/plan/*.md for implementation guidance.*
