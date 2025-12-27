# Analysis of Stripe Ruby and ActiveMerchant Gems

This document provides a deep analysis of the Stripe Ruby (`stripe-ruby`) and ActiveMerchant (`active_merchant`) gems to inform the design of the Kozo HTTP abstraction layer for Umi.

---

## Executive Summary

Both gems are production-grade payment processing libraries with years of real-world usage. They take notably different approaches:

| Aspect | Stripe Ruby | ActiveMerchant |
|--------|-------------|----------------|
| **Philosophy** | Single API, rich client | Gateway abstraction layer |
| **Error Model** | Exception hierarchy | Response object with `success?` |
| **Retry Strategy** | Built-in exponential backoff | Configurable simple retries |
| **HTTP Client** | Net::HTTP with connection pooling | Net::HTTP per-request |
| **Configuration** | Global + per-request override | Class attributes + instance options |
| **Resources** | Dynamic object model | Simple hashes |

---

## 1. Error Handling Patterns

### Stripe Ruby

**Location:** `lib/stripe/errors.rb`, `lib/stripe/api_requestor.rb`

#### Error Hierarchy

```
StandardError
  |
  StripeError (base class)
    |-- AuthenticationError   (401)
    |-- APIConnectionError    (network failures)
    |-- APIError              (generic 5xx)
    |-- CardError             (402 - card issues)
    |-- IdempotencyError      (400/404 with idempotency_error type)
    |-- InvalidRequestError   (400/404 - bad params)
    |-- PermissionError       (403)
    |-- RateLimitError        (429)
    |-- SignatureVerificationError (webhook)
    |-- TemporarySessionExpiredError
    |
    OAuth::OAuthError
      |-- InvalidClientError
      |-- InvalidGrantError
      |-- InvalidRequestError
      |-- InvalidScopeError
      |-- UnsupportedGrantTypeError
      |-- UnsupportedResponseTypeError
```

#### Error Attributes

Each `StripeError` carries rich context:
- `message` - Human-readable error message
- `http_status` - HTTP status code
- `http_body` - Raw response body
- `http_headers` - Response headers (includes `request-id`, `idempotent-replayed`)
- `json_body` - Parsed JSON response
- `code` - Stripe-specific error code (e.g., `card_declined`, `lock_timeout`)
- `request_id` - Request ID for debugging
- `error` - Constructed `ErrorObject` with structured error data

```ruby
# Example: CardError also has param attribute
class CardError < StripeError
  attr_reader :param  # Which parameter caused the error
end
```

#### Retryable vs Non-Retryable Distinction

Stripe has **explicit** retry logic in `APIRequestor.should_retry?`:

```ruby
def self.should_retry?(error, num_retries:, config:)
  return false if num_retries >= config.max_network_retries

  case error
  when Net::OpenTimeout, Net::ReadTimeout
    true  # Always retry timeouts
  when EOFError, Errno::ECONNREFUSED, Errno::ECONNRESET,
       Errno::EHOSTUNREACH, Errno::ETIMEDOUT, SocketError
    true  # Retry connection issues
  when Stripe::StripeError
    # Server can OVERRIDE retry behavior via header!
    return false if error.http_headers["stripe-should-retry"] == "false"
    return true if error.http_headers["stripe-should-retry"] == "true"

    return true if error.http_status == 409  # Conflict

    # 429 only retried for lock_timeout, NOT general rate limiting
    return true if error.http_status == 429 && error.code == "lock_timeout"

    true if error.http_status >= 500  # Server errors
  else
    false
  end
end
```

**Key insight:** The `stripe-should-retry` HTTP header allows the server to communicate retry appropriateness. This is a sophisticated pattern that pushes retry decisions to the server when it has better information.

#### Rate Limiting

- Returns 429 with `RateLimitError`
- Rate limiting 429s are **NOT retried** by default (would make congestion worse)
- Only `lock_timeout` 429s are retried (lock contention, transient)
- No built-in backpressure or rate limiter - relies on server to throttle

### ActiveMerchant

**Location:** `lib/active_merchant/errors.rb`, `lib/active_merchant/network_connection_retries.rb`

#### Error Hierarchy

```
StandardError
  |
  ActiveMerchantError (base)
    |-- ConnectionError (network issues)
    |     |-- RetriableConnectionError
    |-- ResponseError (HTTP errors)
    |     |-- OAuthResponseError
    |-- ClientCertificateError
    |-- InvalidResponseError

Billing::Error (separate namespace)
```

