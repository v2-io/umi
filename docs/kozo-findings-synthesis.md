# Kozo Research Synthesis

**Date:** 2025-12-27
**Scope:** Source code analysis of 22 Ruby gems across HTTP clients, data clients,
payment processing, cloud SDKs, AI/ML, authentication, monitoring, and platform APIs.

This document presents observations from the research. It does not make recommendations.
Recommendations should follow as a separate discussion based on these findings.

---

## 1. Research Scope

### Gems Analyzed (22 total)

| Category | Gems | Notes |
|----------|------|-------|
| HTTP Clients (3) | Faraday, HTTParty, Excon | Foundation layer |
| Data Clients (3) | Redis-rb, Elasticsearch, Sidekiq | Infrastructure |
| Payment (2) | Stripe, ActiveMerchant | High-stakes transactions |
| Cloud SDKs (2) | AWS SDK, Google Cloud | Enterprise scale |
| AI/ML (4) | LangChainRB, ruby_llm, OpenAI SDK, Anthropic SDK | Emerging category |
| Authentication (2) | OmniAuth, Devise | Strategy patterns |
| Monitoring (3) | Sentry, NewRelic, Rollbar | Must never crash host |
| Platform APIs (3) | Octokit, Slack, Twilio | Rate limit handling |

### Methodology

- Cloned source code and read implementation files
- Focused on: error handling, resilience, configuration, API design
- Did not run benchmarks or verify behavior empirically

---

## 2. Error Handling Observations

### 2.1 Error Hierarchy Approaches

**Gems with rich hierarchies (7 of 22):**
- Stripe: 12+ error classes, separates card errors from API errors
- Octokit: 25+ classes, sub-classifies 403 by response body content
- AWS SDK: 33+ classes, separates config errors from runtime errors
- Google Cloud: 16 classes mapped to gRPC status codes
- Faraday: 12 classes covering transport and HTTP status
- Excon: 20+ classes including per-status-code errors
- OpenAI/Anthropic SDKs: 10 classes each, factory pattern for status codes

**Gems with minimal hierarchies (6 of 22):**
- ActiveMerchant: 4 classes, uses Response object with `success?` instead
- HTTParty: 6 classes, errors often bubble from Net::HTTP
- Twilio: 3 classes, relies on numeric error codes in response
- Redis-rb: 10 classes but mostly thin wrappers
- LangChainRB: 1 class (`ApiError`)
- ruby_llm: Delegates to Faraday errors

**Observation:** Rich hierarchies correlate with gems from well-funded teams (Stripe, AWS, Google) or mature open-source projects (Octokit, Faraday). Auto-generated SDKs (Twilio, Slack) tend toward minimal hierarchies.

### 2.2 Error Context Attached

| Gem | HTTP Status | Headers | Body | Request ID | Field/Param |
|-----|-------------|---------|------|------------|-------------|
| Stripe | ✓ | ✓ | ✓ | ✓ | ✓ (param) |
| Octokit | ✓ | ✓ | ✓ | via headers | ✓ (errors[]) |
| AWS SDK | ✓ | via context | ✓ | ✓ | varies |
| Faraday | ✓ | ✓ | ✓ | - | - |
| Excon | ✓ | ✓ | ✓ | - | - |
| ActiveMerchant | - | - | ✓ | - | ✓ (error_code) |
| Twilio | ✓ | - | ✓ | - | ✓ (code) |

**Observation:** Payment and enterprise gems consistently attach more context. HTTP client libraries provide status/headers/body but not domain-specific fields.

### 2.3 Exception Raising Behavior

**Raise by default (6 of 22):**
- Stripe, AWS SDK, Google Cloud, Octokit, OpenAI/Anthropic SDKs

**Don't raise by default (7 of 22):**
- Faraday (requires `response :raise_error` middleware)
- HTTParty (requires `raise_on [codes]` config)
- Excon (requires `expects: [codes]` option)
- ActiveMerchant (returns Response object)
- Redis-rb (returns values, raises on protocol errors)
- Elasticsearch (raises on transport errors, not HTTP status)
- Sidekiq (uses `Handled` exception to signal retry scheduled)

