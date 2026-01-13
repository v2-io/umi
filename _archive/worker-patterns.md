# Worker Patterns: Beyond Request/Response

This document covers worker abstractions beyond the basic GenServer request/response
pattern, with Ruby 4.0 Port equivalents.

Based on "Designing Elixir Systems with OTP" Chapter 8: Summon Your Workers.

---

## Table of Contents

1. [Why Workers?](#why-workers)
2. [Tasks: One-Shot Concurrent Work](#tasks-one-shot-concurrent-work)
3. [Pooling: Bounded Concurrency](#pooling-bounded-concurrency)
4. [DynamicSupervisor: On-Demand Processes](#dynamicsupervisor-on-demand-processes)
5. [Scheduling: Delayed and Periodic Work](#scheduling-delayed-and-periodic-work)
6. [Registry: Finding Dynamic Processes](#registry-finding-dynamic-processes)
7. [Implications for Umi](#implications-for-umi)

---

## Why Workers?

The book identifies three motivations for introducing worker processes:

### 1. Concurrency (Micro Concern)

> "In the simplest terms, concurrency means doing more than one thing at the
> same time."

Examples:
- Fire 6 database queries in parallel instead of sequentially
- Run a timer while the user works
- Process uploads in the background

### 2. Isolation (Fault Tolerance)

> "Processes aren't just for concurrency. They also insulate users from one
> another."

Examples:
- One user's crash doesn't affect others
- Twitter integration failure doesn't take down the whole system
- Policy decision: which failures are fatal vs recoverable

### 3. Scalability (Macro Concern)

> "When you strategically use concurrency across an entire system, Elixir
> allows a single instance of a program to take advantage of all system cores."

The key insight: **Most of the time, leverage frameworks rather than building
your own concurrency abstractions.**

---

## Tasks: One-Shot Concurrent Work

### The Problem

You have a slow operation and want to do other work while waiting:

```elixir
# Sequential: 2 seconds total
result1 = slow_db_query_1()  # 1 second
result2 = slow_db_query_2()  # 1 second

# Concurrent: 1 second total (they run in parallel)
```

### Elixir Solution: Task.async/await

```elixir
task = Task.async(fn -> slow_db_query_1() end)
result2 = slow_db_query_2()  # runs while task is working
result1 = Task.await(task)   # collect result (blocks if not ready)
```

**Key properties:**
- Task is linked to caller (caller dies if task crashes)
- `await` blocks until result ready (with timeout)
- Result is returned directly

### Bounded Parallelism: Task.async_stream

The naive approach is dangerous:

```elixir
# DON'T DO THIS - can spawn thousands of tasks
items
|> Enum.map(&Task.async(fn -> process(&1) end))
|> Enum.map(&Task.await/1)
```

The safe approach:

```elixir
# Limits concurrency to number of CPU cores
items
|> Task.async_stream(fn item -> process(item) end)
|> Enum.map(fn {:ok, result} -> result end)
```

`Task.async_stream` defaults to `System.schedulers_online()` concurrent tasks—
usually the number of CPU cores. This provides **natural backpressure**.

### Ruby 4.0 Equivalent

The Port model makes this pattern very natural:

```ruby
# Simple async task
def async_task(&block)
  result_port = Ractor::Port.new

  Ractor.new(result_port, &block) do |port, work|
    result = work.call
    port.send([:ok, result])
  rescue => e
    port.send([:error, e.message])
  end

  result_port  # caller can wait on this whenever they want
end

# Usage
task = async_task { slow_db_query_1() }
result2 = slow_db_query_2()  # runs in parallel

case task.receive
in [:ok, result1] then ...
in [:error, msg] then ...
end
```

**The Port advantage**: The "reply channel" is explicit. The caller creates it,
passes it in, and decides when to wait on it. No magic `from` parameter.

### Bounded Parallel Stream in Ruby

```ruby
def parallel_map(items, max_concurrent: Etc.nprocessors)
  items.each_slice(max_concurrent).flat_map do |batch|
    # Start all tasks in batch
    ports = batch.map do |item|
      port = Ractor::Port.new
      Ractor.new(port, item) do |p, i|
        p.send(yield(i))
      end
      port
    end

    # Collect all results
    ports.map(&:receive)
  end
end

# Usage
results = parallel_map(items) { |item| process(item) }
```

---

## Pooling: Bounded Concurrency

### The Problem

Some resources are expensive to create or limited in quantity:
- Database connections (memory, server limits)
- HTTP clients (socket limits)
- External API connections (rate limits)

You want N workers shared across M requests (where M >> N).

### Elixir Solution: Poolboy

```elixir
# Configuration in application.ex
defp poolboy_config do
  [
    {:name, :worker_pool},
    {:worker_module, MyApp.Worker},
    {:size, 3},           # permanent workers
    {:max_overflow, 2}    # temporary workers under load
  ]
end

# Usage: borrow a worker, do work, return it
:poolboy.transaction(:worker_pool, fn pid ->
  GenServer.call(pid, request)
end)
```

**Key properties:**
- Fixed number of workers (plus overflow)
- Caller blocks if no worker available (backpressure)
- Workers are reused (no startup cost per request)
- Worker crash → pool creates a new one

### The Pool Pattern (Abstract)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  POOL                                                                       │
│                                                                             │
│  Configuration:                                                             │
│    - Worker module (how to start a worker)                                 │
│    - Size (permanent workers)                                              │
│    - Max overflow (temporary workers)                                      │
│    - Checkout timeout (how long to wait for a worker)                      │
│                                                                             │
│  Operations:                                                                │
│    checkout() → {:ok, worker} | {:error, :timeout}                         │
│    checkin(worker) → :ok                                                   │
│    transaction(fn worker -> ... end) → result                              │
│                                                                             │
│  Invariants:                                                                │
│    - At most size + max_overflow workers exist                             │
│    - Workers are reused across checkouts                                   │
│    - Worker crash → pool starts replacement                                │
│    - Checkout without checkin → detected, worker restarted                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Ruby 4.0 Equivalent

```ruby
class Umi::Pool
  def initialize(size:, overflow: 0, &worker_factory)
    @command_port = Ractor::Port.new
    @worker_factory = worker_factory

    @ractor = Ractor.new(@command_port, size, overflow, worker_factory) do |cmd, sz, ovf, factory|
      available = sz.times.map { factory.call }
      overflow_available = ovf
      waiting = []

      loop do
        case cmd.receive
        in [:checkout, reply_port, timeout_port]
          if available.any?
            worker = available.pop
            reply_port.send([:ok, worker])
          elsif overflow_available > 0
            overflow_available -= 1
            worker = factory.call
            reply_port.send([:ok, worker])
          else
            waiting << reply_port
          end

        in [:checkin, worker, is_overflow]
          if waiting.any?
            waiting.shift.send([:ok, worker])
          elsif is_overflow
            # Let overflow worker die
            overflow_available += 1
          else
            available << worker
          end

        in [:worker_died, was_overflow]
          if was_overflow
            overflow_available += 1
          else
            available << factory.call
          end
        end
      end
    end
  end

  def transaction(timeout: 5.0)
    reply_port = Ractor::Port.new
    timer_port = Ractor::Port.new
    Thread.new { sleep(timeout); timer_port.send(:timeout) rescue nil }

    @command_port.send([:checkout, reply_port, timer_port])

    case Ractor.select(reply_port, timer_port)
    in [^reply_port, [:ok, worker]]
      begin
        yield(worker)
      ensure
        @command_port.send([:checkin, worker, false])
      end
    in [^timer_port, _]
      raise Timeout::Error, "pool checkout timeout"
    end
  end
end
```

---

## DynamicSupervisor: On-Demand Processes

### The Problem

Some processes are created dynamically based on user actions:
- A process per user session
- A process per game room
- A process per upload

You don't know at startup how many you'll need.

### Elixir Solution: DynamicSupervisor

```elixir
# In application.ex - start the dynamic supervisor
children = [
  {DynamicSupervisor, name: MyApp.SessionSupervisor, strategy: :one_for_one}
]

# Later - start a child dynamically
DynamicSupervisor.start_child(MyApp.SessionSupervisor, {
  MyApp.Session,
  [user_id: user_id]
})

# Find all children
DynamicSupervisor.which_children(MyApp.SessionSupervisor)

# Stop a specific child
DynamicSupervisor.terminate_child(MyApp.SessionSupervisor, pid)
```

**Key properties:**
- Children started at runtime, not boot
- Same restart policies as regular Supervisor
- Combined with Registry for lookup by key

### The Pattern (Abstract)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  DYNAMIC SUPERVISOR                                                         │
│                                                                             │
│  Unlike regular Supervisor:                                                 │
│    - Children are not defined at startup                                   │
│    - Children are added/removed at runtime                                 │
│    - Usually combined with Registry for lookup                             │
│                                                                             │
│  Operations:                                                                │
│    start_child(spec) → {:ok, pid} | {:error, reason}                       │
│    terminate_child(pid) → :ok | {:error, :not_found}                       │
│    which_children() → [{id, pid, type, modules}]                           │
│    count_children() → %{active: n, ...}                                    │
│                                                                             │
│  Restart behavior:                                                          │
│    - Child crashes → restarted per its spec                                │
│    - Supervisor crashes → all children lost (unless persistent)            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Ruby 4.0 Considerations

DynamicSupervisor is really just:
1. A place to start children
2. Tracking of which children exist
3. Restart policy application

With Ruby 4.0 Ractors:

```ruby
class Umi::DynamicSupervisor
  def initialize(restart_policy: :permanent)
    @command_port = Ractor::Port.new
    @restart_policy = restart_policy
    @children = {}  # id → {ractor, spec, monitor_port}

    # The supervisor ractor
    @ractor = Ractor.new(@command_port, @restart_policy) do |cmd, policy|
      children = {}

      loop do
        # Use select to wait on command port AND all child monitors
        monitor_ports = children.values.map { |c| c[:monitor_port] }
        selected, msg = Ractor.select(cmd, *monitor_ports)

        case selected
        when cmd
          handle_command(msg, children, policy)
        else
          # A child died
          handle_child_exit(selected, msg, children, policy)
        end
      end
    end
  end

  def start_child(id, &block)
    reply_port = Ractor::Port.new
    @command_port.send([:start_child, id, block, reply_port])
    reply_port.receive
  end

  def terminate_child(id)
    reply_port = Ractor::Port.new
    @command_port.send([:terminate_child, id, reply_port])
    reply_port.receive
  end
end
```

---

## Scheduling: Delayed and Periodic Work

### The Problem

You need work to happen in the future:
- "End this quiz in 60 minutes"
- "Retry this request in 5 seconds"
- "Check for updates every hour"

### Elixir Solutions

**1. GenServer timeout in reply tuple:**

```elixir
def handle_call(:schedule_something, _from, state) do
  # This will send :timeout to handle_info after 5000ms
  {:reply, :ok, state, 5000}
end

def handle_info(:timeout, state) do
  do_scheduled_work()
  {:noreply, state}
end
```

From the book:
> "GenServer timeouts are one of the most underused features in OTP. Loosely
> stated, a timeout says 'If nothing is happening in x milliseconds, I'll make
> it happen.'"

**2. Process.send_after for specific messages:**

```elixir
def start_quiz(quiz, now) do
  # Send :end_quiz to self in `timeout` milliseconds
  timeout = DateTime.diff(quiz.end_at, now, :millisecond)
  Process.send_after(self(), {:end_quiz, quiz.title}, timeout)
end

def handle_info({:end_quiz, title}, state) do
  QuizManager.remove_quiz(title)
  {:noreply, state}
end
```

**3. :timer.send_interval for periodic work:**

```elixir
def init(_) do
  :timer.send_interval(60_000, :check_for_updates)
  {:ok, %{}}
end

def handle_info(:check_for_updates, state) do
  # Called every 60 seconds
  {:noreply, state}
end
```

### Ruby 4.0 Equivalents

**Timer Port Pattern:**

```ruby
def schedule_after(delay_seconds, port, message)
  Thread.new do
    sleep(delay_seconds)
    port.send(message) rescue nil
  end
end

# Usage in a worker
def run
  timer_port = Ractor::Port.new
  command_port = Ractor::Port.new

  # Schedule quiz end in 60 minutes
  schedule_after(3600, timer_port, [:end_quiz, quiz_id])

  loop do
    case Ractor.select(command_port, timer_port)
    in [^command_port, msg]
      handle_command(msg)
    in [^timer_port, [:end_quiz, id]]
      end_quiz(id)
    end
  end
end
```

**Periodic Timer:**

```ruby
def start_interval(seconds, port, message)
  Thread.new do
    loop do
      sleep(seconds)
      port.send(message) rescue break
    end
  end
end

# Usage
health_check_port = Ractor::Port.new
start_interval(60, health_check_port, :check)

loop do
  case Ractor.select(command_port, health_check_port)
  in [^health_check_port, :check]
    perform_health_check()
  in [^command_port, msg]
    handle_command(msg)
  end
end
```

**The Port advantage**: Scheduled messages arrive on a dedicated port, so they
don't need to be distinguished from other message types via pattern matching.

---

## Registry: Finding Dynamic Processes

### The Problem

With dynamic processes, you need to find them later:
- "Get the session for user@example.com"
- "Find all sessions for quiz 'math-101'"
- "Stop all sessions for a user"

### Elixir Solution: Registry

```elixir
# Start registry in application.ex
{Registry, [name: MyApp.Registry.Sessions, keys: :unique]}

# Register when starting a process (via tuple)
def start_link({quiz_title, email}) do
  GenServer.start_link(__MODULE__, {quiz_title, email},
    name: via({quiz_title, email}))
end

defp via(name) do
  {:via, Registry, {MyApp.Registry.Sessions, name}}
end

# Lookup later
Registry.lookup(MyApp.Registry.Sessions, {quiz_title, email})

# Find all keys for a pid
Registry.keys(MyApp.Registry.Sessions, pid)
```

**Key properties:**
- Auto-unregister when process dies
- Can use compound keys like `{quiz_title, email}`
- Can find all keys for a given pid

### The Pattern (Abstract)

This is covered in [otp-principles-abstract.md](./otp-principles-abstract.md)
Layer 5: Registry. The key insight for dynamic workers:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  REGISTRY + DYNAMIC SUPERVISOR = Named Dynamic Processes                   │
│                                                                             │
│  Pattern:                                                                   │
│    1. DynamicSupervisor starts the process                                 │
│    2. Process registers itself with Registry on init                       │
│    3. Callers find process via Registry, not pid                          │
│    4. Process death auto-unregisters                                       │
│                                                                             │
│  Benefits:                                                                  │
│    - Restart gets new pid, but same name                                   │
│    - Callers don't need to track pids                                      │
│    - Can query "all processes matching X"                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Implications for Umi

### What Umi Should Provide

Based on this analysis, Umi should consider providing:

**1. Umi::Task** - Simple one-shot concurrent work

```ruby
# Fire and forget (but linked for crash propagation)
task = Umi::Task.async { slow_work() }
other_work()
result = task.await(timeout: 5.0)

# Bounded parallelism
results = Umi::Task.parallel(items, max: 4) { |item| process(item) }
```

**2. Umi::Pool** - Resource pooling

```ruby
pool = Umi::Pool.new(size: 5, overflow: 2) { DatabaseConnection.new }

pool.transaction do |conn|
  conn.query("SELECT ...")
end
```

**3. Umi::DynamicSupervisor** - On-demand supervised workers

```ruby
supervisor = Umi::DynamicSupervisor.new(restart: :transient)

# Start a session for this user
supervisor.start_child(user_id) { UserSession.new(user_id) }

# Terminate when done
supervisor.terminate_child(user_id)
```

**4. Timer utilities**

```ruby
# One-shot
Umi::Timer.after(60) { port.send(:timeout) }

# Periodic
Umi::Timer.every(5) { port.send(:heartbeat) }
```

### The Ruby 4.0 Port Advantage

Several patterns are cleaner with Ports:

| Elixir Pattern | Ruby 4.0 Port Equivalent |
|----------------|--------------------------|
| Task.await with timeout | `Ractor.select(result_port, timer_port)` |
| Poolboy transaction | Same, but reply port explicit |
| GenServer timeout | Dedicated timer port in select |
| Process.send_after | `Thread.new { sleep; port.send }` |
| Selective receive in scheduler | Different ports for different concerns |

The common theme: **explicit ports replace implicit mailbox routing**.

### Priority for Umi

Based on the book's guidance and practical utility:

| Component | Priority | Reason |
|-----------|----------|--------|
| **Supervisor** | Essential | Core of fault tolerance |
| **DynamicSupervisor** | High | Per-user/per-session is common |
| **Registry** | High | Finding dynamic processes |
| **Task** | Medium | Useful but often use Ractors directly |
| **Pool** | Medium | Important for DB, can use existing gems |
| **Timer** | Low | Simple Thread wrapper |

---

## References

- *Designing Elixir Systems with OTP*, Chapter 8: Summon Your Workers
- [Task — Elixir](https://hexdocs.pm/elixir/Task.html)
- [DynamicSupervisor — Elixir](https://hexdocs.pm/elixir/DynamicSupervisor.html)
- [Registry — Elixir](https://hexdocs.pm/elixir/Registry.html)
- [Poolboy — GitHub](https://github.com/devinus/poolboy)
- [otp-principles-abstract.md](./otp-principles-abstract.md) - Layer 5: Registry
- [genserver-analysis.md](./genserver-analysis.md) - Basic worker pattern
