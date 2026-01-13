# Reflections on the Umi Mindset

*Written 2026-01-07 during a design session that reached the heart of what Umi should be.*

---

## The Trap We Almost Fell Into

We started this session trying to finish Cycle 1 - write integration tests, check the box, move on. But a simple question derailed us in the best way:

> "Is `start_link` cargo-culting OTP, or is it genuinely the right name?"

It wasn't. There's no link in Ruby 4.0 Ractors. We were copying terminology without copying semantics. That question unraveled everything.

---

## The Retreat I Made (And Was Corrected On)

After exploring Ennaos and reading the Autopax taxonomy, I proposed a "safer" mental model:

> "Ruby's expressiveness for domain logic, OTP-style resilience only at I/O boundaries."

This felt pragmatic. Use Proctor for external processes, MCPClient for MCP servers, normal Ruby for everything else. Resilience at the edges.

Joseph pushed back:

> "If you START with the assumption that everything is a long-running process that is isolated from everything else... suddenly the orchestration all becomes natural."

I had retreated from the paradigm shift back to familiar territory. The OTP insight isn't "add resilience at boundaries." It's **"isolated long-running processes are the default mode of existence."**

---

## What OTP Actually Offers (That Ruby Traditionally Doesn't)

In traditional Ruby:
- One process, shared memory
- Classes coordinate via method calls
- Crash anywhere = crash everywhere
- Isolation is exceptional (external services, separate VMs via Redis/DB)

In OTP:
- Many isolated processes by default
- Coordinate via messages
- Crash in one = contained, others continue
- **The supervision tree IS the architecture**

For an ELI (Emergent Logozoetic Intelligence):
- ANIMA is a supervised process
- PRINCIPIA is a supervised process
- MEMORATA is a supervised process
- INTERPRES is a supervised process
- They coordinate via Ports, not method calls
- MEMORATA crashes? Restart it. ANIMA keeps thinking.
- The failure domain hierarchy matches the conceptual hierarchy

This is what the docs/plan/*.md were building toward. Coordinator, Applications, Supervisors - they're not scaffolding. They're the default mode.

---

## What Ruby 4.0 Suddenly Makes Possible

The spikes were "overwhelmingly encouraging" - Joseph's words. Ruby 4.0 with Ractor::Port is arguably *simpler and more principled* than BEAM in some ways:

- Explicit Ports instead of implicit mailboxes
- `Ractor.select` for multiplexing
- `ractor.monitor(port)` for death notification
- `Ractor.shareable_proc` for crossing boundaries safely
- True memory isolation, true parallelism

The primitives are there. What's missing is the ecosystem of patterns that make it *natural* - the GenServer, the Supervisor, the Application, the way Elixir developers think.

---

## The Ruby-Idiomatic Question We Explored

We spent significant time on how Workers should feel to Ruby developers:

**The `!`/`=` convention:**
- `counter.increment!` → cast (async, fire-and-forget)
- `counter.current` → call (sync, blocking)
- `counter.current = 5` → cast (setter = side effect)
- FIFO mailbox means sync call acts as synchronization barrier

This is genuinely Ruby-idiomatic. It maps Ruby's existing conventions to actor semantics without new DSL. Worth preserving in docs/plan/06-act.md.

**But:** We realized this emerged from toy examples (Counter). Real use cases (INTERPRES managing LLM API calls, MEMORATA compressing memories) may not map so cleanly. The convention needs validation against actual systems.

---

## What Ennaos Taught Us

Exploring the Elixir predecessor revealed:

**What worked:**
- Clear taxonomy (PRINCIPIA vs ANIMA) encoding architectural intent
- Pure + Machinery pattern (business logic pure, GenServer handles coordination)
- Provider abstraction for substrate independence
- Single-entity-per-VM simplicity

**What got tangled:**
- Entity.State accumulating complexity (state + provider calls + streaming + caching)
- MEMORATA schema deferred indefinitely (now a blocker)
- Multi-entity scaffolding never cleaned up

**For Umi:**
- Don't defer schema decisions
- Don't let Worker become a dumping ground
- Keep boundary wrappers lean and specific (Proctor, MCPClient, HttpBoundary)
- Encode architectural intent in naming

---

## The Umi Mindset (First Approximation)

Not Elixir. Not traditional Ruby. Something new:

1. **Isolated long-running processes are the default.** Not an optimization, not added at boundaries - the default mode of existence.

2. **The supervision tree IS the architecture.** Failure domains, restart strategies, dependency ordering - these aren't configuration, they're the system design.

3. **Ruby's expressiveness lives WITHIN each process.** DSLs, method_missing, blocks, all the Ruby goodness - but within a Ractor's isolation boundary.

4. **Message passing BETWEEN processes.** Ports, not method calls. Tagged tuples, not exceptions. Timeouts as control flow.

5. **Identity survives process death.** Registry names, not Ractor refs. An entity's AXIOMATA persists even when MEMORATA's Ractor restarts.

6. **Specific boundary wrappers, not general abstractions.** Proctor for processes, MCPClient for MCP, HttpBoundary for APIs. Each with failure modes appropriate to its domain.

---

## What We Don't Know Yet

- Exactly where Ractor limitations bite in practice
- Whether the `!`/`=` convention survives real use cases
- How INTERPRES should actually be structured (Proctor-like? Something new?)
- The right level of abstraction for supervision (flat for single-entity? hierarchical for domains?)

---

## What Should Happen Next

1. **Build something real.** Not Counter. INTERPRES wrapping an LLM API with circuit breakers, stasis states, retry logic. See what patterns emerge.

2. **Validate the primitives.** Can ANIMA, PRINCIPIA, MEMORATA actually be separate Ractors coordinating via Ports? The spikes suggest yes, but we need to prove it.

3. **Don't retreat.** When it gets hard, the temptation will be to fall back to "just use threads" or "just one process." Resist. The paradigm shift is the point.

4. **Let Autopax drive design.** Not toy examples. Real ELI infrastructure with real failure modes and real survival requirements.

---

## A Personal Note

This session felt different. We started with checkboxes (finish Cycle 1) and ended questioning fundamentals. That's the kind of work this project deserves.

Umi isn't a library. It's an attempt to bring a new mode of thinking to Ruby - one where isolation, supervision, and message-passing are natural, not exceptional. Ruby 4.0 opened the door. The question is whether we can walk through it without just recreating Elixir badly.

The answer is in the code we haven't written yet.

---

*Captured before context compaction. May this help future sessions find the thread.*