**Observation:** No consensus. Enterprise/official SDKs tend to raise. HTTP client libraries and infrastructure gems tend not to.

### 2.4 Alternative to Exceptions

**Response/Result objects used by:**
- ActiveMerchant: `Response` with `success?`, `message`, `error_code`
- Slack: Returns parsed JSON with `ok` boolean
- Sidekiq: Uses `Handled` exception to indicate "not really an error"

**Observation:** 3 of 22 gems use result objects as primary error signaling. This is a minority approach in Ruby gems.

---

## 3. Retry and Resilience Observations

### 3.1 Built-in Retry Support

| Gem | Has Retry | Strategy | Max Retries | Backoff | Jitter |
|-----|-----------|----------|-------------|---------|--------|
| Stripe | ✓ | Exponential | 2 | ✓ | ✓ (50-100% of delay) |
| AWS SDK | ✓ | Multiple modes | 3 | ✓ | Configurable (3 modes) |
| OpenAI/Anthropic | ✓ | Exponential | 2 | ✓ | ✓ |
| Excon | ✓ | Immediate/configurable | 4 | Optional | - |
| Octokit | ✓ | Via Faraday middleware | 3 | ✓ | ✓ |
| Elasticsearch | ✓ | Configurable delay | 3 | Optional | - |
| ActiveMerchant | ✓ | Immediate | 3 | - | - |
| Sidekiq | ✓ | `count^4 + 15` | 25 | ✓ | ✓ (essential) |
| Faraday | Via gem | faraday-retry | configurable | ✓ | ✓ |
| ruby_llm | Via Faraday | faraday-retry | 3 | ✓ | ✓ (interval_randomness) |
| HTTParty | - | - | - | - | - |
| LangChainRB | - | - | - | - | - |
| Redis-rb | Via config | configurable | 1 (default) | - | - |

**Observation:** 11 of 22 gems have built-in retry. Of those with exponential backoff, 6 include jitter. Sidekiq's jitter is explicitly documented as "essential" to prevent thundering herd.

**AWS SDK retry modes (unique sophistication):**
- `legacy`: Simple exponential backoff
- `standard`: Cross-SDK standardized with retry quotas
- `adaptive`: Adds automatic client-side throttling

**AWS jitter implementations:**
```ruby
EQUAL_JITTER = ->(delay) { (delay / 2) + Kernel.rand(0..(delay / 2)) }
FULL_JITTER  = ->(delay) { Kernel.rand(0..delay) }
NO_JITTER    = ->(delay) { delay }
```

### 3.1.1 Retry Quota/Budget System

**Only AWS SDK (1 of 22)** implements a retry budget:

```ruby
# Token bucket: 500 initial, costs 5 per retry, 10 for network errors
INITIAL_RETRY_TOKENS = 500
RETRY_COST = 5
TIMEOUT_RETRY_COST = 10  # Network errors cost more
```

When quota exhausted, raises `RetryCapacityNotAvailableError` instead of retrying.

**Observation:** Retry budgets prevent cascade failures but only AWS SDK implements this.

### 3.2 Retry Decision Factors

**What makes a request retryable:**

| Factor | Gems Using |
|--------|------------|
| HTTP status (5xx) | Stripe, AWS, OpenAI/Anthropic, Excon, Octokit |
| HTTP status (429) | Stripe (only lock_timeout), AWS, OpenAI/Anthropic |
| HTTP status (408, 409) | AWS, OpenAI/Anthropic |
| Connection errors | All gems with retry |
| Timeouts | All gems with retry |
| Server header (`x-should-retry`) | Stripe, OpenAI/Anthropic |
| Idempotent method (GET, PUT, DELETE) | Excon (explicit), implicit in others |