Notably **simpler** than Stripe:
- `ConnectionError` wraps the original exception in `triggering_exception`
- `RetriableConnectionError` signals that retry is appropriate (e.g., ECONNREFUSED)
- `ResponseError` wraps failed HTTP responses

#### Response Object Pattern

ActiveMerchant uses a **different paradigm**: instead of exceptions for business errors, it returns `Response` objects:

```ruby
class Response
  attr_reader :params, :message, :authorization,
              :avs_result, :cvv_result, :error_code,
              :emv_authorization, :network_transaction_id

  def success?
    @success
  end

  def failure?
    !success?
  end

  def test?
    @test
  end

  def fraud_review?
    @fraud_review
  end
end
```

**Usage:**
```ruby
response = gateway.purchase(amount, credit_card)
if response.success?
  # handle success
else
  puts response.message     # Error message
  puts response.error_code  # Standardized error code
end
```

#### Standardized Error Codes

ActiveMerchant defines gateway-agnostic error codes in `Gateway::STANDARD_ERROR_CODE`:

```ruby
STANDARD_ERROR_CODE = {
  incorrect_number: 'incorrect_number',
  invalid_number: 'invalid_number',
  invalid_expiry_date: 'invalid_expiry_date',
  invalid_cvc: 'invalid_cvc',
  expired_card: 'expired_card',
  incorrect_cvc: 'incorrect_cvc',
  incorrect_zip: 'incorrect_zip',
  incorrect_address: 'incorrect_address',
  incorrect_pin: 'incorrect_pin',
  card_declined: 'card_declined',
  processing_error: 'processing_error',
  call_issuer: 'call_issuer',
  pickup_card: 'pick_up_card',
  config_error: 'config_error',
  test_mode_live_card: 'test_mode_live_card',
  unsupported_feature: 'unsupported_feature',
  invalid_amount: 'invalid_amount'
}
```

Each gateway implementation maps its specific errors to these standard codes.

#### Retryable Errors

```ruby
DEFAULT_CONNECTION_ERRORS = {
  EOFError               => 'The remote server dropped the connection',
  Errno::ECONNRESET      => 'The remote server reset the connection',
  Timeout::Error         => 'The connection to the remote server timed out',
  Errno::ETIMEDOUT       => 'The connection to the remote server timed out',
  SocketError            => 'The connection to the remote server could not be established',
  Errno::EHOSTUNREACH    => 'The connection to the remote server could not be established',
  OpenSSL::SSL::SSLError => 'The SSL connection to the remote server could not be established'
}
```

Special handling for `Errno::ECONNREFUSED` which becomes `RetriableConnectionError`.

---

## 2. Resilience Features

### Stripe Ruby

#### Retry Logic with Exponential Backoff

**Configuration:**
```ruby
Stripe.max_network_retries = 2  # Default: 2
Stripe.initial_network_retry_delay = 0.5  # seconds
Stripe.max_network_retry_delay = 5  # seconds
```

**Implementation in `APIRequestor.sleep_time`:**
```ruby
def self.sleep_time(num_retries, config:)
  # Exponential backoff: delay * 2^(retries-1)
  sleep_seconds = [
    config.initial_network_retry_delay * (2**(num_retries - 1)),
    config.max_network_retry_delay,
  ].min

  # Jitter: random value between 50-100% of calculated delay
  sleep_seconds *= (0.5 * (1 + rand))

  # Never sleep less than initial delay
  [config.initial_network_retry_delay, sleep_seconds].max
end
```

**Jitter prevents thundering herd** when many clients retry simultaneously.

#### Timeout Configuration

**Separate timeouts for different phases:**
```ruby
Stripe.open_timeout = 30   # Connection establishment
Stripe.read_timeout = 80   # Reading response (80s is HIGH - payments can be slow)
Stripe.write_timeout = 30  # Writing request body (Ruby 2.6+)
```

When any timeout changes, connection managers are cleared to pick up new settings.

#### Idempotency Key Support

```ruby
# Automatic generation for POST/DELETE when retries enabled
if %i[post delete].include?(method) && config.max_network_retries > 0
  headers["Idempotency-Key"] ||= SecureRandom.uuid
end

# Or manual:
Stripe::Charge.create({ amount: 1000 }, { idempotency_key: 'unique-key' })
```

The idempotency key is preserved across retries, making retries safe.

#### No Built-in Circuit Breaker

Stripe does NOT implement circuit breaker patterns. It relies on:
1. Retry limits
2. Server-side rate limiting
3. The `stripe-should-retry` header for server-controlled retry decisions

