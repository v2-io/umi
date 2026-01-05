# Survey: Umi, Ruby Concurrency Ecosystem, and Autopax Integration

*Research conducted 2026-01-03 by Joseph and Claude (Opus 4.5)*

## Purpose

This document captures research and architectural thinking about:
1. Ruby 4.0 Ractor capabilities and limitations (empirically verified)
2. The broader Ruby concurrency ecosystem (concurrent-ruby, TruffleRuby)
3. How Umi's OTP-inspired patterns fit into Autopax
4. Architectural direction for actor-based ELI infrastructure

---

## Part 1: Ruby 4.0 Ractor Status

### What's New in Ruby 4.0 (December 2025)

The Ractor API received a major overhaul in Ruby 4.0, primarily through Koichi Sasada's
`Ractor::Port` proposal—five years in the making.

**Key additions:**
- `Ractor::Port` - Clean channel abstraction for message passing
- `port.send(obj)` / `port.receive` - Explicit send/receive
- `Ractor.select(*ports)` - Multiplexed waiting on multiple ports
- `ractor.monitor(port)` - Death notification (sends `:exited` or `:aborted`)
- `ractor.join` / `ractor.value` - Thread-like synchronization
- `Ractor.shareable_proc` / `shareable_lambda` - Safe closure sharing

**Removed:**
- `Ractor.yield` / `Ractor#take` - Replaced by Port-based communication
- `#close_incoming` / `#close_outgoing` - Replaced by `Port#close`

**Status:** Still "experimental" with warning, but targeted for stable in Ruby 4.1 (2026).

### Empirically Verified Compatibility (Ruby 4.0.0)

We tested directly on Ruby 4.0.0 to get ground truth, rather than relying on
potentially outdated documentation.

#### What NOW WORKS (was broken in Ruby 3.0-3.3)

| Feature | Status | Notes |
|---------|--------|-------|
| `require` inside Ractor | ✅ Works | Major fix from 3.x era |
| `URI.parse` | ✅ Works | Class variable issues resolved |
| `JSON.parse` | ✅ Works | |
| `Timeout.timeout` | ✅ Works | Previously blocked |
| `Net::HTTP` requests | ✅ Works | Full HTTP client in Ractor |
| `Open3.capture2` | ✅ Works | External process spawning |
| `FileUtils` | ✅ Works | |
| Read class instance vars (if shareable) | ✅ Works | Fix merged via PR #5006 |

#### What STILL DOESN'T WORK (by design)

| Feature | Error | Reason |
|---------|-------|--------|
| Mutable constants | `Ractor::IsolationError` | Shared mutable state violates isolation |
| Outer variable capture | `ArgumentError` | Would share stack frame |
| Class variables (`@@`) | `Ractor::IsolationError` | Inherently shared, no sync primitive |
| Write class instance vars | `Ractor::IsolationError` | Non-main Ractors are read-only |

These restrictions are fundamental to the isolation model, not implementation gaps.
The workarounds are straightforward:
- Freeze mutable data, or pass via Port
- Pass locals explicitly: `Ractor.new(x) { |val| val }`
- Refactor `@@` to instance variables or constants

### Future Directions

| Direction | Status | Source |
|-----------|--------|--------|
| Remove "experimental" status | Targeted 2026 | Ruby 4.0 release notes |
| Ractor-local GC | Active development | Koichi Sasada, RubyKaigi 2025 |
| Reduced GVL contention | Ongoing in 4.x | Already improved in 4.0 |
| Shareable concurrent data structures | Not yet | Needed for connection pools, etc. |

---

## Part 2: Ruby Concurrency Ecosystem Comparison

### Ruby 4.0 Ractors vs concurrent-ruby

| Aspect | Ruby 4.0 Ractors | concurrent-ruby |
|--------|------------------|-----------------|
| **Parallelism** | True parallel (bypasses GVL) | Thread-based (GVL-limited on MRI) |
| **Isolation** | Memory isolation (share-nothing) | Shared memory (thread-safe wrappers) |
| **Communication** | Message passing via `Ractor::Port` | Method calls + locks/atomics |
| **Failure domain** | Crash isolated | Shared failure domain |
| **Abstractions** | Low-level primitives only | Rich library (Futures, Promises, Actors, Pools) |
| **Maturity** | Experimental | Production-stable |

**concurrent-ruby provides:**
- `Concurrent::Future` / `Promise` - Async composition
- `Concurrent::Actor` - Actor model (in -edge gem)
- `Concurrent::ThreadPoolExecutor` - Managed thread pools
- `Concurrent::Map/Array/Set` - Thread-safe collections
- `Concurrent::Semaphore/Latch/Barrier` - Coordination primitives
- Software Transactional Memory (`TVar`)