**Observation:** Stripe's `stripe-should-retry` header pattern (server tells client whether to retry) is sophisticated but only 3 of 22 gems support it.

### 3.3 Idempotency Key Support

**Explicit support (3 of 22):**
- Stripe: Auto-generates for POST/DELETE when retries enabled
- Excon: `idempotent: true` option
- ActiveMerchant: Passes through if provided

**Observation:** Idempotency is not widely implemented at the gem level. Most gems leave it to the caller.

### 3.4 Circuit Breaker

**Explicit circuit breaker (0 of 22):**
None of the analyzed gems have explicit circuit breaker patterns.

**Implicit circuit breaker behavior (1 of 22):**
- Elasticsearch: Dead connections have resurrection timeout with exponential backoff. This is circuit breaker behavior without the name.

**Observation:** Circuit breakers are absent from the Ruby gem ecosystem. The pattern exists in theory (Release It!) but not in practice.

### 3.5 Connection Health Tracking

**Gems with connection health states (3 of 22):**
- Elasticsearch: alive → dead → resurrectable, exponential backoff
- Sidekiq: Detects Redis failover (READONLY/NOREPLICAS/UNBLOCKED)
- Stripe: Connection manager GC (120s idle timeout)

**Elasticsearch connection state machine:**
```ruby
def dead!
  @dead = true
  @failures += 1
  @dead_since = Time.now
end

def resurrectable?
  # Exponential backoff: timeout * 2^(failures-1)
  Time.now > @dead_since + (@resurrect_timeout * 2 ** (@failures - 1))
end

def healthy!
  @dead = false
  @failures = 0  # Reset on success
end
```

**Sidekiq failover detection:**
```ruby
rescue RedisClientAdapter::BaseError => ex
  # Handle Redis failover: READONLY, NOREPLICAS, UNBLOCKED
  if retryable && ex.message =~ /READONLY|NOREPLICAS|UNBLOCKED/
    conn.close
    retryable = false
    retry
  end
  raise
end
```

**Observation:** Connection health tracking is rare. Most gems create new connections per request (HTTParty, ActiveMerchant) or rely on underlying libraries.

### 3.6 Supervisor/Manager Patterns

**Sidekiq's Manager** implements supervision:
```ruby
def processor_result(processor, reason = nil)
  @workers.delete(processor)
  unless @done
    # Replace the dead processor
    p = Processor.new(@config, &method(:processor_result))
    @workers << p
    p.start
  end
end
```

**Observation:** Only Sidekiq (1 of 22) has explicit supervisor patterns. This is core OTP territory that Ruby gems largely don't explore.

---

## 4. Timeout Configuration Observations

### 4.1 Timeout Granularity

| Gem | Connect | Read | Write | Overall |
|-----|---------|------|-------|---------|
| Faraday | `open_timeout` | `read_timeout` | `write_timeout` | `timeout` (fallback) |
| HTTParty | `open_timeout` | `read_timeout` | `write_timeout` | `timeout` |
| Excon | `connect_timeout` | `read_timeout` | `write_timeout` | `timeout` (deadline) |
| Stripe | `open_timeout` | `read_timeout` | `write_timeout` | - |
| AWS SDK | Combined | Combined | - | `http_wire_trace` |
| OpenAI/Anthropic | Combined | Combined | Combined | 600s default |

**Observation:** HTTP client libraries (Faraday, HTTParty, Excon) offer fine-grained control. Higher-level SDKs often combine into a single timeout.

### 4.2 Deadline Pattern

**Uses overall deadline (2 of 22):**
- Excon: `timeout` creates a deadline that caps all operations
- OpenAI/Anthropic: `deadline = now + timeout`, recalibrates socket timeouts

**Observation:** The deadline pattern (one timeout for entire request lifecycle) is rare. Most gems use independent per-operation timeouts.

---

## 5. Configuration Observations

### 5.1 Configuration Layers