### ActiveMerchant

#### Simple Retry Logic

**Configuration:**
```ruby
Connection::MAX_RETRIES = 3
base.class_attribute :max_retries
base.max_retries = Connection::MAX_RETRIES

base.class_attribute :retry_safe
base.retry_safe = false  # Must explicitly enable!
```

**Implementation in `NetworkConnectionRetries`:**
```ruby
def retry_network_exceptions(options = {})
  retries = options[:max_retries] || DEFAULT_RETRIES

  begin
    result = yield
  rescue ActiveMerchant::RetriableConnectionError => e
    retries -= 1
    retry unless retries.zero?
    raise ActiveMerchant::ConnectionError.new(e.message, e)
  rescue ActiveMerchant::ConnectionError, ActiveMerchant::InvalidResponseError => e
    retries -= 1
    # Only retry if retry_safe is set!
    retry if (options[:retry_safe] || retry_safe) && !retries.zero?
    raise
  end
end
```

**No exponential backoff!** Retries happen immediately. This is simpler but potentially problematic for transient failures.

#### Timeout Configuration

```ruby
Connection::OPEN_TIMEOUT = 60  # seconds
Connection::READ_TIMEOUT = 60  # seconds

# Per-gateway configuration:
base.class_attribute :open_timeout
base.open_timeout = Connection::OPEN_TIMEOUT
base.class_attribute :read_timeout
base.read_timeout = Connection::READ_TIMEOUT
```

#### No Idempotency Built-In

ActiveMerchant gateways must handle idempotency individually. The Stripe gateway within ActiveMerchant does pass idempotency keys:

```ruby
headers['Idempotency-Key'] = options[:idempotency_key] if options[:idempotency_key]
```

#### No Circuit Breaker

Like Stripe, no circuit breaker pattern.

---

## 3. API Design Patterns

### Stripe Ruby

#### Configuration: Global + Per-Request

**Global configuration:**
```ruby
Stripe.api_key = 'sk_test_...'
Stripe.api_version = '2024-01-01'
Stripe.max_network_retries = 2
```

**Per-request override:**
```ruby
Stripe::Customer.list(
  { limit: 10 },
  {
    api_key: 'sk_test_other',
    stripe_account: 'acct_...',
    idempotency_key: 'unique-key',
    stripe_version: '2023-01-01'
  }
)
```

**Client-based (modern, recommended):**
```ruby
client = Stripe::StripeClient.new(
  'sk_test_...',
  stripe_account: 'acct_...',
  stripe_version: '2024-01-01'
)
client.v1.customers.list()
```

#### Resource/Model Pattern

Stripe uses **dynamic objects** that feel like ActiveRecord but aren't:

```ruby
class StripeObject
  include Enumerable

  # Dynamic accessors from API response
  def initialize(id = nil, opts = {})
    @values = {}
    @unsaved_values = Set.new
    # ... builds accessors dynamically
  end

  # Method missing for dynamic access
  def method_missing(name, *args)
    if name.to_s.end_with?("=")
      add_accessors([name.to_s[0...-1].to_sym], ...)
      # ...
    elsif @values.key?(name)
      @values[name]
    else
      super
    end
  end
end

class APIResource < StripeObject
  include APIOperations::Request
  include APIOperations::Create  # adds .create
  include APIOperations::Save    # adds #save (deprecated)
  include APIOperations::Delete  # adds #delete

  def self.retrieve(id, opts = {})
    instance = new(id)
    instance.refresh
  end

  def refresh
    # Fetches latest from API
  end
end
```

**Mixins for CRUD operations:**
- `APIOperations::Create` - `.create(params, opts)`
- `APIOperations::Save` - `#save` (deprecated) / `.update(id, params, opts)`
- `APIOperations::Delete` - `#delete`
- `APIOperations::List` - `.list(params, opts)`

#### Pagination

`ListObject` implements `Enumerable` with cursor-based pagination:

```ruby
class ListObject < StripeObject
  include Enumerable

  attr_accessor :filters  # Preserves limit, expand, etc.

  def each(&blk)
    data.each(&blk)  # Current page only
  end

  def auto_paging_each(&blk)
    page = self
    loop do
      page.each(&blk)
      page = page.next_page
      break if page.empty?
    end
  end

  def next_page(params = {}, opts = {})
    return self.class.empty_list(opts) unless has_more
    last_id = data.last.id
    params = filters.merge(starting_after: last_id).merge(params)
    list(params, opts)
  end
end
```

