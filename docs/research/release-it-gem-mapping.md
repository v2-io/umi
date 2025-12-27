# Release It! Patterns vs Ruby Gem Ecosystem

**Date:** 2025-12-27
**Purpose:** Map Nygard's stability patterns/antipatterns against observations
from 22 Ruby gems, and identify which patterns are in Kozo's scope.

---

## Part 1: The Antipatterns

### Integration Points

**The Problem:** Every socket, process, pipe, or remote procedure call can hang.
Integration points are "the number-one killer of systems." Failures take many forms:
connection refused, slow responses, malformed responses, protocol violations.

**Gems Observed:**
- All 22 gems deal with integration points (that's what they're for)
- Faraday/HTTParty/Excon are integration point abstractions themselves
- None of the gems explicitly warn callers about integration point risks

**Kozo Scope:** Core. Kozo exists precisely to address integration point problems.

---

### Chain Reactions

**The Problem:** When one server in a horizontally scaled layer fails, remaining
servers pick up the slack. Increased load makes them more likely to fail.
Accelerating cascade until entire layer goes down.

**Gems Observed:**
- 0 of 22 gems address this (it's a deployment/orchestration concern)
- Sidekiq's supervisor pattern replaces dead processors, which is related

**Kozo Scope:** Out of scope. This is a scaling/deployment concern, not HTTP client behavior.

---

### Cascading Failures

**The Problem:** Failure in one layer triggers failure in calling layers.
Usually via blocked threads, resource pool exhaustion, or excessive retrying.

**Gems Observed:**
- 0 of 22 gems explicitly prevent cascading failures
- AWS SDK's retry quota prevents unlimited retry amplification
- Sentry/NewRelic/Rollbar are designed to never cascade into host app

**Kozo Scope:** Core. Kozo can prevent cascading by:
- Circuit breakers to stop calling failed services
- Deadlines to prevent indefinite blocking
- Retry budgets to prevent amplification

---

### Blocked Threads

**The Problem:** Threads blocked on integration points, resource pools, or locks.
"The proximate cause of most failures." System appears running but does nothing.

**Gems Observed:**
- Faraday/HTTParty/Excon: Timeout options exist but not enforced by default
- Redis-rb: Uses Monitor (reentrant mutex) for thread safety
- Elasticsearch: Per-connection mutex for state changes
- Stripe: 120s idle timeout on connection manager

**What default timeout behavior looks like:**

| Gem | Default Connect Timeout | Default Read Timeout |
|-----|------------------------|---------------------|
| Faraday | nil (system default) | nil (system default) |
| HTTParty | nil | nil |
| Excon | 60 | 60 |
| Stripe | 30 | 80 |
| Octokit | via Faraday (nil) | via Faraday (nil) |

**Kozo Scope:** Core. Kozo should:
- Require timeouts (no nil/infinite defaults)
- Enforce overall deadlines
- Never allow indefinite blocking

---

### Slow Responses

**The Problem:** "Slow response is worse than no response." Ties up resources
in both caller and callee. Triggers cascading failures upward.

**Gems Observed:**
- OpenAI/Anthropic SDKs: 600s default timeout (10 minutes!)
- Most gems: No responsiveness monitoring
- Sentry: Has backpressure monitoring with downsample factor

**Kozo Scope:** Core. Kozo should:
- Track response time percentiles
- Detect degradation before timeout
- Potentially shed load or fail fast when degrading

---

### Dogpile (Thundering Herd)

**The Problem:** Synchronized load spikes from server restarts, cron jobs,
cache expiration, or retry waves. Concentrates demand beyond capacity.

**Gems Observed:**
- Sidekiq: `rand(10 * (count + 1))` jitter - explicitly "essential"
- Stripe: 50-100% jitter on retry delay
- AWS SDK: Three jitter modes (EQUAL, FULL, NONE)
- 6 of 22 gems with retry include jitter
- 5 of 11 gems with retry DO NOT include jitter

**Kozo Scope:** Core. Kozo should:
- Always include jitter in retry/backoff
- Document why (prevent thundering herd)

---

### Unbalanced Capacities

**The Problem:** Front-end can generate more load than back-end can handle.
Traffic pattern changes can suddenly flood back-end services.

**Gems Observed:**
- Rate limit header parsing: 3 of 22 gems (Sentry, Octokit, Stripe)
- Preemptive slowdown: 0 of 22 gems
- AWS SDK: Has RetryCapacityNotAvailableError when budget exhausted

**Kozo Scope:** Partially in scope. Kozo can help callers by:
- Parsing rate limit headers
- Preemptive slowdown before hitting limits
- Retry budgets to prevent overwhelming backends

---

## Part 2: The Patterns

### Timeouts

**The Pattern:** "Hope is not a design method." Every call needs a timeout.
Timeouts provide fault isolation. Use at socket, pool, and application levels.

**Gems Observed:**
| Timeout Granularity | Count | Examples |
|---------------------|-------|----------|
| connect + read + write | 6 | Faraday, HTTParty, Excon, Stripe |
| Single combined timeout | 5 | AWS SDK, OpenAI/Anthropic |
| Overall deadline | 2 | Excon, OpenAI/Anthropic |
| No timeout support | 0 | (All support some form) |

**Excon's deadline approach (most sophisticated):**
```ruby
if @data.include?(:deadline)
  remaining = request_time_remaining
  timeout = [remaining, timeout].min
end
```

**Kozo Scope:** Core. Kozo should:
- Require timeout specification (no infinite waits)
- Support deadline-based timeouts (Excon pattern)
- Propagate remaining deadline to child operations

---

### Circuit Breaker

**The Pattern:** Closed → Open → Half-Open state machine. Stop calling when
failures exceed threshold. Periodically test if service recovered.

**Gems Observed:**
- Explicit circuit breaker: 0 of 22 gems
- Implicit circuit breaker behavior: 1 of 22 (Elasticsearch)

**Elasticsearch's connection health (implicit circuit breaker):**
```ruby
def dead!
  @dead = true
  @failures += 1
  @dead_since = Time.now
end

def resurrectable?
  Time.now > @dead_since + (@resurrect_timeout * 2 ** (@failures - 1))
end
```

This is circuit breaker behavior without the name:
- Failure marks connection as "dead" (circuit open)
- Exponential backoff before resurrection attempt (half-open)
- Success resets state (circuit closed)

**Kozo Scope:** Core. Kozo should provide:
- Explicit circuit breaker with closed/open/half-open states
- Leaky bucket for failure counting (fault density, not total)
- Observable state changes (for monitoring)
- Manual override capability

---

### Bulkheads

**The Pattern:** Partition capacity to preserve partial functionality.
Failure in one partition doesn't affect others.

**Gems Observed:**
- Thread pool partitioning: Sidekiq (server middleware)
- Connection pool per-client: Stripe (connection manager)
- Request isolation: Sentry (discards when queue full)

**Kozo Scope:** Partially in scope. Kozo could:
- Provide per-endpoint connection management
- Separate pools for different criticality levels
- But full bulkhead patterns may be out of scope

---

### Fail Fast

**The Pattern:** If system can determine it will fail, fail immediately.
Don't waste resources on doomed work. Check circuit breakers early.

**Gems Observed:**
- ActiveMerchant: Response object with `success?` instead of exceptions
- Faraday: Middleware position matters (auth before expensive ops)
- Sidekiq: `Handled` exception to signal "retry scheduled, not error"

**Kozo Scope:** Core. Kozo should:
- Check circuit breaker state before making calls
- Validate configuration early
- Distinguish system failures from application failures

---

### Shed Load

**The Pattern:** When overloaded, refuse new work rather than slowing down.
"You can't out-scale the world."

**Gems Observed:**
- HTTP 503 support: Most gems can return 503
- Automatic load shedding: 0 of 22 gems
- Sentry: Discards silently when queue full

**Kozo Scope:** Out of scope for client behavior. Kozo is a client library;
load shedding is a server-side concern. However, Kozo should handle 503
responses appropriately (retry with backoff, respect Retry-After).

---

### Back Pressure

**The Pattern:** When queue is full, slow down producers. Propagate pressure
upstream. Works best within system boundaries, not across the internet.

**Gems Observed:**
- Sentry: Backpressure monitoring with downsample factor
- Sidekiq: `fallback_policy: :discard` when queue full
- HTTP clients: No back pressure support

**Kozo Scope:** Limited. Back pressure is for internal systems. For HTTP
clients calling external services, load shedding (503) and rate limiting
are more appropriate than back pressure.

---

### Governor

**The Pattern:** Limit rate of actions to allow human intervention. Apply
resistance in "unsafe" directions. Time-aware and stateful.

**Gems Observed:**
- AWS SDK: Retry quota is a governor on retry rate
- Rate limiting headers: 3 of 22 gems parse them
- Preemptive slowdown: 0 of 22 gems

**Kozo Scope:** Partially in scope. Kozo could:
- Govern retry rate (via budget)
- Govern request rate (preemptive rate limiting)
- But this overlaps with circuit breaker and rate limiting

---

## Part 3: Summary - What's In Kozo's Scope

### Core Patterns (Must Address)

| Pattern | Current Gem Support | Kozo Value |
|---------|--------------------| ------------|
| **Timeouts** | 22/22 support, 2/22 have deadlines | Enforce, add deadlines |
| **Circuit Breaker** | 0/22 explicit, 1/22 implicit | New capability |
| **Retry with Jitter** | 6/22 have jitter | Standardize, require jitter |
| **Fail Fast** | 3/22 use result objects | Standardize pattern |
| **Cascading Failure Prevention** | 0/22 explicit | New capability via composition |

### Secondary Patterns (Should Address)

| Pattern | Current Gem Support | Kozo Value |
|---------|--------------------| ------------|
| **Retry Budget** | 1/22 (AWS SDK only) | New capability |
| **Rate Limit Handling** | 3/22 parse headers | Standardize, add preemption |
| **Connection Health** | 3/22 track health | Standardize state machine |

### Out of Scope (Server/Deployment Concerns)

| Pattern | Why Out of Scope |
|---------|------------------|
| Chain Reactions | Deployment/scaling concern |
| Load Shedding (server) | Kozo is a client |
| Back Pressure (internal) | For internal systems, not HTTP clients |
| Bulkheads (full) | Requires orchestration layer |

---

## Part 4: Antipatterns Kozo Addresses

| Antipattern | How Kozo Addresses |
|-------------|-------------------|
| Integration Points | Primary purpose - wrap dangerous calls |
| Cascading Failures | Circuit breaker + deadlines + retry budget |
| Blocked Threads | Required timeouts, deadlines |
| Slow Responses | Deadline tracking, fail fast |
| Dogpile | Jitter always included in retry |
| Unbalanced Capacities | Rate limit handling, retry budget |

---

## Part 5: Open Questions

1. **Where does circuit breaker live?**
   - Per-host? Per-endpoint? Per-operation?
   - Nygard: "built at the scope of a single process"

2. **How to handle half-open state?**
   - Single probe request (Nygard's description)
   - Or percentage of traffic (some implementations)

3. **What counts as a failure?**
   - Timeout? 5xx? 429? Connection refused?
   - Nygard: "track different types of failures separately"

4. **Retry budget scope?**
   - Per-client? Per-endpoint? Shared across clients?
   - AWS SDK: Per-client, 500 tokens

5. **Integration with Proctor?**
   - Proctor already has death detection via Ractor.monitor
   - Should Kozo and Proctor share primitives?
