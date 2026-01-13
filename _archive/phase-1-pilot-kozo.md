# Phase 1 Pilot: Kozo (骨組み)

**Status:** Research / Brainstorm
**Date:** 2025-12-27

Kozo (骨組み) means "framework" or "skeleton/structure" in Japanese. This component
provides the structural foundation for robust HTTP/API integration - making the first
naive implementation already production-ready, the way Proctor did for MCPClient.

---

## Part 1: First Principles - Failure Mode Analysis

Instead of starting with "what HTTP status codes exist," we start with:
1. **What can go wrong?** (failure modes)
2. **What can we do about it?** (possible reactions)
3. **What information is available?** (to make decisions)
4. **What must the developer tell us?** (intent, constraints)

### 1.1 Failure Mode Categories

```
┌─────────────────────────────────────────────────────────────────┐
│                    FAILURE MODE TAXONOMY                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐                                               │
│  │ DNS Layer    │ Name resolution                               │
│  └──────┬───────┘                                               │
│         ▼                                                        │
│  ┌──────────────┐                                               │
│  │ TCP Layer    │ Connection establishment                      │
│  └──────┬───────┘                                               │
│         ▼                                                        │
│  ┌──────────────┐                                               │
│  │ TLS Layer    │ Encryption handshake                          │
│  └──────┬───────┘                                               │
│         ▼                                                        │
│  ┌──────────────┐                                               │
│  │ HTTP Layer   │ Request/response exchange                     │
│  └──────┬───────┘                                               │
│         ▼                                                        │
│  ┌──────────────┐                                               │
│  │ Content Layer│ Payload parsing                               │
│  └──────┬───────┘                                               │
│         ▼                                                        │
│  ┌──────────────┐                                               │
│  │ Protocol Layer│ REST/GraphQL/JSON-RPC semantics              │
│  └──────────────┘                                               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Part 2: Layer-by-Layer Failure Analysis

### 2.1 DNS Layer

| Failure Mode | Cause | Available Info | Possible Reactions |
|--------------|-------|----------------|-------------------|
| NXDOMAIN | Host doesn't exist | hostname | **Config error** - don't retry, alert human |
| SERVFAIL | DNS server error | hostname, resolver | **Transient** - retry with backoff, try alt resolver |
| Timeout | DNS server slow/unreachable | hostname, timeout value | **Transient** - retry, try alt resolver |
| REFUSED | DNS server refused query | hostname, resolver | **Config error** - check resolver config |

**What only developer knows:**
- Is this hostname expected to exist? (typo vs new service)
- Are there fallback hostnames?
- Is DNS caching acceptable? For how long?

---

### 2.2 TCP Layer

| Failure Mode | Cause | Available Info | Possible Reactions |
|--------------|-------|----------------|-------------------|
| ECONNREFUSED | Nothing listening on port | host, port | **Service down** - retry with backoff, circuit break |
| ETIMEDOUT | Connection attempt timed out | host, port, timeout | **Network issue** - retry with backoff |
| ENETUNREACH | Network unreachable | host, network info | **Network issue** - retry, maybe transient |
| EHOSTUNREACH | Host unreachable | host | **Network/config** - retry with backoff |
| ECONNRESET | Connection reset by peer | host, port | **Service issue** - retry |
| ECONNABORTED | Connection aborted | - | **Transient** - retry |

**Key distinction:**
- ECONNREFUSED = we reached the host but nothing's listening → service is down
- ETIMEDOUT = we couldn't reach the host → network issue

**What only developer knows:**
- Expected connection time for this service?
- Is the service expected to be up 24/7?
- Are there replica hosts to try?

---

### 2.3 TLS Layer

| Failure Mode | Cause | Available Info | Possible Reactions |
|--------------|-------|----------------|-------------------|
| Certificate expired | Cert past validity | cert details, expiry date | **Config error** - don't retry, alert urgently |
| Certificate not yet valid | Cert future validity | cert details, not-before date | **Config/clock error** - check system clock |
| Hostname mismatch | Cert doesn't match host | expected host, cert hosts | **Config error** - wrong host or cert |
| Self-signed | No trusted CA | cert chain | **Config error** - need to trust CA or use different cert |
| Unknown CA | CA not in trust store | cert chain, CA | **Config error** - update trust store |
| Protocol mismatch | TLS version incompatible | offered versions, required | **Config error** - update client or server |
| Handshake timeout | TLS negotiation too slow | timeout value | **Transient** - retry |
| Handshake failure | Generic failure | error details | **Investigate** - could be many things |

**What only developer knows:**
- Should we accept self-signed certs? (dev vs prod)
- Is there a specific CA we should trust?
- What TLS versions are acceptable?

---

### 2.4 HTTP Layer - Request Phase

| Failure Mode | Cause | Available Info | Possible Reactions |
|--------------|-------|----------------|-------------------|
| Write timeout | Server not accepting data | timeout, bytes sent | **Service slow** - retry with longer timeout? |
| Connection closed | Server closed mid-request | bytes sent | **Transient** - retry if idempotent |
| Request too large | 413 before body sent | content-length, limit | **Client error** - don't retry, reduce payload |

**Critical question: Did the server receive the request?**
- If connection closed before full send → server probably didn't process
- If connection closed after full send → server might have processed

---

### 2.5 HTTP Layer - Response Phase

#### 2.5.1 Redirects (3xx)

| Status | Meaning | Available Info | Automatic Reaction | Developer Concern |
|--------|---------|----------------|-------------------|-------------------|
| 301 | Moved Permanently | Location header | Follow + **update stored URL** | Should we persist the new URL? |
| 302 | Found (temp redirect) | Location header | Follow, **don't update URL** | - |
| 303 | See Other | Location header | Follow with **GET** | - |
| 304 | Not Modified | - | **Use cached response** | Cache valid |
| 307 | Temporary Redirect | Location header | Follow, **preserve method** | - |
| 308 | Permanent Redirect | Location header | Follow, **preserve method + update URL** | Should we persist? |

**What only developer knows:**
- Max redirects to follow?
- Should we follow cross-origin redirects?
- Should we persist permanent redirects?

#### 2.5.2 Client Errors (4xx)

| Status | Meaning | Retriable? | Available Info | Developer Concern |
|--------|---------|------------|----------------|-------------------|
| 400 | Bad Request | **No** - our bug | error body | Fix the code |
| 401 | Unauthorized | **Maybe** - refresh auth | WWW-Authenticate header | Do we have refresh capability? |
| 403 | Forbidden | **No** - not authorized | error body | Permissions issue |
| 404 | Not Found | **Usually no** | - | Resource doesn't exist (or bad URL) |
| 405 | Method Not Allowed | **No** - our bug | Allow header | Wrong HTTP method |
| 406 | Not Acceptable | **No** - our bug | - | Wrong Accept header |
| 408 | Request Timeout | **Yes** - server timeout | - | Server gave up waiting |
| 409 | Conflict | **Maybe** - refresh & retry | error body | State conflict, might resolve |
| 410 | Gone | **No** - permanent | - | Resource deleted forever |
| 412 | Precondition Failed | **Maybe** - refresh & retry | - | ETag/If-Match failed |
| 413 | Payload Too Large | **No** - our bug | - | Reduce payload size |
| 414 | URI Too Long | **No** - our bug | - | Shorten URL |
| 415 | Unsupported Media Type | **No** - our bug | - | Wrong Content-Type |
| 422 | Unprocessable Entity | **No** - validation | error body (often structured) | Fix input data |
| 429 | Too Many Requests | **Yes** - after delay | Retry-After header | Rate limited |
| 451 | Unavailable For Legal | **No** | - | Legal block |

#### 2.5.3 Server Errors (5xx)

| Status | Meaning | Retriable? | Available Info | Developer Concern |
|--------|---------|------------|----------------|-------------------|
| 500 | Internal Server Error | **Maybe** | error body | Server bug, might be transient |
| 501 | Not Implemented | **No** | - | Feature doesn't exist |
| 502 | Bad Gateway | **Yes** | - | Upstream failure |
| 503 | Service Unavailable | **Yes** | Retry-After header | Overloaded/maintenance |
| 504 | Gateway Timeout | **Yes** | - | Upstream timeout |

---

### 2.6 Content Layer

| Failure Mode | Cause | Available Info | Possible Reactions |
|--------------|-------|----------------|-------------------|
| Content-Type mismatch | Expected JSON, got HTML | Content-Type header, body | **Error** - wrong endpoint? Error page? |
| JSON parse error | Malformed JSON | body, parse error position | **Error** - server bug |
| Encoding error | Wrong charset | Content-Type charset, body | **Error** - try different encoding? |
| Truncated response | Connection closed mid-body | Content-Length vs received | **Transient** - retry |
| Decompression error | Bad gzip/brotli | Content-Encoding, body | **Error** - server bug |

**What only developer knows:**
- Expected content type?
- Fallback content types acceptable?
- Schema for validation?

---

### 2.7 Protocol Layer (REST/GraphQL/JSON-RPC)

#### REST

| Situation | Available Info | Meaning |
|-----------|----------------|---------|
| 200 + empty body | - | Success, no content |
| 200 + error in body | error field | **API-level error** (bad pattern but common) |
| 201 + Location | Location header | Created, here's the URL |
| 202 | - | Accepted, processing async |
| Pagination headers | Link, X-Total-Count, etc. | More data available |

#### GraphQL

| Situation | Available Info | Meaning |
|-----------|----------------|---------|
| 200 + data + no errors | data field | **Success** |
| 200 + data + errors | data + errors fields | **Partial success** |
| 200 + no data + errors | errors field | **Failure** |
| errors[].extensions.code | error codes | Machine-readable error type |

#### JSON-RPC

| Situation | Available Info | Meaning |
|-----------|----------------|---------|
| result field present | result | **Success** |
| error field present | error.code, error.message, error.data | **Failure** |
| error.code -32700 | - | Parse error |
| error.code -32600 | - | Invalid request |
| error.code -32601 | - | Method not found |
| error.code -32602 | - | Invalid params |
| error.code -32603 | - | Internal error |

---

## Part 3: The Idempotency Question

**The critical question that determines retry strategy:**

> If we send the request again, what happens?

| Method | Idempotent by Spec? | Reality |
|--------|--------------------| --------|
| GET | Yes | Yes - safe to retry |
| HEAD | Yes | Yes - safe to retry |
| OPTIONS | Yes | Yes - safe to retry |
| PUT | Yes | Usually - replaces resource |
| DELETE | Yes | Usually - already deleted = ok |
| POST | **No** | Depends on endpoint semantics |
| PATCH | **No** | Depends on endpoint semantics |

**But idempotency is more nuanced:**

```
┌─────────────────────────────────────────────────────────────────┐
│                    IDEMPOTENCY SCENARIOS                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Request sent, no response received:                            │
│  ├─ Connection failed before send complete → Retry safe         │
│  ├─ Connection failed after send complete → ???                 │
│  │   ├─ If idempotent → Retry safe                              │
│  │   └─ If not idempotent → DANGER - may have processed         │
│  └─ Timeout waiting for response → ???                          │
│      ├─ Server might still be processing                        │
│      ├─ Server might have finished and we missed response       │
│      └─ Server might have failed                                │
│                                                                  │
│  POST /payments:                                                 │
│  ├─ With Idempotency-Key header → Retry safe                    │
│  └─ Without → May create duplicate payment                      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**What only developer knows:**
- Is this specific endpoint idempotent regardless of HTTP method?
- Does the API support idempotency keys?
- What's the consequence of duplicate requests?
- Is this part of an eventually-consistent system?