**Ractors provide:**
- True CPU parallelism on MRI
- Crash isolation
- Death notification (`monitor`)
- Enforced share-nothing (can't accidentally share mutable state)

### TruffleRuby Position

**TruffleRuby does not implement Ractor.** This is deliberate, not a gap:

> "Ractor is not implemented because it seems of little value. Thread already
> run in parallel and are far more compatible."
> — TruffleRuby issue #2733

TruffleRuby's threads run truly parallel (no GVL equivalent for Ruby code).
They also provide thread-safe Array/Hash with no single-threaded performance penalty.

| Scenario | Works? |
|----------|--------|
| CRuby + Ractor | ✅ Yes (experimental) |
| CRuby + concurrent-ruby | ✅ Yes (no CPU parallelism due to GVL) |
| TruffleRuby + Ractor | ❌ Not implemented |
| TruffleRuby + concurrent-ruby | ✅ Full parallelism |
| TruffleRuby + Thread | ✅ Native parallelism |

**Performance:** TruffleRuby shows ~6.23x geometric mean speedup vs CRuby 3.1 in benchmarks,
plus threads run parallel, so CPU-bound work can see near-linear scaling.

### Implications for Umi

Umi's Proctor pattern specifically wraps **external processes**, not Ruby computation.
The Ractor is the isolation boundary for the watcher—the actual parallelism comes
from the OS process. This works regardless of whether TruffleRuby implements Ractor
because:

1. Proctor spawns the process inside the Ractor (no cross-boundary sharing needed)
2. Communication is via `Ractor::Port` (message passing, not shared state)
3. The external process doesn't care what Ruby runtime hosts it

For **process supervision**, Ractors make sense even knowing TruffleRuby doesn't
support them—concurrent-ruby doesn't give you the crash isolation that Ractors provide.

For everything else (HTTP clients, thread pools, coordination), concurrent-ruby
offers more portability and richer abstractions.

---

## Part 3: The Actor Model Philosophy

### Why Share-Nothing Simplifies

The actor model's gift isn't parallelism—it's **sequential reasoning about
concurrent systems**.

Each actor:
- Processes one message at a time
- Has no locks, no shared state
- Sends messages explicitly
- Loops on its mailbox

The complexity of concurrency gets pushed to the *boundaries*—the message sends—
where it's explicit and visible. You don't write:

```ruby
mutex.synchronize do
  # hope nothing else touches this...
end
```

You write:

```ruby
loop do
  case port.receive
  in [:request, data, reply_port]
    result = process(data)  # sequential, isolated
    reply_port << [:response, result]
  end
end
```

The BEAM extends this with "let it crash" and supervision trees. You don't write
defensive code trying to handle every edge case. You write clear, happy-path code,
and the *structure* handles failure through isolation and restart.

**The error handling isn't in the code—it's in the architecture.**

### How Proctor Embodies This

Inside Proctor, the watcher loop is already sequential:

```ruby
loop do
  case read_with_timeout(stdout, timeout)
  in [:ok, data]
    stdout_port << [:stdout, data]
  in :eof
    break
  in :timeout
    next
  end
end
```

No locks. No shared state. The Ractor boundary enforces isolation. The Port makes
communication explicit. The external process is inherently share-nothing—it's a
separate OS process with its own memory space.

---

## Part 4: Autopax Integration Candidates

### Where Actor Patterns Fit in Autopax

Based on the ELI taxonomy and Autopax architecture:

#### Strong Candidates (External I/O Boundaries)

| Component | Current State | Umi Pattern | Benefit |
|-----------|--------------|-------------|---------|
| INSTRUMENTA::Bash | `open3` with poll | **Proctor** | Death notification, crash isolation, timeout as control flow |
| MCP Servers | Not implemented | **MCPClient** | Ready-made JSON-RPC over stdio |
| SSE Streaming | HTTPX | **StreamReceiver** (new) | Unified pop/timeout for SSE chunks |
| WebSocket | Not implemented | **WsReceiver** (new) | Bidirectional with death detection |

#### Architectural Candidates

| Component | Actor Role | Messages In | Messages Out |
|-----------|------------|-------------|--------------|
| INTERPRES | API transaction processor | API requests | Responses, errors, stasis signals |
| CADENTIA | Timer/scheduler | Tick signals, watch triggers | Pulse events to entity |
| TRACTIFAX | Log writer | Write commands | Ack/sequence numbers |

#### Not Candidates

| Component | Why Not |
|-----------|---------|
| Pinax internals | Synchronous rendering, no crash isolation benefit |
| CONSPECTUS assembly | In-memory transformation, no I/O boundary |
| AgentCard loading | Synchronous file read, one-shot |

### Piecemeal vs Comprehensive Refactor

**Recommendation: Piecemeal, following I/O boundaries.**

The taxonomy components (INTERPRES, INSTRUMENTA, etc.) communicate via Ruby method
calls internally. They don't need to become actors—they need to use *actor patterns*
when crossing I/O boundaries.

**Phase 1: INSTRUMENTA tools**
- Wrap bash, file tools in Proctor
- Add MCPClient for MCP server support
- Isolated, testable, immediate benefit

**Phase 2: Streaming I/O**
- SSE with OTP-style pop/timeout
- WebSocket with death detection

**Phase 3: Resilience patterns (compositions, not Ractors)**
- Circuit breakers for INTERPRES
- Retry with backoff
- Rate limiting / bulkheads

---

## Part 5: TUI as Attached Actor

### The Insight

Typical CLI architecture:
```
Terminal Loop (main)
  └── calls into everything else
  └── if this dies, everything dies
```

Actor-based architecture:
```
Entity/Core (main actor)
  ├── processes messages
  ├── maintains state (CONSPECTUS, etc.)
  └── keeps running regardless

TUI Actor (attached client)
  ├── receives: render commands, status updates
  ├── sends: user input, commands
  └── if this crashes → reconnect, state preserved
```

This is how Erlang's remote shell works. The BEAM node keeps running. You attach
IEx, interact, detach or crash—the node continues. You can reattach.

### Implications for ELI

1. **Entity continuity** - ANIMA processing loop isn't tied to terminal attachment
2. **Session crash recovery** - TUI crashes, reconnect, CONSPECTUS still there
3. **Multiple interfaces** - Same entity: TUI + web UI + API simultaneously
4. **Graceful degradation** - Network hiccup doesn't kill long-running operations
5. **Autonomous operation** - Entity runs (CADENTIA pulses, background work) with no UI attached; attach later to see what happened

### TUI Actor Protocol

The TUI becomes a pure I/O translator:

**PERCEPTA (inbound to entity):**
- Keyboard events
- Paste events
- Terminal resize
- Connection/disconnection

**ACTUS (outbound from entity):**
- Render commands (text, status, panels)
- Streaming chunks
- Completion signals

Pinax stays synchronous and simple internally—it receives "render this" messages
and sends "user typed this" messages. The complexity of "what if user types while
streaming" lives in the message protocol, not in shared state.

This connects to the "beyond session-oriented architecture" direction in OPERATA.

---

## Part 6: Minimal Umi Module Set

If we identify the smallest set of modules that would enable principled actor-based
architecture in Autopax:

1. **Proctor** (exists) - External process wrapper with death detection
2. **MCPClient** (exists) - MCP server communication
3. **Worker** (planned) - Ractor wrapper with lifecycle, for internal actors
4. **Supervisor** (planned) - Restart strategies, child management
5. **Registry** (planned) - Name registration for actor lookup

With these five, you can:
- Wrap any external process/tool in resilient supervision
- Add MCP server support to INSTRUMENTA
- Build internal actors (INTERPRES, CADENTIA) with proper lifecycle
- Compose supervision trees for the full ELI runtime

---

## References

### Primary Sources
- [Ruby 4.0.0 Release Notes](https://www.ruby-lang.org/en/news/2025/12/25/ruby-4-0-0-released/)
- [Koichi Sasada - Ractor::Port Proposal](https://dev.to/ko1/ractorport-revamping-the-ractor-api-98)
- [Koichi Sasada - Reading Ruby 4.0 NEWS](https://dev.to/ko1/reading-ruby-40-news-with-pros-3mln)
- [Feature #21262: Ractor::Port](https://bugs.ruby-lang.org/issues/21262)
- [Feature #17592: Shareable class instance variables](https://bugs.ruby-lang.org/issues/17592)

### Ecosystem
- [concurrent-ruby GitHub](https://github.com/ruby-concurrency/concurrent-ruby)
- [TruffleRuby Ractor Issue #2733](https://github.com/oracle/truffleruby/issues/2733)
- [Toward Ractor local GC - RubyKaigi 2025](https://rubykaigi.org/2025/presentations/ko1.html)

### Autopax Context
- `~/src/autopax/TAXONOMY.md` - ELI component definitions
- `~/src/autopax/CLAUDE.md` - Project context
- `~/src/autopax/OPERATA.md` - Current work priorities