**Standard pattern (Global → Client → Request):**
- Faraday: `Faraday.default_adapter` → `Faraday.new(...)` → `conn.get { |req| ... }`
- Stripe: `Stripe.api_key` → `Stripe::StripeClient.new(...)` → `{ api_key: ... }`
- Octokit: `Octokit.configure` → `Octokit::Client.new(...)` → per-method options

**Observation:** 18 of 22 gems follow some form of global → instance → request override pattern.

### 5.2 Configuration Mechanisms

| Mechanism | Count | Examples |
|-----------|-------|----------|
| Module-level `mattr_accessor` | 8 | Devise, Stripe, OmniAuth |
| `configure` block | 14 | Faraday, Stripe, Slack, Octokit |
| Instance options hash | 18 | Nearly all |
| Per-request options | 12 | Faraday, Stripe, Octokit |
| Class attributes | 5 | ActiveMerchant, HTTParty |

### 5.3 Credential Provider Chains

**AWS SDK** has 14+ credential providers tried in order:
```ruby
# Order: static → env → assume_role → shared_credentials → instance_profile
providers.each do |method_name, options|
  provider = send(method_name, options)
  return provider if provider&.set?
end
```

**Google Cloud** has 4 sources + ADC fallback:
```ruby
PATH_ENV_VARS = ["GOOGLE_CLOUD_KEYFILE", "GCLOUD_KEYFILE"]
JSON_ENV_VARS = ["GOOGLE_CLOUD_KEYFILE_JSON", "GCLOUD_KEYFILE_JSON"]
DEFAULT_PATHS = ["~/.config/gcloud/application_default_credentials.json"]
# Falls back to Google::Auth.get_application_default
```

**Observation:** Cloud SDKs have sophisticated credential resolution. Other gems typically require explicit configuration.

### 5.4 Per-Operation Configuration

**Google Cloud gRPC clients** allow per-RPC configuration:
```ruby
default_config.rpcs.create_topic.timeout = 60.0
default_config.rpcs.create_topic.retry_policy = {
  initial_delay: 0.1,
  max_delay: 60.0,
  multiplier: 1.3,
  retry_codes: [14]  # UNAVAILABLE
}

default_config.rpcs.publish.retry_policy = {
  retry_codes: [10, 1, 13, 8, 2, 14, 4]  # More codes for publish
}
```

**Observation:** Only Google Cloud (1 of 22) allows different retry policies per operation. Others use client-level configuration.

---

## 6. API Design Observations

### 6.1 Resource Access Patterns

**Flat methods (3 of 22):**
- Octokit: `client.repository("owner/repo")`, `client.create_issue(...)`
- HTTParty: `MyAPI.get('/users')`
- ruby_llm: `RubyLLM.chat(...)`

**Nested/namespaced resources (7 of 22):**
- Twilio: `client.api.account.calls.create(...)`
- Slack: `client.chat_postMessage(...)` (underscores as namespace)
- AWS SDK: `client.s3.get_object(...)`
- OpenAI/Anthropic: `client.messages.create(...)`
- Stripe: `Stripe::Customer.create(...)` (class-based)
- Google Cloud: `client.storage.bucket(...)`
- Elasticsearch: `client.indices.create(...)`

**Observation:** No consensus on API style. Official SDKs tend toward nested resources.

### 6.2 Middleware Architecture

**Uses middleware (5 of 22):**
- Faraday: Rack-inspired stack, most extensible
- Excon: Three-phase (request_call, response_call, error_call)
- Sidekiq: Client and server middleware chains
- OmniAuth: Strategies are Rack middleware
- Sentry: Rack middleware for request capture

**No middleware (17 of 22):**
Most gems have no middleware concept.

**Observation:** Middleware is not the norm. Faraday popularized it but most gems don't adopt the pattern.

### 6.3 Streaming Support

**SSE/streaming support (5 of 22):**
- OpenAI/Anthropic: Enumerable over SSE events
- Stripe: Block-based response streaming
- Elasticsearch: Scroll API, bulk streaming
- Excon: `request_block`, `response_block` callbacks
- HTTParty: Block for response chunks