---

## Part 4: Developer Intent Categories

The library can handle mechanics. The developer must declare **intent**:

### 4.1 Criticality

```ruby
# "I need a response, failure is not acceptable"
client.get(url, criticality: :must_succeed)
# → Aggressive retry, long timeouts, alert on final failure

# "Best effort, failure is acceptable"
client.get(url, criticality: :best_effort)
# → Limited retry, short timeouts, silent failure ok

# "Fire and forget"
client.post(url, body: data, criticality: :fire_and_forget)
# → No retry, no waiting for response
```

### 4.2 Idempotency Declaration

```ruby
# "This POST is actually idempotent"
client.post(url, body: data, idempotent: true)
# → Safe to retry on timeout/connection failure

# "This POST has an idempotency key"
client.post(url, body: data, idempotency_key: uuid)
# → Safe to retry, server will dedupe

# "This POST is NOT idempotent, be careful"
client.post(url, body: data, idempotent: false)  # default
# → Only retry on definite non-delivery (connection refused, etc.)
```

### 4.3 Consistency Model

```ruby
# "Part of eventually-consistent system"
client.post(url, body: data,
  consistency: :eventual,
  idempotency_key: uuid
)
# → If timeout after send, schedule background retry/verification
# → Don't block waiting, return "accepted" status

# "Need strong consistency"
client.post(url, body: data, consistency: :strong)
# → Wait for definitive response
# → Fail loudly on ambiguous outcomes
```