**Returns Enumerator when no block:**
```ruby
customers = Stripe::Customer.list.auto_paging_each
customers.each { |c| puts c.email }
```

#### Streaming Support

```ruby
def execute_request_stream(method, path, base_address, params:, opts:, &read_body_chunk_block)
  # ...
  response_block = lambda do |response|
    response.read_body(&read_body_chunk_block) unless should_handle_as_error(response.code.to_i)
  end
  # ...
end
```

### ActiveMerchant

#### Configuration: Class Attributes + Instance

**Class-level defaults:**
```ruby
class Gateway
  class_attribute :money_format
  self.money_format = :dollars

  class_attribute :default_currency
  class_attribute :supported_cardtypes
  class_attribute :test_url, :live_url
  # ...
end
```

**Instance-level options:**
```ruby
gateway = StripeGateway.new(
  login: 'sk_test_...',
  fee_refund_login: 'sk_test_other'
)

# Options per-request
response = gateway.purchase(1000, credit_card, {
  currency: 'USD',
  description: 'Order #123',
  metadata: { order_id: 123 }
})
```

#### Simple Response Objects

```ruby
response = gateway.purchase(1000, credit_card)

response.success?        # true/false
response.message         # "Transaction approved" or error
response.authorization   # Transaction ID
response.params          # Raw response hash
response.avs_result      # Address verification
response.cvv_result      # CVV verification
response.error_code      # Standardized error code
```

#### No Pagination

ActiveMerchant doesn't deal with paginated list operations - it's focused on transactions.

#### No Streaming

No streaming support - responses are small (JSON transaction results).

---

## 4. Ruby Idioms

### Stripe Ruby

#### Heavy Use of Blocks

```ruby
# Configuration block
Stripe::StripeConfiguration.setup do |config|
  config.api_key = 'sk_test_...'
end

# Instrumentation callbacks
Stripe::Instrumentation.subscribe(:request_end) do |event|
  StatsD.timing('stripe.request', event.duration)
end
```

#### Method Chaining (Fluent Interface)

```ruby
client.v1.customers.list({ limit: 10 })
       .auto_paging_each
       .select { |c| c.email.include?('@') }
```

#### DSL for Resource Definition

```ruby
class Customer < APIResource
  extend APIOperations::Create
  extend APIOperations::List
  include APIOperations::Save
  include APIOperations::Delete

  custom_method :create_funding_instructions, http_verb: :post
  save_nested_resource :source
end
```

#### Forwardable for Delegation

```ruby
class << self
  extend Forwardable
  def_delegators :@config, :api_key, :api_key=
  def_delegators :@config, :max_network_retries, :max_network_retries=
  # ...
end
```

#### No Pattern Matching

Stripe was written before Ruby 3.0 pattern matching. Uses traditional conditionals.

### ActiveMerchant

#### Mixin Modules

```ruby
class Gateway
  include PostsData         # HTTP methods
  include CreditCardFormatting
  include Versionable
end

module PostsData
  def self.included(base)
    base.class_attribute :ssl_strict
    base.ssl_strict = true
    # ...
  end

  def ssl_post(endpoint, data, headers = {})
    ssl_request(:post, endpoint, data, headers)
  end
end
```

#### class_attribute (Rails-style)

```ruby
class Gateway
  class_attribute :money_format
  class_attribute :supported_cardtypes
  class_attribute :default_currency
end
```

#### Refinements (Modern Ruby)

```ruby
class Connection
  using NetHttpSslConnection  # Refinement for SSL features
end
```

#### MultiResponse for Compound Operations

```ruby
def verify(payment, options = {})
  MultiResponse.run(:use_first_response) do |r|
    r.process { authorize(auth_minimum_amount, payment, options) }
    r.process(:ignore_result) { void(r.authorization, options) }
  end
end
```

---

## 5. HTTP Client Layer

### Stripe Ruby

**Location:** `lib/stripe/connection_manager.rb`, `lib/stripe/api_requestor.rb`

#### Uses Net::HTTP with Connection Pooling

```ruby
class ConnectionManager
  def initialize(config = Stripe.config)
    @active_connections = {}  # {[host, port] => Net::HTTP}
    @mutex = Mutex.new
  end

  def connection_for(uri)
    @mutex.synchronize do
      u = URI.parse(uri)
      connection = @active_connections[[u.host, u.port]]

      if connection.nil?
        connection = create_connection(u)
        connection.start
        @active_connections[[u.host, u.port]] = connection
      end

      connection
    end
  end
end
```

