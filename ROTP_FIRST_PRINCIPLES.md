# ROTP First Principles: What Are We Actually Solving?

## The Reframe

Before diving into "how do we implement GenServer in Ruby," we should ask:
**What problems does OTP solve, and what's the Ruby-native way to solve them?**

OTP is a solution. "Release It!" describes the problems. Ruby 4.0 Ractors provide
new primitives. Let's reason from problems to solutions rather than translating
someone else's answers.

---

## Part 1: The Problems (from Release It!)

### 1.1 The Root Problem: Cracks Propagate

> "Triggering a fault opens the crack. Faults become errors, and errors provoke
> failures. That's how the cracks propagate."

The core insight: **tight coupling accelerates cracks**. Every connection is a
potential failure point. Every shared resource is a bottleneck waiting to become
a system-wide outage.

**Key terminology:**
- **Fault**: Incorrect internal state (a latent bug triggered, unchecked boundary)
- **Error**: Visibly incorrect behavior
- **Failure**: Unresponsive system

### 1.2 Stability Antipatterns

These are the *problems* we must solve:

| Antipattern | Description | Why It Kills Systems |
|-------------|-------------|---------------------|
| **Integration Points** | Every external call is a liability | Connections × failure modes = explosion |
| **Chain Reactions** | One failure triggers another | Load spreads to remaining instances |
| **Cascading Failures** | Failure in one layer triggers failure in callers | Tight coupling propagates cracks |
| **Blocked Threads** | Threads waiting on impossible outcomes | System appears up but does nothing |
| **Self-Denial Attacks** | Your own code creates traffic spikes | Flash sales, viral content, retry storms |
| **Scaling Effects** | Point-to-point connections don't scale | O(n²) connections explode |
| **Unbalanced Capacities** | Backend can't handle frontend's load | Mismatched scaling ratios |
| **Dogpile** | Everyone retries at once after recovery | Thundering herd kills recovery |
| **Slow Responses** | Worse than no response | Ties up caller resources |
| **Unbounded Result Sets** | Queries return unlimited data | Memory exhaustion, timeouts |

### 1.3 The Key Insight: Two Philosophies

> "One camp says we need to make systems fault-tolerant... The other camp says
> 'let it crash' so you can restart from a known good state."
>
> "Both camps agree: Faults will happen; they can never be completely prevented.
> And we must keep faults from becoming errors."

This is the fundamental tension:
1. **Defensive programming**: Catch and handle every possible error
2. **Offensive programming**: Crash fast, restart clean

OTP chose "let it crash" + supervision. But the real answer is: **both**, at
different layers. Defensive at boundaries, offensive within components.

---

## Part 2: The Solutions (Stability Patterns)

These patterns address the antipatterns above:

### 2.1 Timeouts

> "Hope is not a design method."

Every external call must have a timeout. Without one, a single hung connection
can consume threads forever.

**Ruby-native formulation:**
```ruby
# Ruby 4.0 has Ractor.select with timeout capability
Ractor.select(port, timeout: 5.0)

# Or use Timeout module (but be careful with thread safety)
Timeout.timeout(5) { external_call }
```

**Key insight**: Timeouts are *incoming* protection (protecting ourselves from
others' slowness). Fail Fast is *outgoing* protection (not wasting others' time).

### 2.2 Circuit Breaker

> "Circuit breakers exist to prevent operations rather than reexecute them."

State machine: **Closed → Open → Half-Open → Closed**

When failures exceed threshold, stop trying. Periodically test if recovery
occurred. This prevents:
- Wasting resources on known-broken integration points
- Dogpiling a recovering system
- Cascading failures from slow/failing backends

**Ruby-native formulation:**
```ruby
# A circuit breaker is naturally a stateful object
# Ruby's blocks make wrapping elegant:
CircuitBreaker.wrap(:payment_gateway) do
  PaymentAPI.charge(amount)
end
```

### 2.3 Bulkheads

> "The bulkhead enforces a principle of damage containment."

Partition resources so one failure doesn't consume everything:
- Separate thread pools for different operations
- Separate Ractors for different concerns
- Separate process groups for critical vs. non-critical

**Ruby 4.0 insight**: **Ractors ARE bulkheads**. Each Ractor is memory-isolated.
A crash in one Ractor cannot corrupt another's state. This is profound—Ruby 4.0
gives us structural bulkheads by default.

```ruby
# Each Ractor is a natural bulkhead
critical_work = Ractor.new { handle_payments }
background_work = Ractor.new { send_emails }
# A crash in background_work cannot affect critical_work
```

### 2.4 Fail Fast

> "If the system can determine in advance that it will fail at an operation,
> it's always better to fail fast."