### 4.4 Fallback Behavior

```ruby
client.get(url,
  fallback: -> { cached_value },
  fallback_on: [:timeout, :server_error, :circuit_open]
)
# → Use fallback instead of failing for these cases
```

---

## Part 5: What Kozo Should Do Automatically

### 5.1 Always (no developer input needed)

| Situation | Automatic Behavior |
|-----------|--------------------|
| 301/308 redirect | Follow + remember (optionally persist) |
| 302/307 redirect | Follow (don't remember) |
| 303 redirect | Follow with GET |
| ECONNREFUSED | Retry with backoff up to N times |
| ETIMEDOUT (connect) | Retry with backoff |
| DNS SERVFAIL | Retry with backoff |
| Gzip/brotli response | Decompress transparently |
| Retry-After header | Respect the delay |
| Rate limit headers | Track and preemptively slow down |

### 5.2 Configurable Defaults

| Situation | Default | Configurable |
|-----------|---------|--------------|
| Max redirects | 5 | Yes |
| Connect timeout | 10s | Yes |
| Read timeout | 30s | Yes |
| Retry attempts | 3 | Yes |
| Backoff strategy | Exponential | Yes |
| Circuit breaker threshold | 5 failures | Yes |

### 5.3 Requires Developer Declaration

| Situation | Why Developer Must Decide |
|-----------|---------------------------|
| POST/PATCH retry on timeout | May cause duplicates |
| Cross-origin redirect following | Security implications |
| Self-signed cert acceptance | Security implications |
| Fallback values | Domain-specific |
| Error classification | API-specific |

---

## Part 6: The Return Value Design

### 6.1 Semantic Tuples

Every response should be a tagged tuple that tells you **what happened** and **what you can do**:

```ruby
# Success cases
[:ok, response]              # 2xx with body
[:created, response]         # 201, response.location has URL
[:accepted, response]        # 202, async processing
[:no_content, response]      # 204
[:cached, response]          # 304, used cache

# Redirect cases (if not auto-followed)
[:redirect, :permanent, response]  # 301/308
[:redirect, :temporary, response]  # 302/307

# Client errors - by recoverability
[:invalid, response]         # 400, 415, 422 - our bug, don't retry
[:unauthorized, response]    # 401 - need auth
[:forbidden, response]       # 403 - won't ever work
[:not_found, response]       # 404
[:gone, response]            # 410 - permanently deleted
[:conflict, response]        # 409 - state conflict, might retry after refresh
[:rate_limited, response]    # 429 - response.retry_after has delay

# Server errors
[:server_error, response]    # 5xx - response.retriable? usually true

# Transport errors
[:connection_failed, error]  # ECONNREFUSED etc
[:timeout, phase, error]     # :connect, :read, :total
[:ssl_error, reason, error]  # Certificate issues
[:dns_error, reason, error]  # Resolution failed

# Circuit breaker
[:circuit_open, state]       # Not even attempted
```

### 6.2 Response Object Intelligence

```ruby
response.status              # Numeric code
response.status_class        # :success, :redirect, :client_error, :server_error

response.retriable?          # Should we try again?
response.retry_after         # Seconds to wait (from header or calculated)
response.retry_strategy      # :immediate, :backoff, :after_delay, :after_auth, :never

response.permanent_failure?  # Will never succeed
response.transient_failure?  # Might succeed later
response.auth_failure?       # Need credentials

response.body                # Parsed based on content-type
response.raw_body            # Unparsed bytes
response.headers             # Response headers

response.request             # Original request (for debugging/retry)
response.timing              # DNS, connect, TLS, request, response times
```

---

## Part 7: Open Questions

1. **How to handle "request sent, connection lost before response"?**
   - For idempotent: retry
   - For non-idempotent with idempotency-key: retry
   - For non-idempotent without: ???
     - Return special status? `[:ambiguous, :sent_but_no_response, ...]`
     - Let developer decide via callback?

2. **Should we track API versioning/deprecation?**
   - Many APIs send deprecation warnings in headers
   - Should we surface these? Log them? Callback?

3. **How to handle "partial success" in GraphQL?**
   - 200 status but errors array non-empty
   - Some data returned, some fields errored
   - Is this `:ok` or `:partial` or `:error`?

4. **Background retry for eventually-consistent systems?**
   - If POST times out but we sent the request...
   - Should there be a "retry in background and notify" mode?

5. **Per-endpoint configuration?**
   - Different endpoints have different characteristics
   - `/health` should have short timeout, no retry
   - `/process-payment` should have idempotency-key, careful retry
   - How to express this cleanly?

---

## Part 8: Research Tasks

- [x] Survey real-world API error responses (Stripe, Twilio, GitHub, etc.)
      → See `docs/research/analysis-payment-gems.md`, `analysis-platform-apis.md`
- [x] Document common header patterns (rate limiting, deprecation, etc.)
      → See Part 9 below and `docs/research/` analyses
- [x] Analyze Ruby HTTP client architectures (Faraday, HTTParty, Excon)
      → See `docs/research/analysis-http-clients.md`
- [x] Analyze data/infrastructure clients (Redis, Elasticsearch, Sidekiq)
      → See `docs/research/analysis-data-clients.md`
- [x] Survey Ruby AI/ML gem ecosystem
      → See `docs/research/research-ruby-ai-gems.md`
- [ ] Analyze httpx plugin architecture for integration points
- [ ] Prototype tagged-tuple wrapper around httpx
- [ ] Test with intentionally broken servers (chaos testing)

---

---

## Part 9: Real-World API Research

### 9.1 Top 50 Ruby API Gems by Downloads

**TIER 1: 100M+ Downloads (Infrastructure-level)**

| Rank | Gem | Downloads | Category |
|------|-----|-----------|----------|
| 1 | aws-sdk-core | 1,571M | Cloud infrastructure |
| 2 | faraday | 1,092M | HTTP client middleware |
| 3 | redis | 523M | Data store |
| 4 | rest-client | 446M | HTTP client |
| 5 | httparty | 425M | HTTP client |
| 6 | pg | 413M | Database |
| 7 | octokit | 349M | GitHub API |
| 8 | google-apis-core | 232M | Google APIs |
| 9 | mysql2 | 222M | Database |
| 10 | elasticsearch | 197M | Search |
| 11 | http | 189M | HTTP client |
| 12 | newrelic_rpm | 172M | Monitoring |
| 13 | twilio-ruby | 115M | Communications |
| 14 | sentry-ruby | 114M | Error tracking |
| 15 | stripe | 102M | Payments |

**TIER 2: 20-100M Downloads (Major Services)**

| Rank | Gem | Downloads | Category |
|------|-----|-----------|----------|
| 16 | mongo | 97M | Database |
| 17 | graphql-client | 84M | GraphQL |
| 18 | slack-ruby-client | 77M | Messaging |
| 19 | rollbar | 70M | Error tracking |
| 20 | sequel | 65M | Database |
| 21 | bugsnag | 61M | Error tracking |
| 22 | jira-ruby | 61M | Project management |
| 23 | sendgrid-ruby | 52M | Email |
| 24 | restforce | 50M | Salesforce |
| 25 | airbrake | 47M | Error tracking |
| 26 | opensearch-ruby | 46M | Search |
| 27 | zendesk_api | 41M | Support |
| 28 | pusher | 41M | Realtime |
| 29 | honeybadger | 36M | Error tracking |
| 30 | koala | 29M | Facebook |

**TIER 3: 5-20M Downloads (Popular Services)**

| Rank | Gem | Downloads | Category |
|------|-----|-----------|----------|
| 31 | asana | 28M | Project management |
| 32 | twitter | 26M | Social |
| 33 | braintree | 25M | Payments |
| 34 | intercom | 24M | Support |
| 35 | plaid | 21M | Banking |
| 36 | cloudinary | 18M | Media |
| 37 | gibbon | 17M | Email (Mailchimp) |
| 38 | postmark | 17M | Email |
| 39 | shopify_api | 11M | E-commerce |
| 40 | chargebee | 10M | Billing |

**Observations:**
- HTTP clients dominate the top 10 (faraday, rest-client, httparty, http)
- Error tracking services are heavily represented (5 in top 30)
- Payment/billing services appear multiple times
- Database clients mixed with API clients

### 9.1.1 Extended Survey: Top 100 Ruby API Gems

From comprehensive research across RubyGems.org, GitHub, and community resources:

**By Category Distribution:**

| Category | Count | Top Examples |
|----------|-------|--------------|
| Cloud Infrastructure | 8 | aws-sdk-*, fog-aws, google-cloud-* |
| HTTP Clients | 4 | faraday, httparty, rest-client, http |
| Payment Processing | 6 | stripe, braintree, activemerchant, square, paypal, plaid |
| Communication (SMS/Email) | 6 | twilio, sendgrid, mailgun, postmark, nexmo, messagebird |
| Social Media | 5 | koala, twitter/x, slack, instagram (deprecated), linkedin |
| Error Tracking | 5 | sentry, newrelic, rollbar, bugsnag, airbrake, honeybadger |
| Search | 3 | elasticsearch, algolia, opensearch |
| E-commerce | 2 | shopify_api, activemerchant |
| Authentication | 2+ | omniauth (194M), devise |
| AI/ML | 4 | openai, anthropic, replicate, hugging-face |

**Key Ecosystem Insights:**

1. **AWS Dominates Cloud** - 5 of top 10 gems are AWS SDK components
   - aws-sdk-core: 1,571M downloads
   - aws-sigv4, aws-partitions, aws-eventstream, jmespath: 1,200M+ each

2. **Faraday is the Foundation** - 1,091M downloads
   - Most API gems build on Faraday middleware
   - Provides adapter pattern over Net::HTTP, etc.
   - Rack-inspired request/response cycle

3. **Payment Processing is Critical**
   - Stripe (102M) + ActiveMerchant (since 2006) + Braintree
   - ActiveMerchant provides unified interface across 100+ gateways
   - Maintained by Shopify - production use for 18+ years

4. **Error Tracking is Pervasive**
   - 5 competing services in top 50
   - Sentry (114M), NewRelic (172M), Rollbar (70M), Bugsnag (61M), Airbrake (47M)
   - Indicates universal need for error visibility

5. **Social Media Gems Are Volatile**
   - Instagram gem: archived (Facebook ended API access)
   - Twitter gem: deprecated, replaced by 'x' gem
   - API policy changes break gems - maintenance risk

6. **OmniAuth is Authentication Standard**
   - 194M downloads for core gem
   - Dozens of strategy gems (google-oauth2, facebook, github, twitter)
   - De facto standard for OAuth in Ruby

7. **AI/ML is Emerging Category**
   - openai, anthropic, replicate, hugging-face
   - Newer gems, growing rapidly
   - Different patterns (streaming, long-running, expensive operations)

**Foundation Layer (HTTP Clients):**

| Gem | Downloads | Philosophy |
|-----|-----------|------------|
| faraday | 1,091M | Middleware-based, adapter pattern |
| rest-client | 446M | Simple DSL, Sinatra-inspired |
| httparty | 425M | "Makes HTTP fun again" |
| http | 189M | Chainable, streaming-friendly |

All API gems ultimately depend on one of these. Faraday's middleware pattern
enables composition (auth, retry, logging as separate concerns).

### 9.2 Stripe Error Handling Patterns

**Error Response Structure:**
```json
{
  "error": {
    "type": "card_error | api_error | idempotency_error | invalid_request_error",
    "message": "Human-readable message",
    "code": "card_declined | expired_card | ...",
    "param": "Which parameter caused error",
    "doc_url": "Link to docs",
    "decline_code": "Card-specific decline reason"
  }
}
```

**Key Insights:**
- Uses 402 for payment failures (unusual but semantic)
- Uses 424 for external dependency failures
- Idempotency keys get their own error type
- Error `type` is coarse, `code` is specific
- `param` field enables form validation UX

**Rate Limiting:**
- Returns 429 with recommendation for exponential backoff
- No specific Retry-After header mentioned

### 9.3 GitHub Error Handling Patterns

**Error Response Structure:**
```json
{
  "message": "Validation Failed",
  "errors": [
    {
      "resource": "Issue",
      "field": "title",
      "code": "missing_field"
    }
  ]
}
```

**Error Codes:**
- `missing` - Resource doesn't exist
- `missing_field` - Required field omitted
- `invalid` - Field format wrong
- `already_exists` - Uniqueness violation
- `unprocessable` - Invalid value

**Key Insights:**
- 404 intentionally masks private resource existence (security)
- Rate limiting uses `x-ratelimit-remaining`, `x-ratelimit-reset`, `retry-after`
- 10 second timeout causes server error (not timeout status)

### 9.4 AWS SDK Error Handling Patterns

**Error Hierarchy (33+ error classes):**

```
Aws::Errors
├── ServiceError (base for AWS errors)
├── Credential Errors
│   ├── MissingCredentialsError
│   ├── InvalidCredentialSourceError
│   └── InvalidSSOCredentials
├── Region/Endpoint Errors
│   ├── MissingRegionError
│   ├── InvalidRegionError
│   └── NoSuchEndpointError
├── Configuration Errors
│   ├── NoSuchProfileError
│   └── SourceProfileCircularReferenceError
└── Operational Errors
    ├── ChecksumError
    └── RetryCapacityNotAvailableError
```

**Key Insights:**
- Errors are highly specific (33+ types)
- Distinguishes config errors from runtime errors
- Has `RetryCapacityNotAvailableError` - retry budget exhausted
- Credential errors separated from service errors

### 9.5 RFC 7807 - Problem Details for HTTP APIs

**Standard Structure:**
```json
{
  "type": "https://example.com/probs/out-of-credit",
  "title": "You do not have enough credit",
  "status": 403,
  "detail": "Your current balance is 30, but that costs 50",
  "instance": "/account/12345/transactions/abc"
}
```

**Key Fields:**
- `type` - URI identifying problem category (primary identifier)
- `title` - Human-readable summary (consistent per type)
- `status` - HTTP status (duplicated for convenience)
- `detail` - This specific occurrence explanation
- `instance` - URI identifying this specific occurrence

**Content-Type:** `application/problem+json`

**Extension:** Custom fields allowed, must be 3+ chars starting with letter

### 9.6 Common Patterns Across APIs

| Pattern | Stripe | GitHub | AWS | RFC 7807 |
|---------|--------|--------|-----|----------|
| Error type/code | ✓ type + code | ✓ code | ✓ class hierarchy | ✓ type URI |
| Human message | ✓ message | ✓ message | ✓ message | ✓ title + detail |
| Field-level errors | ✓ param | ✓ errors[] | varies | extension |
| Doc links | ✓ doc_url | ✗ | ✗ | ✓ type URI |
| Request ID | ✓ | ✓ | ✓ | ✓ instance |
| Retry-After | ✗ explicit | ✓ header | ✓ | n/a |

### 9.7 Ruby Gem Error Handling Patterns (Source Code Analysis)

#### Stripe Ruby Gem - Rich Error Hierarchy

```
StripeError (base)
├── Attributes: message, code, error, http_body, http_headers,
│               http_status, json_body, request_id, response
├── AuthenticationError
├── APIConnectionError      ← Network/TLS issues
├── APIError                ← Generic/unknown
├── IdempotencyError        ← Idempotency key issues
├── PermissionError
├── RateLimitError
├── TemporarySessionExpiredError
├── CardError               + param attribute
├── InvalidRequestError     + param attribute
└── SignatureVerificationError + sig_header attribute
```

**Key Insight:** Every error carries full HTTP context (status, headers, body, request_id).
The `param` attribute on CardError/InvalidRequestError enables field-level error handling.

#### Octokit (GitHub) - HTTP Status Mapped to Semantic Errors

```
Octokit::Error (base)
├── ClientError (4xx)
│   ├── BadRequest (400)
│   ├── Unauthorized (401)
│   │   └── OneTimePasswordRequired  ← OTP delivery method in headers
│   ├── Forbidden (403)
│   │   ├── TooManyRequests         ← Rate limiting
│   │   ├── TooManyLoginAttempts
│   │   ├── AbuseDetected           ← Suspicious activity
│   │   ├── RepositoryUnavailable   ← DMCA, etc.
│   │   ├── UnverifiedEmail
│   │   ├── AccountSuspended
│   │   ├── BillingIssue
│   │   └── SAMLProtected
│   ├── NotFound (404)
│   ├── Conflict (409)
│   ├── UnprocessableEntity (422)
│   │   ├── CommitIsNotPartOfPullRequest
│   │   └── PathDiffTooLarge
│   └── UnavailableForLegalReasons (451)
└── ServerError (5xx)
    ├── InternalServerError (500)
    ├── BadGateway (502)
    └── ServiceUnavailable (503)
```

**Key Insight:** Highly granular 403 errors - distinguishes rate limit from abuse from billing
from account issues. Each has different recovery strategy.

#### Slack Ruby Client - ok/error JSON Pattern

```ruby
# Response structure check
if body['ok'] == false
  error_message = body['error'] || body['errors'].map { |e| e['error'] }.join(',')
  error_class = Slack::Web::Api::Errors::ERROR_CLASSES[error_message]
  raise (error_class || SlackError).new(response)
end

# Special case for rate limiting
raise TooManyRequestsError if status == 429
```

**Key Insight:** HTTP 200 can still be an error (ok: false). Error code in body maps
to specific exception class. Redacts auth headers before raising.

#### Twilio Ruby - Minimal Error Handling

```ruby
# Only validates nil arguments
raise ArgumentError, 'sid cannot be nil' if sid.nil?

# All HTTP errors propagate from underlying client
# No retry logic in SDK - left to caller
```

**Key Insight:** Auto-generated SDK does minimal error handling. Trusts HTTP layer
to raise appropriate exceptions. Application handles all recovery.

#### AWS SDK - Configuration vs Runtime Errors

```
Aws::Errors
├── ServiceError (base for AWS service errors)
├── Credential Errors (config-time)
│   ├── MissingCredentialsError
│   ├── InvalidCredentialSourceError
│   └── InvalidSSOCredentials
├── Region/Endpoint Errors (config-time)
│   ├── MissingRegionError
│   ├── InvalidRegionError
│   └── NoSuchEndpointError
├── Configuration Errors (config-time)
│   ├── NoSuchProfileError
│   └── SourceProfileCircularReferenceError
└── Operational Errors (runtime)
    ├── ChecksumError
    └── RetryCapacityNotAvailableError  ← Retry budget exhausted!
```

**Key Insight:** Clear separation of configuration errors (human must fix) vs
runtime errors (might be transient). Has explicit "retry budget exhausted" error.

### 9.8 Error Handling Philosophy Comparison

| Gem | Philosophy | Retry Logic | Field Errors | HTTP Context |
|-----|------------|-------------|--------------|--------------|
| **Stripe** | Rich hierarchy | None in SDK | ✓ param | Full |
| **Octokit** | HTTP-semantic | None in SDK | Via response | Full |
| **Slack** | ok/error JSON | None in SDK | Via response | Partial |
| **Twilio** | Propagate up | None in SDK | Via response | Minimal |
| **AWS** | Config vs runtime | Has budget | Varies | Full |

**Common Pattern:** None of these SDKs do retry logic internally. All propagate
errors to the caller. This is intentional - retry strategy depends on application
context (idempotency, consistency requirements, etc).

### 9.9 Implications for Kozo

1. **Error classification should be hierarchical**
   - Coarse: transport / http / api / validation
   - Fine: specific codes within each (like Octokit's 403 subtypes)

2. **Field-level errors are common**
   - Need to surface which parameter caused the error
   - Stripe's `param` attribute is the model

3. **Request IDs are universal**
   - Always capture and surface for debugging
   - Include in error responses

4. **Idempotency is first-class**
   - Stripe has dedicated idempotency_error type
   - Need to support idempotency keys

5. **Rate limiting needs rich handling**
   - Track remaining requests
   - Respect Retry-After
   - Preemptively slow down near limit

6. **Retry budgets matter**
   - AWS has explicit "retry capacity exhausted" error
   - Don't retry forever

7. **Config errors vs runtime errors**
   - AWS pattern: config errors = human must fix, don't retry
   - Runtime errors = might be transient, consider retry

8. **HTTP 200 can be an error**
   - Slack pattern: ok: false in body
   - GraphQL pattern: data + errors
   - Must parse body to know success

9. **SDKs don't retry - but Kozo should**
   - Current gems leave retry to caller
   - Kozo opportunity: principled retry with developer intent

---

## References

- Release It! - Stability patterns
- httpx documentation and source
- RFC 7231 (HTTP/1.1 Semantics)
- RFC 7807 (Problem Details for HTTP APIs)
- Stripe API error handling docs
- GitHub API troubleshooting docs
- AWS SDK for Ruby error classes
- GraphQL spec error handling
- JSON-RPC 2.0 spec