#### Thread-Local Connection Managers

```ruby
class APIRequestor
  def self.current_thread_context
    Thread.current[:api_requestor__internal_use_only] ||= ThreadContext.new
  end

  def self.default_connection_manager(config = Stripe.config)
    current_thread_context.default_connection_managers[config.key] ||= begin
      ConnectionManager.new(config)
    end
  end
end
```

#### Connection Manager Garbage Collection

Unused connection managers are garbage collected after 120 seconds:

```ruby
CONNECTION_MANAGER_GC_LAST_USED_EXPIRY = 120  # seconds
CONNECTION_MANAGER_GC_PERIOD = 60  # check frequency

def self.maybe_gc_connection_managers
  # Prunes connection managers not used in 2 minutes
end
```

#### HTTP Keep-Alive

```ruby
connection.keep_alive_timeout = 30  # seconds (Go's default)
```

### ActiveMerchant

**Location:** `lib/active_merchant/connection.rb`, `lib/active_merchant/posts_data.rb`

#### Net::HTTP Without Pooling

```ruby
class Connection
  def request(method, body, headers = {})
    retry_exceptions(max_retries: max_retries) do
      http.start unless http.started?  # Opens connection
      result = http.post(endpoint.request_uri, body, headers)
      result
    end
  ensure
    http.finish if http.started?  # Closes connection!
  end
end
```

**Connection closed after EVERY request.** No pooling.

#### New Connection Per Request

```ruby
module PostsData
  def raw_ssl_request(method, endpoint, data, headers = {})
    connection = new_connection(endpoint)  # New connection each time
    connection.open_timeout = open_timeout
    connection.read_timeout = read_timeout
    # ...
    connection.request(method, data, headers)
  end

  def new_connection(endpoint)
    Connection.new(endpoint)
  end
end
```

#### SSL Configuration

```ruby
def configure_ssl(http)
  return unless endpoint.scheme == 'https'

  http.use_ssl = true
  http.ssl_version = ssl_version if ssl_version
  http.min_version = min_version if min_version  # TLS 1.1+
  http.max_version = max_version if max_version

  if verify_peer
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.ca_file = ca_file  # Bundled CA certs
  else
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  end
end
```

---

## 6. Notable Features

### Stripe Ruby

#### Instrumentation/Observability

Comprehensive hooks for monitoring:

```ruby
Stripe::Instrumentation.subscribe(:request_begin) do |event|
  puts "Starting #{event.method} #{event.path}"
end

Stripe::Instrumentation.subscribe(:request_end) do |event|
  puts "#{event.method} #{event.path}: #{event.http_status} in #{event.duration}s"
  puts "Retries: #{event.num_retries}"
  puts "Request ID: #{event.request_id}"
end
```

#### Telemetry

Optional telemetry sends request timing back to Stripe:

```ruby
class StripeRequestMetrics
  attr_accessor :request_id, :request_duration_ms, :usage

  def payload
    { request_id: request_id, request_duration_ms: request_duration_ms }
  end
end

# Sent in X-Stripe-Client-Telemetry header
headers["X-Stripe-Client-Telemetry"] = JSON.generate(
  last_request_metrics: @last_request_metrics.pop&.payload
)
```

#### Webhook Signature Verification

```ruby
Stripe::Webhook.construct_event(
  payload,
  sig_header,
  endpoint_secret,
  tolerance: 300  # seconds
)

# Verifies:
# 1. Valid HMAC signature
# 2. Timestamp within tolerance (replay protection)
```

#### Type Annotations (RBI/Sorbet)

Modern Stripe versions ship with RBI files for static type checking.

### ActiveMerchant

#### Gateway Abstraction

The killer feature - unified API across 100+ payment gateways:

```ruby
# Works the same for any gateway
gateway.purchase(amount, credit_card)
gateway.authorize(amount, credit_card)
gateway.capture(amount, authorization)
gateway.refund(amount, authorization)
gateway.void(authorization)
gateway.store(credit_card)
```

#### Scrubbing Sensitive Data

Built-in transcript scrubbing for logs:

```ruby
def supports_scrubbing?
  true
end

def scrub(transcript)
  transcript.
    gsub(%r((Authorization: Basic )\w+), '\1[FILTERED]').
    gsub(%r((\[card\]\[number\]=)\d+), '\1[FILTERED]').
    gsub(%r((\[card\]\[cvc\]=)\d+), '\1[FILTERED]')
end
```

#### Credit Card Validation

Built-in Luhn check and card type detection:

```ruby
credit_card = CreditCard.new(
  number: '4242424242424242',
  month: '12',
  year: Time.now.year + 1,
  verification_value: '123'
)

credit_card.validate  # Returns array of errors
credit_card.brand     # :visa, :master, etc.
```

---

## 7. Design Implications for Kozo

### Error Handling Recommendations

1. **Rich error objects** like Stripe - include HTTP status, body, headers, request ID
2. **Consider both paradigms:**
   - Exceptions for infrastructure errors (network, auth)
   - Result objects for domain errors (optional, OTP-style tuples would fit Umi)
3. **Server-controlled retry hints** (like `stripe-should-retry` header) are powerful
4. **Standardized error codes** for cross-gateway compatibility

### Resilience Recommendations

1. **Exponential backoff with jitter** is essential - ActiveMerchant's immediate retry is naive
2. **Separate timeout configuration** (connect, read, write) provides fine-grained control
3. **Automatic idempotency key generation** for mutating requests when retries enabled
4. **Consider circuit breaker** - neither gem implements this, but Umi could

### HTTP Client Recommendations

1. **Connection pooling per-host** like Stripe - massive performance improvement
2. **Thread-local connection managers** for thread safety without global locks
3. **Connection manager GC** to clean up dead connections
4. **Keep-alive with reasonable timeout** (30s is good)

### API Design Recommendations

1. **Client object pattern** (like `StripeClient`) keeps configuration encapsulated
2. **Per-request option override** for multi-tenant scenarios
3. **Mixin modules for operations** (Create, List, etc.) allow composition
4. **Instrumentation hooks** for observability are essential

### Ruby Idioms to Adopt

1. **Forwardable for delegation** keeps code clean
2. **Thread-local contexts** for per-request state
3. **Blocks for configuration and callbacks**
4. **Consider pattern matching** for Ruby 3.x (neither gem uses it, opportunity to modernize)

### What to Avoid

1. **Per-request connections** (ActiveMerchant) - wasteful
2. **Immediate retries without backoff** (ActiveMerchant) - can worsen transient issues
3. **Deeply nested exception hierarchies** - keep it simple
4. **Global mutable state** - prefer client instances (Stripe's modern pattern)

---

## 8. Code Examples to Inform Design

### Ideal Error Pattern for Kozo (OTP-style)

```ruby
case kozo.request(:post, "/v1/charges", params, timeout: 30)
in [:ok, response]
  handle_success(response)
in [:error, :timeout, details]
  # Timeout, could retry
in [:error, :rate_limited, retry_after]
  sleep(retry_after)
  retry
in [:error, :auth_failed, _]
  raise AuthError
in [:error, :client_error, response]
  handle_validation_error(response)
in [:error, :server_error, response]
  # May retry
end
```

### Ideal Resilience Pattern for Kozo

```ruby
class Kozo::Client
  def initialize(config)
    @config = config
    @connection_pool = ConnectionPool.new(
      per_host_limit: 10,
      idle_timeout: 120.seconds,
      keep_alive: 30.seconds
    )
    @circuit_breaker = CircuitBreaker.new(
      failure_threshold: 5,
      reset_timeout: 60.seconds
    )
  end

  def request(method, path, params = {}, opts = {})
    @circuit_breaker.call do
      retry_with_backoff(opts[:max_retries] || @config.max_retries) do
        conn = @connection_pool.checkout(host)
        begin
          response = conn.request(method, path, params, opts)
          handle_response(response)
        ensure
          @connection_pool.checkin(conn)
        end
      end
    end
  end
end
```

### Ideal Instrumentation Pattern

```ruby
Kozo::Instrumentation.subscribe(:request) do |event|
  case event
  in { status: :begin, method:, path: }
    # Request starting
  in { status: :complete, method:, path:, duration:, http_status:, retries: }
    # Request completed
  in { status: :error, method:, path:, error:, retries: }
    # Request failed
  end
end
```

---

## Summary

Both gems are excellent references with complementary strengths:

- **Stripe Ruby**: Modern, well-engineered, great resilience patterns, rich observability
- **ActiveMerchant**: Battle-tested abstraction, clean response pattern, gateway portability

For Kozo, the recommendation is to combine:
- Stripe's connection management and retry logic
- ActiveMerchant's gateway abstraction pattern (if building abstractions over multiple services)
- OTP-style tagged tuples for results (aligns with Umi philosophy)
- Built-in circuit breaker (missing from both)
- Ruby 3.x pattern matching throughout