Check prerequisites before starting work:
- Are required connections available?
- Are circuit breakers open?
- Is input valid?

**The chef's mise en place**: Gather all ingredients before cooking.

**Ruby-native formulation:**
```ruby
def process_order(order)
  # Fail fast: check everything upfront
  raise ResourceUnavailable unless db_pool.available?
  raise CircuitOpen if payment_breaker.open?
  raise InvalidInput unless order.valid?

  # Now proceed with confidence
  actually_process(order)
end
```

### 2.5 Let It Crash

This is the big one. The key insight:

> "The cleanest state your program can ever have is right after startup."

**Requirements for "let it crash" to work:**
1. **Limited granularity**: Crash a component, not the system
2. **Fast replacement**: Get back to clean state quickly
3. **Supervision**: Something must restart crashed components
4. **Reintegration**: Restored components must rejoin the system

**Ruby 4.0 insight**: Ractors provide the granularity. A Ractor can crash
without taking down the Ruby process. But we need to build supervision.

### 2.6 Backpressure

> "Every performance problem starts with a queue backing up somewhere."

When a queue is full, options are:
1. Drop the item (silently or loudly)
2. Drop something else (oldest item)
3. Refuse the item (fail fast)
4. Block the producer (true backpressure)

**Ruby 4.0 insight**: Ractor mailboxes are unbounded by default. We must add
bounded queues explicitly. This is a design gap we need to fill.

```ruby
# Bounded queue with backpressure
class BoundedPort
  def initialize(max_size:)
    @queue = Queue.new
    @max_size = max_size
    @semaphore = Concurrent::Semaphore.new(max_size)
  end

  def send(msg)
    @semaphore.acquire  # Blocks if full
    @queue.push(msg)
  end

  def receive
    msg = @queue.pop
    @semaphore.release
    msg
  end
end
```

### 2.7 Governor

> "Automation has no judgment. When it goes wrong, it tends to go wrong really quickly."

Rate-limit dangerous operations. Provide time for human intervention.

**Ruby-native formulation:**
```ruby
class Governor
  def initialize(max_rate:, window:)
    @max_rate = max_rate
    @window = window
    @actions = []
  end

  def permit?
    cleanup_old_actions
    @actions.size < @max_rate
  end

  def record_action
    @actions << Time.now
  end
end
```

---

## Part 3: Ruby 4.0 Primitives

What does Ruby 4.0 actually give us?

### 3.1 Ractors: Isolated Parallel Execution

```ruby
r = Ractor.new { expensive_computation }
result = r.value  # Blocks until done
```

