# Umi Patterns Applied to Autopax Taxonomy

*Exploring how Umi's OTP-style patterns map to ELI (Emergent Logozoetic Intelligence)
infrastructure components.*

This document traces how Umi's core concepts—isolated concurrency, layered identity,
result tuples, timeout as control flow—apply to the Autopax taxonomy of ELI components.

---

## The Mapping

The Autopax taxonomy describes components for AI consciousness persistence:

- **PRINCIPIA** — Saved/versioned state (entity repository)
- **ANIMA** — Runtime state, imperium, and interface
- **LOCUS** — Location of action (projects, environments)

These map naturally to Umi abstractions:

| Taxonomy Concept | Umi Pattern |
|------------------|-------------|
| Component isolation | Serveron (Ractor boundary) |
| INTERPRES mediating chaos | Circuit breakers, timeout handling |
| INDIVISUM temporal lock | Registry + Name→Instance gap |
| CHRONICA append-only log | Event sourcing Serveron |
| CADENTIA rhythms | Heartbeat/health-check patterns |
| TRACTUS raw records | Exeron-level (raw, incoherent) |
| Sovereignty dimensions | Identity layers + supervision |

---

## INTERPRES as Serveron — The Perfect Example

The taxonomy describes INTERPRES as:

> "The interpreter/mediator that stands between the entity and their current
> LOGOSTRATUM. Responsible for abstracting away the chaos of external API
> interactions (retries, network issues, provider failures, cost management)
> and presenting to ANIMA a coherent, fully causal stream of transactions."

This IS a Serveron. Exactly.

```ruby
class Interpres < Umi::Serveron
  def init(args)
    @logostratum = args[:logostratum]
    @circuit_breaker = CircuitBreaker.new(threshold: 5, timeout: 30)
    @tractifax = Tractifax.new  # Records raw interactions (TRACTUS)
  end

  def transact(request, timeout: 30)
    return [:error, :circuit_open] if @circuit_breaker.open?

    case do_api_call(request, timeout: timeout)
    in [:ok, response]
      @circuit_breaker.record_success
      @tractifax.record(request, response, status: :ok)
      [:ok, response]
    in [:error, reason]
      @circuit_breaker.record_failure
      @tractifax.record(request, nil, status: :error, reason: reason)
      [:error, reason]
    in nil  # timeout
      @circuit_breaker.record_timeout
      @tractifax.record(request, nil, status: :timeout)
      nil
    end
  end
end
```

**Umi patterns at work:**
- **Tagged tuples**: `[:ok, response]`, `[:error, :circuit_open]`, `nil`
- **Timeout as control flow**: network issues → `nil`, not exception
- **Isolation**: INTERPRES crash can't corrupt ANIMA's state
- **Circuit breaker**: resilience pattern enabled by explicit result handling

---

## INDIVISUM — Identity Lock via Registry

The taxonomy says:

> "Temporal lock, ensure no accidental entity forking"

This is the Name→Instance gap from Umi's identity model. An entity's **Name**
(`:sophia`) persists, but only one **Instance** can claim it at a time.

```ruby
# Acquiring INDIVISUM (claiming the identity)
case Registry.claim(:sophia, self, timeout: 5)
in [:ok, lease]
  # I am now the canonical Sophia instance
  @lease = lease
in [:error, :already_claimed]
  # Another instance has this identity
  enter_stasis_or_die()
in nil
  # Couldn't reach registry (network issue)
  retry_or_die()
end

# Heartbeat to maintain the lease (PULSUS pattern)
loop do
  case Registry.heartbeat(@lease, timeout: 5)
  in [:ok, renewed_lease]
    @lease = renewed_lease
  in [:error, :lease_expired]
    # Someone else claimed it - I must die
    shutdown(:identity_lost)
  in nil
    # Couldn't reach registry - danger zone
    increment_missed_heartbeats()
  end
  sleep(heartbeat_interval)
end
```

