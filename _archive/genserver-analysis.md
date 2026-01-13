# GenServer from First Principles: Lessons for Umi

Analysis based on "Designing Elixir Systems with OTP" by Bruce Tate and James Gray,
with implications for what Umi can do differently with Ruby 4.0's Port model.

---

## Table of Contents

1. [The Book's Layered Architecture](#the-books-layered-architecture)
2. [What GenServer Actually Does](#what-genserver-actually-does)
3. [The Call vs Cast Insight](#the-call-vs-cast-insight)
4. [The Problems GenServer Solves](#the-problems-genserver-solves)
5. [What Ruby 4.0 Ports Change](#what-ruby-40-ports-change)
6. [Implications for Umi](#implications-for-umi)

---

## The Book's Layered Architecture

The book advocates for a strict layered approach:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Layer 1: DATA                                                              │
│    Structs, types, the "nouns" of your domain                              │
│    Pure data, no behavior                                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│  Layer 2: FUNCTIONAL CORE                                                   │
│    Pure functions that transform data                                       │
│    No processes, no side effects, no I/O                                   │
│    Easy to test, easy to reason about                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│  Layer 3: BOUNDARY (GenServers)                                             │
│    Wraps core in processes for state and isolation                         │
│    Handles uncertainty: user input, external systems, failures             │
│    Two parts: Server layer (GenServer) + API layer (public functions)      │
├─────────────────────────────────────────────────────────────────────────────┤
│  Layer 4: LIFECYCLE (Supervisors)                                           │
│    Starts and stops boundaries                                              │
│    Defines restart policies                                                 │
│    child_spec configuration                                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  Layer 5: WORKERS                                                           │
│    Concurrency for performance, isolation, or reliability                   │
│    Tasks, pools, scheduled jobs                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key insight**: "Many projects will not need any layers beyond [data, functions, tests].
Consider processes when these use cases show up:
- Sharing state across processes
- Presenting a uniform API for external services
- Managing side effects
- Monitoring system-wide resources
- Isolating critical services from failure"

**What's principled**: Separating pure logic from process machinery. The core should
be testable without starting any processes. The boundary is "optional impure
integration code" that makes the core "fast, robust, and reliable."

---

## What GenServer Actually Does

From the book's examples, GenServer provides:

### 1. State Management via Recursive Loop

The GenServer handles the recursive receive loop that maintains state:

```elixir
# You write this:
def handle_call({:get, key}, _from, state) do
  {:reply, Map.get(state, key), state}
end

# GenServer provides the loop that calls it
```

### 2. Three Main Callbacks

| Callback | Purpose | Returns |
|----------|---------|---------|
| `init(args)` | Initialize state | `{:ok, state}` or `{:error, reason}` |
| `handle_call(msg, from, state)` | Sync request/response | `{:reply, response, new_state}` |
| `handle_cast(msg, state)` | Async fire-and-forget | `{:noreply, new_state}` |

Plus `handle_info` for raw messages, `terminate` for cleanup, etc.

### 3. The `from` Parameter

```elixir
def handle_call(request, from, state)
#                        ^^^
# from = {pid, reference} - who to reply to
```

This exists because with one mailbox, you need to know who sent what so you can
route the response back. The GenServer framework handles this for you.

### 4. Pattern Matching for Message Dispatch

```elixir
def handle_call({:build_quiz, fields}, _from, state) do ... end
def handle_call({:add_template, title, fields}, _from, state) do ... end
def handle_call({:lookup, title}, _from, state) do ... end
```

Multiple `handle_call` clauses, distinguished by pattern matching on the message.
This is the "central receive loop" pattern that Ruby 4.0 Ports eliminate.

### 5. API Layer Hides Message Format

```elixir
# Server (callbacks)
def handle_call({:build_quiz, fields}, _from, state) do ... end

# Client (API)
def build_quiz(fields) do
  GenServer.call(QuizManager, {:build_quiz, fields})
end
```

The API layer exists because "we leak through the exact format of each call message,
unnecessarily coupling our GenServer to any code that invokes it."

---

## The Call vs Cast Insight

This is one of the book's most valuable sections:

### Why Call is Preferred

> "Intuitively, you might think that it's best to use the one-way handle_cast to
> send messages that don't need responses... Interestingly, handle_cast is rarely
> the best option."

**The problem**: Cast doesn't provide backpressure. If clients send faster than
the server processes, the mailbox grows unboundedly, eventually crashing the node.

**The Logger example**: Elixir's Logger has three modes:
- `:async` (cast) - fast, no backpressure
- `:sync` (call) - slower, provides backpressure
- `:discard` - drop messages when overwhelmed

```elixir
# Logger switches modes based on mailbox size:
case mode do
  _ when messages >= discard_threshold -> :discard
  :discard when messages > keep_threshold -> :discard
  _ when messages >= sync_threshold -> :sync
  :sync when messages > async_threshold -> :sync
  _ -> :async
end
```

**The principle**: "If your code uses handle_call instead of handle_cast, you don't
need to worry as much because you can only send messages as fast as your server can
process them. It's a great automatic governor on a server."

### When Cast is Appropriate

> "Rarely, you'll want to use cast messages to start multiple workers at once, or
> to notify multiple workers simultaneously. Try to be judicious with this approach."

Cast is for:
- Notifications where you don't need confirmation
- Starting work you'll check on later
- Broadcast to multiple recipients

But these are exceptions, not the rule.

---

## The Problems GenServer Solves

Looking at the book holistically, GenServer addresses these concerns:

| Problem | GenServer Solution |
|---------|-------------------|
| State management | Recursive loop with state parameter |
| Request/response | `call` + `handle_call` + reply tuples |
| Fire-and-forget | `cast` + `handle_cast` |
| Message routing | Pattern matching on message tuples |
| Knowing who to reply to | `from` parameter |
| Timeout handling | Built into `GenServer.call` |
| Clean shutdown | `terminate` callback |
| Crash recovery | Supervision + `child_spec` |

### The Hidden Complexity

What GenServer abstracts away:

```elixir
# You don't write this:
def loop(state) do
  receive do
    {:call, from, ref, {:get, key}} ->
      send(from, {:reply, ref, Map.get(state, key)})
      loop(state)
    {:cast, {:put, key, value}} ->
      loop(Map.put(state, key, value))
    {:stop, reason} ->
      :ok
  after
    timeout ->
      handle_timeout(state)
  end
end

# You write this instead:
def handle_call({:get, key}, _from, state) do
  {:reply, Map.get(state, key), state}
end
```

---

## What Ruby 4.0 Ports Change

Ruby 4.0's Port model fundamentally changes the communication pattern:

### Erlang: One Mailbox, Selective Receive

```
┌─────────────────────────────────────────┐
│           Process Mailbox               │
│  ┌─────┬─────┬─────┬─────┬─────┐       │
│  │ msg │ msg │ msg │ msg │ msg │ ...   │
│  └─────┴─────┴─────┴─────┴─────┘       │
│           ↑                             │
│    Pattern match to find the right one  │
└─────────────────────────────────────────┘
```

### Ruby 4.0: Multiple Ports, Direct Receive

```
┌─────────────────────────────────────────┐
│              Ractor                     │
│                                         │
│  request_port ──→ [msg]                 │
│  event_port   ──→ [msg] [msg]           │
│  timer_port   ──→ [msg]                 │
│                                         │
│  Ractor.select(request_port, timer_port)│
│  → waits on exactly those, ignores rest │
└─────────────────────────────────────────┘
```

### Implications

| GenServer Pattern | Ruby 4.0 Port Equivalent |
|-------------------|--------------------------|
| Pattern match on message | Different Ports for different message types |
| `from` parameter | Caller provides a reply Port |
| `handle_call` vs `handle_cast` | Does caller wait on reply Port or not? |
| Selective receive | `Ractor.select` on subset of Ports |
| Timeout in receive | Timer thread sends to timeout Port |

---

## Implications for Umi

### What Umi Can Simplify

**1. No need for call/cast distinction at the protocol level**

```ruby
# Erlang/Elixir: two different message types, two different callbacks
GenServer.call(server, request)   # → handle_call
GenServer.cast(server, request)   # → handle_cast

# Ruby 4.0: same send, different client behavior
reply_port = Ractor::Port.new
server_port.send([:request, data, reply_port])
response = reply_port.receive        # ← client chooses to wait or not
```

The server doesn't need to know if the client will wait. The client decides.

**2. No `from` parameter needed**

```ruby
# Erlang: server needs `from` to know where to reply
def handle_call(request, from, state)
  GenServer.reply(from, response)

# Ruby 4.0: client provides reply destination in the message
def handle_message([:request, data, reply_port], state)
  reply_port.send(response)  # reply destination is explicit
```

**3. No central dispatch loop for message types**

```ruby
# Erlang: one receive, pattern match to dispatch
receive do
  {:call, ...} -> ...
  {:cast, ...} -> ...
  {:info, ...} -> ...
end

# Ruby 4.0: different ports for different concerns
case Ractor.select(request_port, event_port, timer_port)
in [^request_port, msg] then handle_request(msg)
in [^event_port, msg]   then handle_event(msg)
in [^timer_port, _]     then handle_timeout
end
```

**4. Natural backpressure without protocol changes**

```ruby
# If you want backpressure: wait for response
reply_port = Ractor::Port.new
server.send([:request, data, reply_port])
reply_port.receive  # ← blocks until server responds

# If you don't need it: don't wait
server.send([:notify, data, nil])
# continue immediately
```

### What Umi Should Keep

**1. The layered architecture** - Core/Boundary separation is principled
**2. Supervision** - Still needed for crash recovery
**3. API layer** - Still valuable for hiding internal protocol
**4. Backpressure awareness** - The principle remains, implementation differs

### A Potential Umi::Worker Pattern

```ruby
class Umi::Worker
  def initialize
    @command_port = Ractor::Port.new
    @ractor = Ractor.new(@command_port) do |cmd_port|
      state = init_state
      loop do
        msg = cmd_port.receive
        case msg
        in [:request, data, reply_port]
          result, state = handle_request(data, state)
          reply_port&.send(result)
        in [:shutdown, reply_port]
          cleanup(state)
          reply_port&.send(:ok)
          break
        end
      end
    end
  end

  # API layer
  def request(data, timeout: 5.0)
    reply_port = Ractor::Port.new
    @command_port.send([:request, data, reply_port])

    timer_port = Ractor::Port.new
    Thread.new { sleep(timeout); timer_port.send(:timeout) rescue nil }

    case Ractor.select(reply_port, timer_port)
    in [^reply_port, result] then [:ok, result]
    in [^timer_port, _]      then [:error, :timeout]
    end
  end

  def notify(data)  # fire-and-forget
    @command_port.send([:request, data, nil])
    :ok
  end
end
```

Note what's simpler:
- No `handle_call` vs `handle_cast` - same handler, different client behavior
- No `from` in handler - reply port is in the message
- No selective receive - one port for commands
- Timeout is explicit in API, not hidden in protocol

### The Deeper Simplification

The book emphasizes that boundaries are "optional impure integration code." With
Ruby 4.0 Ports, the boundary layer can be thinner because:

1. **Message routing is structural, not pattern-based** - Different ports for
   different message types, rather than different clauses for different patterns

2. **Reply-to is explicit, not implicit** - The caller provides the reply port,
   making the communication pattern obvious in the message itself

3. **Backpressure is a client choice, not a protocol choice** - The same server
   can serve clients that wait (backpressure) and clients that don't (async),
   without different message types

4. **Timeouts are composable** - Using `Ractor.select` with a timer port,
   timeouts become a pattern you compose, not a feature you configure

---

## Key Takeaways

### From the Book (Principled)

1. **Separate pure logic from process machinery** - The core should be testable
   without processes

2. **Prefer call over cast for backpressure** - Let clients only send as fast as
   the server can handle

3. **API layer hides protocol** - Don't leak message formats to callers

4. **Validation at the boundary** - Keep the core clean, validate at edges

5. **Processes for specific needs** - State sharing, external services, side
   effects, monitoring, isolation

### For Umi (Opportunities)

1. **Simpler request/response** - No call/cast distinction needed in protocol

2. **Explicit reply routing** - Reply port in message, not implicit `from`

3. **Structural message routing** - Different ports, not pattern matching

4. **Composable timeouts** - Timer port pattern, not built-in timeouts

5. **Keep the principles, simplify the mechanisms** - Same goals, cleaner
   implementation

---

## Source

*Designing Elixir Systems with OTP* by James Edward Gray II and Bruce Tate
(Pragmatic Bookshelf, 2019)

Key chapters referenced:
- Chapter 6: Isolate Process Machinery in a Boundary
- Chapter 7: Customize Your Lifecycle
- Chapter 8: Summon Your Workers
- Section: "Prefer Call Over Cast to Provide Back Pressure"
