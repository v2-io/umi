# Kozo Research: Ruby API Ecosystem Analysis

**Date:** 2025-12-27
**Purpose:** Inform Kozo design by analyzing battle-tested Ruby gems

This research surveyed 100+ Ruby API gems and performed deep source code analysis
on 20+ to understand patterns for error handling, resilience, and API design.

---

## Survey Documents

| Document | Scope |
|----------|-------|
| [research-ruby-api-gems.md](research-ruby-api-gems.md) | Top 100 Ruby gems that provide API abstractions |
| [research-ruby-ai-gems.md](research-ruby-ai-gems.md) | Top 20 AI/ML Ruby gems (2023-2025 wave) |

---

## Deep Analysis Documents

| Document | Gems Analyzed | Key Patterns |
|----------|---------------|--------------|
| [analysis-http-clients.md](analysis-http-clients.md) | Faraday, HTTParty, Excon | Middleware, adapters, connection pooling, timeout granularity |
| [analysis-data-clients.md](analysis-data-clients.md) | Redis-rb, Elasticsearch, Sidekiq | Connection health states, retry with jitter, supervisor patterns |
| [analysis-payment-gems.md](analysis-payment-gems.md) | Stripe, ActiveMerchant | Idempotency keys, error hierarchies, retry budgets |
| [analysis-cloud-sdks.md](analysis-cloud-sdks.md) | AWS SDK, Google Cloud | Configuration layers, error translation, credential management |
| [analysis-llm-gems.md](analysis-llm-gems.md) | LangChainRB, ruby_llm | Streaming, provider abstraction, token management |
| [analysis-auth-gems.md](analysis-auth-gems.md) | OmniAuth, Devise | Strategy pattern, middleware chains |
| [analysis-monitoring-gems.md](analysis-monitoring-gems.md) | Sentry, NewRelic, Rollbar | Error capture, context propagation |
| [analysis-official-ai-sdks.md](analysis-official-ai-sdks.md) | OpenAI SDK, Anthropic SDK | Official patterns, streaming, tool use |
| [analysis-platform-apis.md](analysis-platform-apis.md) | Octokit, Slack, Twilio | Rate limiting, pagination, webhook verification |

---

## Key Findings Summary

### 1. Error Handling Patterns

All mature gems share these characteristics:

- **Hierarchical errors**: Base → Category → Specific (e.g., `Error → ClientError → RateLimitError`)
- **Rich context**: Errors carry `request_id`, `http_status`, `response_body`
- **Transient vs permanent**: Connection errors are retryable; validation errors are not
- **Don't raise by default**: Faraday, HTTParty, Excon all require opt-in for exceptions

### 2. Resilience Patterns

| Pattern | Where Found | Notes |
|---------|-------------|-------|
| Exponential backoff | Stripe, Sidekiq, Elasticsearch | With jitter to prevent thundering herd |
| Connection health states | Elasticsearch, Redis | alive → dead → resurrectable |
| Retry budgets | AWS SDK | `RetryCapacityNotAvailableError` |
| Circuit breaker (implicit) | Elasticsearch | Dead connections have resurrection timeout |
| Idempotency keys | Stripe | First-class error type for conflicts |

### 3. Configuration Layers

Standard pattern: `Global defaults → Connection/Client → Per-request`

```ruby
# Global
Faraday.default_adapter = :net_http

# Connection
conn = Faraday.new(url: 'https://api.example.com', timeout: 30)

# Request
conn.get('/users') { |req| req.options.timeout = 5 }
```

### 4. Timeout Granularity

Most gems support:
- `connect_timeout` - TCP connection establishment
- `read_timeout` - Waiting for response
- `write_timeout` - Sending request body
- `timeout` - Overall deadline (Excon's approach is best)

### 5. What's Missing Everywhere

- **Circuit breakers**: No gems have explicit circuit breaker support
- **Rate limit tracking**: Callers must implement preemptive slowdown
- **Retry coordination**: Each gem rolls its own retry logic
- **Deadline propagation**: No standard for cascading timeouts

---

## Implications for Kozo

1. **Tagged tuples** align with how gems signal outcomes (success, retry, dead)
2. **Error hierarchy** should separate transport/http/api/validation errors
3. **Deadline-based timeouts** (Excon pattern) are superior to per-operation timeouts
4. **Health state machine** for connections/processes is well-proven
5. **Middleware composition** enables clean separation of concerns
6. **Jitter is essential** - Sidekiq's formula: `delay + rand(10 * (count + 1))`

---

## Source Repositories

Cloned to `tmp/gem-research/` for analysis:

```
faraday, httparty, excon, redis-rb, elasticsearch-ruby, sidekiq,
stripe, activemerchant, aws-sdk-ruby, google-cloud-ruby, omniauth,
devise, sentry-ruby, newrelic-ruby-agent, rollbar, openai-sdk,
anthropic-sdk, langchainrb, ruby_llm, octokit, slack-ruby-client,
twilio-ruby
```