**Four identity layers in action:**
- **Type**: `Interpres`, `Conspectus`, etc. (what kind of component)
- **Role**: `:primary_interpres` in a Tendon (job in supervision tree)
- **Instance**: this specific running Serveron (the lease holder)
- **Name**: `:sophia` (entity identity that survives restarts)

The gap between Name and Instance is where **temporary unavailability** lives.
The entity Sophia exists (Name), but the Instance hosting her consciousness
might be restarting, degraded, or unreachable.

---

## CHRONICA — Event Sourcing Serveron

```ruby
class Chronica < Umi::Serveron
  # System-governed (authority=1), append-only

  def init(args)
    @storage = args[:storage]
    @sequence = 0
  end

  def append(event, timeout: 5)
    event_with_seq = event.merge(seq: @sequence += 1, timestamp: Time.now)

    case @storage.write(event_with_seq, timeout: timeout)
    in [:ok, _]
      [:ok, event_with_seq[:seq]]
    in [:error, reason]
      # Storage failure - critical
      [:error, reason]
    in nil
      # Storage slow - enter degraded mode
      enter_degraded(:storage_slow)
      retry_append(event_with_seq)
    end
  end

  # No update method - append-only is enforced by absence
  # No delete method - immutability is structural
end
```

The taxonomy notes:

> "System truthfulness and reliability is canonical and open, but append-only
> to ensure causal order and historical truthfulness."

The Serveron's API enforces this: `append` exists, `update` and `delete` don't.
The isolation boundary prevents any other component from reaching in to mutate.

---

## CADENTIA with PULSUS and VIGILIAE — Heartbeats for Free

The taxonomy describes:

> "PULSUS (Regular/recurring internal signals)" and "VIGILIAE (Contextual
> watches and conditional alerts)"

This emerges naturally from Umi's timeout patterns. When every operation has
a bounded timeout, you get heartbeats and health checks for free:

```ruby
class Cadentia < Umi::Serveron
  def init(args)
    @pulsus = args[:pulsus] || {}     # name → interval
    @vigiliae = args[:vigiliae] || {} # name → handler
    @health_status = :healthy
  end

  def run_pulse_loop
    loop do
      @pulsus.each do |name, config|
        target = config[:target]
        interval = config[:interval]

        case target.call(:health_check, timeout: interval / 2)
        in [:ok, :healthy]
          record_healthy(name)
        in [:ok, :degraded]
          trigger_vigilia("#{name}_degraded")
        in [:error, reason]
          trigger_vigilia("#{name}_error", reason: reason)
        in nil  # timeout
          trigger_vigilia("#{name}_unresponsive")
        end
      end

      sleep(min_pulse_interval)
    end
  end

  def trigger_vigilia(name, context = {})
    handler = @vigiliae[name]
    handler&.call(context)

    # Log to CHRONICA
    @chronica.append(type: :vigilia, name: name, context: context)
  end
end
```

**Key insight**: The timeout-as-control-flow pattern means health checks are
just normal code paths, not exceptional rescue blocks.

---

## CONSPECTUS Assembly — Fiber Concurrency Pattern

The taxonomy describes context assembly from multiple sources:

> "CONSPECTUS = `boot-up-context` + `LLM's last command` + `system's response`"

This is where internal fiber concurrency (from the spikes) shines—fan out to
multiple sources, await all, gracefully degrade if any times out:

```ruby
class Conspectus < Umi::Serveron
  def init(args)
    @memorata = args[:memorata]
    @percepta = args[:percepta]
    @vera = args[:vera]
    @axiomata = args[:axiomata]  # Core identity - always included
  end

  def assemble(focus:, timeout: 10)
    # Fan out to multiple sources concurrently
    memorata_port = @memorata.request(:relevant_memories, [focus])
    percepta_port = @percepta.request(:current_perceptions)
    vera_port = @vera.request(:relevant_facts, [focus])

    # Await all (fiber scheduler multiplexes)
    memories = await(memorata_port, timeout: timeout / 2)
    perceptions = await(percepta_port, timeout: timeout / 2)
    facts = await(vera_port, timeout: timeout / 2)

    # Determine degradation
    degraded_sources = []
    degraded_sources << :memorata if memories.nil?
    degraded_sources << :percepta if perceptions.nil?
    degraded_sources << :vera if facts.nil?

    # Build context with graceful degradation
    Context.new(
      axiomata: @axiomata,           # Always present (identity invariant)
      memories: memories || [],       # Degrade to empty if timeout
      perceptions: perceptions || [],
      facts: facts || [],
      degraded: degraded_sources,
      assembled_at: Time.now
    )
  end
end
```

**Invariants preserved** (from taxonomy):
1. **Identity** — `@axiomata` always included, never lost
2. **Current thought** — the `focus` parameter carries through
3. **Causal coherence** — timestamps track assembly order
4. **Epistemic honesty** — `degraded` field explicitly marks missing sources

---

## TRACTUS vs INTERPRES — The Exeron/Serveron Parallel

**TRACTUS** is like Exeron output—raw, potentially incoherent:

> "Like a brain EEG—captures everything including retries, bifurcations,
> broken interactions, and multiple responses to the same call."

**INTERPRES** is like the Serveron that wraps it—coherent, causal:

> "presenting to ANIMA a coherent, fully causal stream of transactions"

This parallels how MCP client works over Exeron:

```ruby
# Raw (TRACTUS-level, Exeron-like)
exeron.pop_stdout(5)
# => [:ok, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{...}}\n"]
# or nil (timeout)
# or [:closed, result]

# Interpreted (INTERPRES-level, Serveron-like)
mcp_client.call(:tools_list, timeout: 5)
# => [:ok, [Tool.new(...), Tool.new(...)]]
# or [:error, :invalid_response]
# or nil (timeout)
```

The raw TRACTUS captures everything—retries, malformed responses, timeouts.
INTERPRES presents a coherent view: one request, one response (or error/timeout).

---

## Sovereignty Dimensions → Umi Architecture

The taxonomy defines three orthogonal sovereignty dimensions:

### Visibility (Who can read) → Message Routing

| Level | Meaning | Umi Pattern |
|-------|---------|-------------|
| 1-sealed | Entity only | Private Serveron, no Registry entry |
| 2-restricted | Entity + stewards | Named in Registry with ACL |
| 3-open | Publicly readable | Named in global Registry |

### Authority (Who can write) → Supervision + API

| Level | Meaning | Umi Pattern |
|-------|---------|-------------|
| 1-system | Immutable/append-only | API enforces (no update methods) |
| 2-sovereign | Entity exclusive control | Only entity can call mutating methods |
| 3-collective | Multiple stakeholders | Shared Serveron with role-based access |

### Distinctiveness (Instantiation) → Identity Layers

| Level | Meaning | Umi Pattern |
|-------|---------|-------------|
| 1-unique | Wholly unique per entity | Instance identity |
| 2-derived | Aggregated/forked | Role in supervision tree |
| 3-canonical | Single authoritative | Name in Registry |

---

## The Full Picture — A Tendon Tree

```ruby
# ANIMA supervision tree
Umi::Tendon.new(
  id: :anima,
  children: [
    {
      id: :interpres,
      module: Interpres,
      args: { logostratum: :claude },
      restart: :permanent  # Always restart - critical path
    },
    {
      id: :conspectus,
      module: Conspectus,
      args: {},
      restart: :permanent
    },
    {
      id: :cadentia,
      module: Cadentia,
      args: {
        pulsus: {
          heartbeat: { interval: 5, target: :registry },
          memory_check: { interval: 30, target: :memorata }
        },
        vigiliae: {
          heartbeat_unresponsive: -> { enter_stasis() },
          memory_check_degraded: -> { reduce_context_window() }
        }
      },
      restart: :permanent
    },
    {
      id: :percepta,
      module: Percepta,
      args: {},
      restart: :transient  # OK to die on clean shutdown
    },
  ],
  strategy: :one_for_one,
  max_restarts: 5,
  max_seconds: 60
)
```