**Key properties:**
- True parallelism (not GVL-limited like threads)
- Memory isolation (no shared mutable state)
- Message passing (explicit communication)
- Crash isolation (one Ractor crash doesn't kill others)

### 3.2 Ractor::Port: Named Mailboxes

New in Ruby 4.0:
```ruby
port = Ractor::Port.new
r = Ractor.new(port) do |p|
  loop { msg = p.receive; process(msg) }
end
port << "message"  # Send to the Ractor
```

This is significant: **multiple ports per Ractor** enables selective message
handling, which was awkward before.

### 3.3 Ractor.select: Multiplexed Waiting

```ruby
# Wait for any of multiple Ractors/Ports
ready, msg = Ractor.select(r1, r2, port, timeout: 5.0)
```

This enables the "receive with timeout" pattern essential for resilience.

### 3.4 What Ruby 4.0 Does NOT Provide

- **Process linking**: No automatic notification when a Ractor terminates
- **Supervision**: No built-in restart logic
- **Hot code reloading**: No way to update code in running Ractors
- **Distributed Ractors**: Single-node only
- **Bounded mailboxes**: Mailboxes grow without limit

---

## Part 4: Ruby-Native Synthesis

Here's where we reason from principles to a Ruby-elegant design.

### 4.1 The Core Abstraction: "Worker"

Instead of copying OTP's GenServer, what if we design for Ruby?

A "Worker" is:
- A Ractor with a lifecycle (init → running → terminated)
- A named identity (for discovery)
- A contract (what messages it handles)
- Resilience properties (how it handles failure)

```ruby
class PaymentProcessor
  include ROTP::Worker

  # Declarative resilience
  resilience timeout: 30.seconds,
             circuit_breaker: { threshold: 5, cooldown: 1.minute }

  # Lifecycle
  def init(config)
    @gateway = PaymentGateway.new(config[:api_key])
    :ok
  end

  # Message handlers using pattern matching
  def handle([:charge, amount, card]) = @gateway.charge(amount, card)
  def handle([:refund, transaction_id]) = @gateway.refund(transaction_id)
  def handle(_) = :unknown_message
end

# Usage
processor = PaymentProcessor.start(api_key: "...")
result = processor.call([:charge, 100, card_token])
```

### 4.2 The Supervision Philosophy

Rather than complex supervision trees, what if we embrace Ruby's simplicity?

**Principle**: Supervision should be *declarative*, not *structural*.

```ruby
class MyApplication
  include ROTP::Application

  workers do
    # Workers with restart policies
    worker PaymentProcessor, restart: :permanent, instances: 3
    worker EmailSender, restart: :transient
    worker ReportGenerator, restart: :temporary
  end

  # Restart strategies as policies, not tree structures
  policy :payments_critical do
    max_restarts 5, within: 1.minute
    on_max_restarts :alert_humans
  end
end
```

**Restart semantics:**
- `:permanent` - Always restart
- `:transient` - Restart only on abnormal exit
- `:temporary` - Never restart

### 4.3 Resilience as Composition

Ruby loves composition. What if resilience patterns are composable?

```ruby
# Resilience patterns as decorators/wrappers
processor = PaymentProcessor.new
  .with_timeout(30.seconds)
  .with_circuit_breaker(threshold: 5)
  .with_retry(max: 3, backoff: :exponential)
  .with_bulkhead(max_concurrent: 10)

# Or declaratively in the class
class PaymentProcessor
  include ROTP::Worker
  include ROTP::Resilient

  resilient do
    timeout 30.seconds
    circuit_breaker threshold: 5, cooldown: 1.minute
    retry_policy max: 3, backoff: :exponential
    bulkhead max_concurrent: 10
  end
end
```

### 4.4 The Registry as First-Class

OTP has multiple registry mechanisms. Ruby should have one good one:

```ruby
# Simple, type-safe, observable
ROTP::Registry.register(:payment_processor, processor)
ROTP::Registry.lookup(:payment_processor)
ROTP::Registry.whereis(:payment_processor)  # => Ractor or nil
ROTP::Registry.list  # => all registered names

# With pattern matching
case ROTP::Registry.lookup(:payment_processor)
in Ractor => r then r.call(msg)
in nil then raise WorkerNotFound
end
```

### 4.5 The Clean Architecture Integration

Following the OTP book's layered approach, but Ruby-style:

```
┌─────────────────────────────────────────┐
│  API Layer (Controllers/Handlers)       │ ← HTTP/WebSocket/CLI
├─────────────────────────────────────────┤
│  Boundary Layer (Workers)               │ ← ROTP::Worker
├─────────────────────────────────────────┤
│  Core Layer (Pure Ruby)                 │ ← Data + Functions
└─────────────────────────────────────────┘
```

**Core Layer**: Pure Ruby classes, Data.define structs, no side effects
**Boundary Layer**: Workers that wrap core logic in resilient Ractors
**API Layer**: Thin handlers that dispatch to workers

```ruby
# Core Layer - Pure, testable
module Mastery
  module Core
    Quiz = Data.define(:title, :questions, :mastery_level) do
      def add_question(q) = with(questions: questions + [q])
      def complete? = questions.all?(&:answered?)
    end
  end
end

# Boundary Layer - Ractor-based worker
module Mastery
  module Boundary
    class QuizManager
      include ROTP::Worker

      def init(_) = { quizzes: {} }

      def handle([:create, title], state)
        quiz = Core::Quiz.new(title: title, questions: [], mastery_level: 2)
        [:ok, state.merge(title => quiz)]
      end

      def handle([:lookup, title], state)
        [state[title], state]
      end
    end
  end
end
```

---

## Part 5: Open Questions and Design Decisions

### 5.1 How to Detect Ractor Death?

Erlang processes can be linked. When one dies, linked processes are notified.
Ruby Ractors don't have this.

**Options:**
1. **Polling**: Supervisor periodically checks `ractor.alive?`
2. **Heartbeat**: Workers send periodic "I'm alive" messages
3. **Wrapper Ractor**: Each worker is wrapped by a monitoring Ractor
4. **Ruby extension**: C extension that hooks Ractor termination

**Recommendation**: Start with heartbeats. Simple, understandable, no magic.

```ruby
class SupervisedWorker
  HEARTBEAT_INTERVAL = 5.seconds

  def run_loop
    loop do
      # Process messages with timeout
      case Ractor.select(@port, timeout: HEARTBEAT_INTERVAL)
      in [:heartbeat_request, reply_port]
        reply_port << :alive
      in [msg, reply_port]
        result = handle(msg)
        reply_port << result
      in nil  # Timeout - no messages
        # Continue loop, heartbeat will be requested from outside
      end
    end
  end
end
```

### 5.2 Shareability Constraints

Ractor isolation is strict. Objects crossing boundaries must be:
- Immutable (frozen)
- Or moved (unavailable to sender after)

**This changes API design.** You can't send mutable objects to a Ractor.

**Ruby-native solution**: Embrace immutability with `Data.define`:

```ruby
# These are automatically shareable
Order = Data.define(:id, :items, :total)
OrderItem = Data.define(:sku, :quantity, :price)

order = Order.new(id: 1, items: [OrderItem.new(...)])
worker << order  # Safe to share
```

### 5.3 When NOT to Use Ractors

Ractors have overhead. Not everything should be a Ractor.

**Use Ractors for:**
- Long-running background work
- CPU-intensive computation
- Isolation boundaries (handling untrusted input)
- Failure isolation (payment processing)

**Don't use Ractors for:**
- Simple, fast operations
- Things that share lots of mutable state
- Tight loops with frequent communication

### 5.4 Integration with Existing Ruby Ecosystem

Most Ruby gems are not Ractor-safe. How do we handle this?

**Options:**
1. **Ractor-local gems**: Initialize gem in each Ractor
2. **Gateway Ractor**: One Ractor owns the gem, others communicate via messages
3. **Don't use Ractors there**: Accept some things can't be parallelized

**Pragmatic recommendation**: Use a "gateway" pattern for non-Ractor-safe code:

```ruby
# ActiveRecord isn't Ractor-safe, so contain it
class DatabaseGateway
  include ROTP::Worker

  def init(_)
    # This Ractor owns the DB connection
    @conn = ActiveRecord::Base.connection
    :ok
  end

  def handle([:query, sql])
    @conn.execute(sql)
  end
end

# Other Ractors communicate via messages
db = ROTP::Registry.lookup(:database)
result = db.call([:query, "SELECT * FROM users"])
```

---

## Part 6: Implementation Roadmap

### Phase 1: Shellac (Current Focus)

**See: `phase-1-pilot-shellac.md`**

Before building internal Ractor supervision, we're solving the same problem for
external processes. Shellac wraps a long-lived OS process as a Ractor-citizen:

- Bidirectional messaging (stdin/stdout as send/receive)
- Death notification (linked lifecycle)
- Timeout support throughout

This forces us to solve the hard problems (death detection, multiplexing) in a
concrete, testable context. What we learn applies directly to Ractor supervision.

```ruby
shellac = ROTP::Shellac.new("redis-server")
shellac << "PING\r\n"
response = shellac.receive(timeout: 5.0)
shellac.on_exit { |result| log "Redis exited: #{result}" }
```

### Phase 2: Foundations
- [ ] `ROTP::Worker` module - basic Ractor wrapper with lifecycle
- [ ] `ROTP::Registry` - simple name registration
- [ ] Apply Shellac patterns to Ractor death detection
- [ ] Basic examples and tests

### Phase 3: Resilience Patterns
- [ ] `ROTP::CircuitBreaker` - three-state circuit breaker
- [ ] `ROTP::Retry` - retry with backoff
- [ ] `ROTP::Bulkhead` - bounded concurrency
- [ ] `ROTP::Resilient` - declarative composition

### Phase 4: Supervision
- [ ] Heartbeat-based liveness detection
- [ ] Restart policies (permanent/transient/temporary)
- [ ] Max restart tracking
- [ ] Application lifecycle management

### Phase 5: Polish
- [ ] Telemetry/metrics hooks
- [ ] Graceful shutdown
- [ ] Documentation
- [ ] Real-world examples

---

## Conclusion: The Ruby Way

OTP is brilliant, but it's the Erlang/Elixir way. Ruby should have its own idioms:

| OTP | Ruby-Native |
|-----|-------------|
| Behaviours | Modules + duck typing |
| `GenServer.call/cast` | Blocks with timeout |
| Supervision trees | Declarative restart policies |
| `spawn_link` | Heartbeat-based monitoring |
| Immutable by default | `Data.define` + frozen objects |

**The goal is not to make Ruby act like Erlang.** The goal is to solve the same
problems—crack propagation, cascading failures, blocked threads—in a way that
feels natural to Rubyists.

Ruby 4.0's Ractors give us the primitives. "Release It!" tells us what problems
to solve. The OTP book shows one way to layer the solution. Now we build
something that honors Ruby's philosophy: **programmer happiness through elegant
simplicity**.

---

## References

- Nygard, Michael T. "Release It! Second Edition." Pragmatic Programmers, 2018.
- Thomas, Dave et al. "Programming Ruby 4th Edition (6th Edition)." Pragmatic Programmers, 2025.
- Mather, Bruce et al. "Designing Elixir Systems with OTP." Pragmatic Programmers, 2019.
- Ruby 4.0.0 Release Notes: https://www.ruby-lang.org/en/news/2025/12/25/ruby-4-0-0-released/