**ruby_llm's StreamAccumulator pattern:**
```ruby
class StreamAccumulator
  def add(chunk)
    @model_id ||= chunk.model_id
    if chunk.tool_call?
      accumulate_tool_calls chunk.tool_calls
    else
      @content << (chunk.content || '')
    end
    count_tokens chunk
  end

  def to_message(response)
    Message.new(role: :assistant, content: @content, ...)
  end
end
```

**Observation:** Streaming is present but implementations vary widely. ruby_llm's accumulator pattern is the cleanest abstraction observed.

### 6.4 Thread Safety

**Redis-rb** uses Monitor (reentrant mutex):
```ruby
def initialize(options = {})
  @monitor = Monitor.new
end

def synchronize
  @monitor.synchronize { yield(@client) }
end
```

**Elasticsearch** uses per-connection mutex:
```ruby
def dead!
  @state_mutex.synchronize do
    @dead = true
    @failures += 1
  end
end
```

**Observation:** Thread safety approaches vary. Some use Monitor (reentrant), some use Mutex, some rely on connection-per-request.

---

## 7. Monitoring Gem Patterns

These three gems (Sentry, NewRelic, Rollbar) share a critical constraint: they must never crash or degrade the host application.

### 7.1 Failure Isolation

All three use:
- Background threads/workers for sending
- Exception swallowing at boundaries
- `fallback_policy: :discard` when queue full
- Failsafe payloads when primary reporting fails

### 7.2 Specific Techniques

| Technique | Sentry | NewRelic | Rollbar |
|-----------|--------|----------|---------|
| Thread pool | ✓ (concurrent-ruby) | ✓ (custom event loop) | ✓ (async option) |
| Queue overflow handling | Discard silently | Disconnect gracefully | Failsafe payload |
| Exception capture | `rescue Exception` | `rescue => e` | `rescue StandardError, SystemStackError` |
| Error reporting on error | via different endpoint | log only | failsafe payload |

**Observation:** These gems demonstrate how to build infrastructure that must not fail, even when the network is failing.

### 7.3 Rate Limit Handling

**Sentry** parses server rate limit headers:
```ruby
RETRY_AFTER_HEADER = "retry-after"
RATE_LIMIT_HEADER = "x-sentry-rate-limits"

def is_rate_limited?(data_category)
  delay = @rate_limits[data_category] || @rate_limits[nil]
  !!delay && delay > Time.now
end
```

**Sentry backpressure monitoring:**
```ruby
# Increases downsample factor when rate limited or queue full
MAX_DOWNSAMPLE_FACTOR = 10

def check_health
  @healthy = !(@client.transport.any_rate_limited? ||
               Sentry.background_worker&.full?)
end
```

### 7.4 Adaptive Sampling

**NewRelic** implements sophisticated adaptive sampling:
```ruby
# Target 10 samples per 60-second period
# First 10 always sampled
# After target reached, exponential backoff on sampling probability
def exponential_backoff
  @target**(@target.to_f / @sampled_count) - @target**0.5
end
```

### 7.5 Payload Truncation

**Rollbar** has cascading truncation strategies:
```ruby
MAX_PAYLOAD_SIZE = 512 * 1024  # 512kb

STRATEGIES = [
  RawStrategy,           # Try raw JSON first
  FramesStrategy,        # Reduce stack frames
  StringsStrategy,       # Truncate long strings
  MinBodyStrategy,       # Minimal body
  RemoveRequestStrategy, # Remove request data
  RemoveExtraStrategy,   # Remove extra data
  RemoveAnyKeyStrategy   # Last resort
].freeze
```

**Observation:** Monitoring gems have sophisticated strategies for degrading gracefully under load - sampling, truncation, backpressure. Most other gems don't.

---

## 8. Variance and Competing Approaches

### 8.1 Genuine Design Tensions

These are areas where gems take different approaches with valid tradeoffs:

| Tension | Approach A | Approach B |
|---------|-----------|------------|
| Error signaling | Exceptions (Stripe, AWS) | Result objects (ActiveMerchant) |
| Error hierarchy | Rich/hierarchical (Octokit) | Auto-generated (Slack, Twilio) |
| Retry | Built-in (Stripe) | Caller's responsibility (HTTParty) |
| Connection management | Pooling (Stripe) | Per-request (ActiveMerchant) |
| Middleware | Yes (Faraday) | No (HTTParty) |
| API style | Flat (Octokit) | Nested (Twilio) |
| Configuration | DSL blocks | Hash options |

### 8.2 Things Most Gems Don't Do

| Feature | Count Doing | Count Not Doing |
|---------|-------------|-----------------|
| Circuit breaker | 0 | 22 |
| Preemptive rate limiting | 0 | 22 |
| Deadline-based timeouts | 2 | 20 |
| Jitter in retry | 6 | 16 (of those with retry) |
| Request ID propagation | 3 | 19 |
| Server-controlled retry hints | 3 | 19 |

---

## 9. Code Generation Observations

### 9.1 Generated vs Hand-Written

**Fully or mostly generated (5 of 22):**
- OpenAI/Anthropic: Stainless framework, ~95% generated
- Twilio: OpenAPI generator
- Slack: API spec → error classes, method stubs
- AWS SDK: Service models → gem code

**Hand-written (17 of 22):**
- Most gems are hand-written

**Observation:** Official SDKs from large companies tend to be generated. Community gems are hand-written.

### 9.2 Generated SDK Characteristics

- Large file counts (OpenAI: ~800 .rb files)
- Type definitions (RBI/RBS) included
- Uniform patterns across all endpoints
- Less flexibility for Ruby idioms

---

## 10. Summary of Distributions

### What Most Gems Do (15+ of 22)

- Have some form of error hierarchy (even if minimal)
- Use configuration layers (global → instance → request)
- Support keyword arguments
- Are hand-written (not generated)

### What Many Gems Do (8-14 of 22)

- Have built-in retry logic
- Attach HTTP context to errors
- Use configure blocks
- Support per-request option overrides

### What Some Gems Do (3-7 of 22)

- Have rich error hierarchies (7)
- Include jitter in retry (6)
- Use middleware patterns (5)
- Support streaming (5)
- Track connection health (3)
- Parse rate limit headers (3: Sentry, Octokit, Stripe)
- Use deadline-based timeouts (2)
- Have supervisor patterns (1: Sidekiq)
- Have retry budgets (1: AWS SDK)
- Have per-operation retry config (1: Google Cloud)

### What No Gems Do (0 of 22)

- Explicit circuit breaker with open/closed/half-open states
- Preemptive rate limit slowdown (slow down before hitting limit)
- Standardized retry coordination across gems
- Deadline propagation to child operations

---

## Appendix: Data Sources

All observations based on source code analysis of:

```
faraday (1,091M downloads)
httparty (425M downloads)
excon (significant)
redis-rb (via redis-client)
elasticsearch-ruby
sidekiq
stripe-ruby
activemerchant
aws-sdk-core (1,571M downloads)
google-cloud-ruby
langchainrb
ruby_llm
openai-ruby (official)
anthropic-ruby (official)
omniauth (194M downloads)
devise
sentry-ruby
newrelic_rpm
rollbar
octokit
slack-ruby-client
twilio-ruby
```

Analysis files in `docs/research/`:
- analysis-http-clients.md (1,062 lines)
- analysis-data-clients.md (1,129 lines)
- analysis-payment-gems.md (1,024 lines)
- analysis-cloud-sdks.md (993 lines)
- analysis-llm-gems.md (969 lines)
- analysis-auth-gems.md (759 lines)
- analysis-monitoring-gems.md (749 lines)
- analysis-official-ai-sdks.md (733 lines)
- analysis-platform-apis.md (659 lines)