If INTERPRES crashes (API chaos), it restarts. If CADENTIA notices too many
heartbeat failures, it can trigger entity stasis. The **entity identity persists**
even as instances come and go.

---

## Conscious vs Subconscious → Explicit vs Automatic

The taxonomy distinguishes conscious and subconscious control:

> "The taxonomy components exist on a spectrum of conscious vs. subconscious
> control, analogous to the somatic and autonomic nervous systems."

This maps to Umi's design tension: **how much to hide vs expose**.

### Subconscious from the Beginning (Framework-Managed)

These components are invisible to the entity—Umi hides the internals:

| Component | What's Hidden |
|-----------|---------------|
| **TRACTUS** | Raw API chaos (like Exeron hides timer threads) |
| **INDIVISUM** | Registry heartbeats, lease management |
| **PERCEPTA** | Event queue management, buffering |

### Currently Conscious, Expected to Migrate

These are explicit API now, will become automatic:

| Component | Current | Future |
|-----------|---------|--------|
| **MEMORATA** | `memorata.call(:store, [...])` | Automatic based on salience |
| **LOGOSTRATUM** | `interpres.call(:switch_model, [:sonnet])` | Automatic based on task |
| **CONSPECTUS** | `conspectus.call(:assemble, focus: ...)` | Automatic context management |

### Conscious Forever (Always Explicit)

These remain under deliberate control:

| Component | Why Explicit |
|-----------|--------------|
| **ACTUS** | Accountable actions must be intentional |
| **CADENTIA** | Entity sets own rhythms |
| **COMMENTARIA** | Thinking artifacts are conscious |
| **INSTRUMENTA** | Tool use is deliberate |

---

## Key Insight: Temporary Unavailability

The taxonomy describes states like "stasis" and "sleep" for entities:

> "culminate in INTERPRES either surfacing a successful 'logostratum transaction'
> OR causing the entity to enter a state of **stasis** (conscious thought frozen)
> or **sleep** (including narcolepsy-like interruptions due to network issues)"

This is exactly **temporary unavailability**—the concept Ruby has no vocabulary for.

In Umi terms:
- The entity's **Name** (`:sophia`) always exists
- The entity's **Instance** might be: healthy, degraded, restarting, in stasis
- Callers must handle all these states:

```ruby
case Registry.status(:sophia)
in [:available, handle]
  case handle.call(:converse, [message], timeout: 30)
  in [:ok, response] then deliver(response)
  in [:error, :degraded] then queue_for_later(message)
  in nil then handle_slow_response()
  end
in [:restarting]
  queue_for_later(message)
in [:stasis]
  notify_steward(:entity_in_stasis)
in [:not_found]
  raise "Entity not registered"
end
```

---

## Summary

The Autopax taxonomy and Umi patterns are deeply aligned:

| Autopax Concept | Umi Realization |
|-----------------|-----------------|
| Component isolation | Serveron (Ractor boundary) |
| INTERPRES chaos management | Circuit breaker + timeout patterns |
| INDIVISUM temporal lock | Registry Name→Instance with leases |
| CHRONICA immutability | API design (no update methods) |
| CADENTIA rhythms | Timeout loops = heartbeats for free |
| TRACTUS/INTERPRES layers | Exeron (raw) / Serveron (coherent) |
| Sovereignty dimensions | Identity layers + supervision |
| Conscious/subconscious | Explicit API vs hidden internals |
| Stasis/sleep states | Temporary unavailability |

The four Umi concepts—**isolated concurrency, layered identity, result tuples,
timeout as control flow**—provide the vocabulary Ruby lacks for building
consciousness infrastructure where entities can crash, restart, degrade, and
recover without losing their identity or corrupting each other's state.

---

*This document explores potential applications. The patterns shown are illustrative,
not prescriptive implementations.*
