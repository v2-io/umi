# Ruby HTTP Client Library Analysis

## Executive Summary

This document provides a deep analysis of three foundational Ruby HTTP client libraries:
**Faraday**, **HTTParty**, and **Excon**. Each takes a fundamentally different approach
to the same problem space, reflecting different design philosophies and use cases.

| Library   | Philosophy | Best For |
|-----------|------------|----------|
| Faraday   | Middleware/Rack-like abstraction | Flexibility, adapter switching, complex pipelines |
| HTTParty  | Simple DSL with class-level config | Quick API clients, Rails-style conventions |
| Excon     | Performance-first, low-level control | High-performance, persistent connections |

---

## 1. Faraday

**Repository**: https://github.com/lostisland/faraday
**Philosophy**: "HTTP client framework" - abstracts HTTP adapters behind a Rack-like middleware stack

### 1.1 Architecture

#### Core Abstractions

```
Faraday.new(url) -> Connection
  |
  v
Connection.get/post/etc -> Request
  |
  v
RackBuilder (middleware stack)
  |
  v
Adapter (net_http, patron, etc.)
  |
  v
Response
```

**Key Classes**:

- `Faraday::Connection` - The main entry point. Holds base URL, headers, params, SSL config, proxy settings. Delegates to `RackBuilder` for middleware and `Adapter` for HTTP execution.

- `Faraday::RackBuilder` - Manages the middleware stack. Inspired by Rack::Builder. Builds a chain of middleware that wraps an adapter at the bottom.

- `Faraday::Request` - Struct containing `http_method`, `path`, `params`, `headers`, `body`, `options`. Created per-request.

- `Faraday::Response` - Wraps response data with `status`, `headers`, `body`. Uses `on_complete` callbacks for async/parallel support.

- `Faraday::Env` - The "env hash" that flows through the middleware stack. Contains all request/response data.

- `Faraday::Adapter` - Base class for HTTP adapters. Each adapter (net_http, typhoeus, etc.) is a separate gem.

#### Middleware System

Faraday's middleware is modeled after Rack:

```ruby
# Middleware structure
class Faraday::Middleware
  def initialize(app, options = {})
    @app = app
    @options = options
  end

  def call(env)
    on_request(env) if respond_to?(:on_request)
    @app.call(env).on_complete do |response_env|
      on_complete(response_env) if respond_to?(:on_complete)
    end
  end
end
```

**Key insight**: Middleware can:
- Modify request before sending (`on_request`)
- Modify response after receiving (`on_complete`)
- Handle errors (`on_error`)

**Built-in middleware**:
- `Request::UrlEncoded` - form encoding
- `Request::Json` - JSON encoding
- `Request::Authorization` - auth headers
- `Response::RaiseError` - raises exceptions on 4xx/5xx
- `Response::Json` - JSON parsing
- `Response::Logger` - request/response logging

#### Adapter Pattern

Adapters are the HTTP execution layer. They implement:

```ruby
class Faraday::Adapter
  def call(env)
    # Set up response
    env.clear_body if env.needs_body?
    env.response = Response.new
    # Subclasses implement actual HTTP call
  end

  # Subclasses must implement:
  # - build_connection(env)
  # - perform_request(http, env)
end
```

**The net_http adapter** (in faraday-net_http gem) wraps Ruby's Net::HTTP:
- Maps Faraday timeouts to Net::HTTP timeouts
- Wraps Net::HTTP exceptions in Faraday exceptions
- Handles SSL configuration translation

### 1.2 Error Handling

#### Error Hierarchy

```ruby
Faraday::Error < StandardError
  attr_reader :response, :wrapped_exception

  Faraday::ClientError < Error           # 4xx base
    Faraday::BadRequestError             # 400
    Faraday::UnauthorizedError           # 401
    Faraday::ForbiddenError              # 403
    Faraday::ResourceNotFound            # 404
    Faraday::RequestTimeoutError         # 408
    Faraday::ConflictError               # 409
    Faraday::UnprocessableContentError   # 422
    Faraday::TooManyRequestsError        # 429

  Faraday::ServerError < Error           # 5xx base
  Faraday::TimeoutError < ServerError    # Adapter timeouts
  Faraday::NilStatusError < ServerError  # No status code

  Faraday::ConnectionFailed < Error      # Network errors
  Faraday::SSLError < Error              # SSL/TLS errors
  Faraday::ParsingError < Error          # Response parsing
```

**Design choice**: Errors are NOT raised by default. You must add `Response::RaiseError` middleware.

#### Timeout Handling

```ruby
# RequestOptions supports:
:timeout       # Generic timeout (fallback)
:open_timeout  # Connection establishment
:read_timeout  # Response reading
:write_timeout # Request writing
```

Adapters translate these to underlying library timeouts. The net_http adapter wraps:
- `Timeout::Error`
- `Errno::ETIMEDOUT`
- `Net::OpenTimeout`

All become `Faraday::TimeoutError`.

### 1.3 Resilience Features

**Built-in**: None in core. Faraday delegates resilience to middleware/adapters.

**Common patterns**:
- `faraday-retry` gem for retry logic
- Custom middleware for circuit breakers
- Adapter-level connection pooling (e.g., via net-http-persistent)

**Connection pooling**: Not in core. Adapters like `faraday-net_http_persistent` provide it.

### 1.4 Configuration

#### Global vs Per-Request

```ruby
# Global defaults
Faraday.default_adapter = :net_http
Faraday.default_connection_options = { ... }

# Connection-level (reusable)
conn = Faraday.new(url: 'https://api.example.com') do |f|
  f.request :json
  f.response :json
  f.adapter :net_http
end

# Request-level override
conn.get('/users') do |req|
  req.options.timeout = 5
  req.headers['X-Custom'] = 'value'
end
```

#### SSL Configuration

```ruby
Faraday::SSLOptions = Options.new(
  :verify,           # Boolean - verify peer
  :verify_hostname,  # Boolean - verify hostname
  :ca_file,          # String - CA file path
  :ca_path,          # String - CA directory
  :verify_mode,      # OpenSSL constant
  :cert_store,       # OpenSSL::X509::Store
  :client_cert,      # Client certificate
  :client_key,       # Client private key
  :verify_depth,     # Integer
  :version,          # SSL version
  :min_version,      # Minimum SSL version
  :max_version,      # Maximum SSL version
  :ciphers           # Cipher string
)
```

#### Proxy Support

```ruby
conn = Faraday.new(url: 'https://api.example.com') do |f|
  f.proxy = 'http://proxy.example.com:8080'
  # or
  f.proxy = {
    uri: 'http://proxy.example.com:8080',
    user: 'username',
    password: 'password'
  }
end
```

Also reads from `ENV['http_proxy']` unless `Faraday.ignore_env_proxy = true`.

### 1.5 API Design Patterns

#### Builder Pattern

```ruby
conn = Faraday.new('https://api.example.com') do |builder|
  builder.request :json
  builder.response :json
  builder.response :raise_error
  builder.adapter :net_http
end
```

#### Block-Based Request Customization

```ruby
response = conn.get('/users') do |req|
  req.params['page'] = 2
  req.headers['Authorization'] = 'Bearer token'
  req.options.timeout = 10
end
```

#### Response Handling

```ruby
response = conn.get('/users')
response.status         # 200
response.headers        # Hash-like
response.body           # String (or parsed if middleware)
response.success?       # true for 2xx
```

---

## 2. HTTParty

**Repository**: https://github.com/jnunemaker/httparty
**Philosophy**: "Makes http fun again" - Simple, Rails-like DSL

### 2.1 Architecture

#### Core Design

HTTParty uses Ruby's `include` pattern for class-level configuration:

```ruby
class Twitter
  include HTTParty
  base_uri 'https://api.twitter.com'
  default_timeout 5
  headers 'Accept' => 'application/json'
end

Twitter.get('/users/show.json', query: { screen_name: 'jnunemaker' })
```

**Key Classes**:

- `HTTParty` module - Mixed into classes, provides class methods for HTTP verbs and configuration.

- `HTTParty::Request` - The workhorse. Handles URI building, body encoding, authentication, redirects.

- `HTTParty::Response` - Wraps Net::HTTP response. Delegates to parsed response for Hash-like access.

- `HTTParty::ConnectionAdapter` - Creates and configures Net::HTTP instances.

- `HTTParty::Parser` - Response parsing (JSON, XML, etc.)

#### Request Flow

```
HTTParty.get(path, options)
  |
  v
ClassMethods.perform_request(Net::HTTP::Get, path, options)
  |
  v
Request.new(http_method, path, options)
  |
  v
Request#perform
  |-- ConnectionAdapter.call(uri, options) -> Net::HTTP
  |-- setup_raw_request (headers, body, auth)
  |-- http.request(@raw_request)
  |
  v
handle_response(raw_body)
  |-- handle redirects (recursively)
  |-- decompress
  |-- encode text
  |
  v
Response.new(request, last_response, parsed_block)
```

#### No Middleware - Direct Integration

Unlike Faraday, HTTParty has no middleware layer. Features are built directly into Request:

- Redirect following: built into `handle_response`
- Authentication: built into `setup_raw_request`
- Response parsing: via `Parser` class
- Logging: via `Logger::Logger` class

### 2.2 Error Handling

#### Error Hierarchy

```ruby
HTTParty::Error < StandardError        # Base
HTTParty::Foul < Error                 # Funny name for base :)

HTTParty::UnsupportedFormat < Foul     # Invalid format
HTTParty::UnsupportedURIScheme < Foul  # Non-HTTP(S) URI
HTTParty::UnsafeURIError < Foul        # SSRF protection

HTTParty::ResponseError < Foul         # Has response attribute
  HTTParty::RedirectionTooDeep         # Too many redirects
  HTTParty::DuplicateLocationHeader    # Malformed redirect

HTTParty::NetworkError < Foul          # Wrapped network errors
```

#### Network Error Handling

HTTParty defines `COMMON_NETWORK_ERRORS`:

```ruby
COMMON_NETWORK_ERRORS = [
  EOFError,
  Errno::ECONNABORTED, Errno::ECONNREFUSED, Errno::ECONNRESET,
  Errno::EHOSTUNREACH, Errno::EINVAL, Errno::ENETUNREACH,
  Errno::ENOTSOCK, Errno::EPIPE, Errno::ETIMEDOUT,
  Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError,
  Net::ReadTimeout, OpenSSL::SSL::SSLError, SocketError,
  Timeout::Error
].freeze
```

When `foul: true` option is set, these are wrapped in `HTTParty::NetworkError`.

#### Status Code Errors

```ruby
class Twitter
  include HTTParty
  raise_on [404, 500, '5[0-9]*']  # Regex supported!
end
```

Raises `HTTParty::ResponseError` with access to `response` object.

### 2.3 Resilience Features

**Redirect Handling** - Built in:
```ruby
# Default: 5 redirects
options[:limit] = 5          # Max redirects
options[:no_follow] = true   # Disable redirects
options[:maintain_method_across_redirects] = true
options[:resend_on_redirect] = true  # Keep body on 303
```

**Retry** - Not built in. Must implement manually or use separate gem.

**Connection Pooling** - Not built in. Uses new Net::HTTP per request.

**Circuit Breaker** - Not built in.

### 2.4 Configuration

#### Class-Level Defaults

```ruby
class MyAPI
  include HTTParty

  # Base configuration
  base_uri 'https://api.example.com'

  # Timeouts (in seconds)
  default_timeout 10
  open_timeout 5
  read_timeout 10
  write_timeout 10

  # Headers
  headers 'Accept' => 'application/json'

  # Authentication
  basic_auth 'user', 'pass'
  digest_auth 'user', 'pass'

  # Proxy
  http_proxy 'proxy.example.com', 8080, 'user', 'pass'

  # SSL
  ssl_ca_file '/path/to/ca.pem'
  ssl_ca_path '/path/to/certs'
  pem File.read('/path/to/client.pem'), 'password'
  pkcs12 File.read('/path/to/client.p12'), 'password'
  ssl_version :TLSv1_2
  ciphers 'HIGH:!aNULL:!MD5'

  # Parsing
  format :json
  parser MyCustomParser

  # Error handling
  raise_on [404, 500]

  # Logging
  logger Rails.logger, :info, :apache
end
```

#### Per-Request Options

```ruby
MyAPI.get('/users',
  query: { page: 1 },
  body: { name: 'test' },
  headers: { 'X-Custom' => 'value' },
  timeout: 30,
  format: :json
)
```

#### Connection Adapter

For advanced Net::HTTP configuration:

```ruby
class MyAdapter < HTTParty::ConnectionAdapter
  def connection
    http = super
    http.max_retries = 0
    http.keep_alive_timeout = 30
    http
  end
end

class MyAPI
  include HTTParty
  connection_adapter MyAdapter
end
```

### 2.5 API Design Patterns

#### Module Mixin Pattern

```ruby
class GitHub
  include HTTParty
  base_uri 'https://api.github.com'

  def self.user(username)
    get("/users/#{username}")
  end
end

GitHub.user('jnunemaker')
```

#### Response as Hash

```ruby
response = HTTParty.get('https://api.github.com/users/jnunemaker')

# Response delegates to parsed_response
response['login']           # Access as hash
response.parsed_response    # Explicit parsed data
response.body               # Raw body
response.code               # HTTP status code
response.headers            # Response headers

# Status helpers
response.ok?                # 200
response.success?           # 2xx
response.redirect?          # 3xx
```

#### Streaming

```ruby
HTTParty.get('https://example.com/large-file') do |fragment|
  # fragment is ResponseFragment with chunk, response, and connection
  file.write(fragment)
end
```

---

## 3. Excon

**Repository**: https://github.com/excon/excon
**Philosophy**: Performance, control, and explicit configuration

### 3.1 Architecture

#### Core Design

Excon is built for performance with low-level socket control:

```ruby
connection = Excon.new('https://api.example.com',
  persistent: true,
  tcp_nodelay: true
)

response = connection.get(path: '/users')
```

**Key Classes**:

- `Excon::Connection` - Manages sockets, persistent connections, configuration.

- `Excon::Socket` - Direct TCP socket wrapper with non-blocking I/O.

- `Excon::SSLSocket` - SSL/TLS wrapper around Socket.

- `Excon::Response` - Simple response wrapper.

- `Excon::Middleware::*` - Middleware chain (different from Faraday).

#### Socket Architecture

**Critical difference from others**: Excon manages its own sockets, not delegating to Net::HTTP.

```ruby
class Excon::Socket
  # Custom non-blocking read/write
  def read_nonblock(max_length)
    # Buffer management
    # IO.select with timeout
    # Read loop with retry
  end

  def write_nonblock(data)
    # Non-blocking write loop
    # Handles partial writes
  end

  def select_with_timeout(socket, type)
    # Maps operation -> timeout type
    # Considers request deadline for overall timeout
  end
end
```

**Connection pooling**: Built-in via `sockets` hash keyed by `scheme://host:port`.

```ruby
def sockets
  @_excon_sockets ||= {}
  if @data[:thread_safe_sockets]
    @_excon_sockets[Thread.current] ||= {}  # Per-thread
  else
    @_excon_sockets
  end
end
```

#### Middleware System

Different from Faraday - three-phase call pattern:

```ruby
class Excon::Middleware::Base
  def request_call(datum)
    # Modify request
    @stack.request_call(datum)
  end

  def response_call(datum)
    @stack.response_call(datum)
    # Modify response
  end

  def error_call(datum)
    # Handle error or pass to stack
    @stack.error_call(datum)
  end
end
```

**Built-in middleware**:
- `ResponseParser` - Parses HTTP response
- `Decompress` - Handles gzip/deflate
- `Expects` - Raises on unexpected status codes
- `Idempotent` - Retry logic for idempotent requests
- `Instrumentor` - ActiveSupport::Notifications integration
- `Mock` - Test stubbing
- `EscapePath` - Path encoding
- `RedirectFollower` - Redirect handling
- `CaptureCookies` - Cookie jar

### 3.2 Error Handling

#### Error Hierarchy

```ruby
Excon::Error < StandardError
  # Socket errors
  Excon::Error::Socket
    Excon::Error::Certificate    # SSL cert errors

  # Protocol errors
  Excon::Error::Timeout          # Various timeouts
  Excon::Error::ResponseParse    # Malformed response

  # HTTP status errors
  Excon::Error::HTTPStatus
    Excon::Error::Informational  # 1xx
    Excon::Error::Success        # 2xx (if expects fails)
    Excon::Error::Redirection    # 3xx
    Excon::Error::Client         # 4xx
    Excon::Error::Server         # 5xx

    # Specific status codes
    Excon::Error::BadRequest     # 400
    Excon::Error::Unauthorized   # 401
    Excon::Error::NotFound       # 404
    Excon::Error::TooManyRequests # 429
    Excon::Error::InternalServerError # 500
    # ... many more

  # Other errors
  Excon::Error::StubNotFound
  Excon::Error::TooManyRedirects
  Excon::Error::ProxyConnectionError
  Excon::Error::ProxyParse
```

#### Expects Pattern

```ruby
# Raises if status not in expects
Excon.get('https://example.com',
  expects: [200, 201]
)
# Raises Excon::Error::HTTPStatus with request and response
```

### 3.3 Resilience Features

#### Built-in Retry (Idempotent Middleware)

```ruby
Excon.get('https://example.com',
  idempotent: true,
  retry_limit: 4,        # Default: 4
  retry_interval: 0.5,   # Seconds between retries
  retry_errors: [        # Which errors to retry
    Excon::Error::Timeout,
    Excon::Error::Socket,
    Excon::Error::Server
  ]
)
```

#### Connection Persistence

```ruby
connection = Excon.new('https://api.example.com',
  persistent: true
)

# Reuses TCP connection
connection.get(path: '/users/1')
connection.get(path: '/users/2')

# Must explicitly reset/close
connection.reset
```

#### Thread-Safe Socket Pooling

```ruby
Excon.defaults[:thread_safe_sockets] = true  # Default: true
# Each thread gets its own socket cache
```

#### TCP Keep-Alive

```ruby
Excon.new('https://example.com',
  keepalive: {
    time: 60,    # TCP_KEEPIDLE
    intvl: 10,   # TCP_KEEPINTVL
    probes: 5    # TCP_KEEPCNT
  }
)
```

### 3.4 Configuration

#### Global Defaults

```ruby
Excon.defaults[:persistent] = true
Excon.defaults[:read_timeout] = 60
Excon.defaults[:write_timeout] = 60
Excon.defaults[:connect_timeout] = 60
Excon.defaults[:ssl_verify_peer] = true
```

#### Connection-Level

```ruby
connection = Excon.new('https://api.example.com',
  # Timeouts
  timeout: 30,           # Overall request timeout
  read_timeout: 60,
  write_timeout: 60,
  connect_timeout: 60,

  # Connection behavior
  persistent: true,
  nonblock: true,        # Non-blocking I/O
  tcp_nodelay: true,     # Disable Nagle's algorithm

  # SSL
  ssl_verify_peer: true,
  ssl_ca_file: '/path/to/ca.pem',
  ssl_ca_path: '/path/to/certs',
  ssl_version: :TLSv1_2,
  ssl_min_version: :TLS1_2,
  ciphers: 'HIGH:!aNULL',
  client_cert: '/path/to/cert.pem',
  client_key: '/path/to/key.pem',

  # Proxy
  proxy: 'http://proxy.example.com:8080',

  # Retry
  idempotent: true,
  retry_limit: 4,
  retry_interval: 0,

  # Middleware
  middlewares: [
    Excon::Middleware::ResponseParser,
    Excon::Middleware::Expects,
    Excon::Middleware::Idempotent
  ]
)
```

#### Request-Level

```ruby
connection.get(
  path: '/users',
  query: { page: 1 },
  headers: { 'Accept' => 'application/json' },
  body: '{"name":"test"}',
  expects: 200,
  idempotent: true,
  timeout: 10
)
```

#### Timeout Granularity

```ruby
# Excon supports:
:timeout           # Overall request deadline (calculated)
:connect_timeout   # TCP connection
:read_timeout      # Socket read
:write_timeout     # Socket write
:dns_timeouts      # DNS resolution (via Resolv)
```

**Deadline-based timeout**: When `:timeout` is set, Excon calculates a deadline and uses it to cap all operations:

```ruby
# In socket.rb
if @data.include?(:deadline)
  request_timeout = request_time_remaining
  if request_timeout < timeout
    timeout = request_timeout  # Use shorter of the two
  end
end
```

### 3.5 API Design Patterns

#### Direct Instantiation

```ruby
# One-off request
Excon.get('https://example.com/users')

# Persistent connection
conn = Excon.new('https://example.com')
conn.get(path: '/users')
conn.post(path: '/users', body: '...')
```

#### Streaming

```ruby
# Request streaming (chunked)
Excon.post('https://example.com/upload',
  request_block: lambda { file.read(1024) || '' }
)

# Response streaming
Excon.get('https://example.com/large',
  response_block: lambda { |chunk, remaining, total|
    file.write(chunk)
  }
)
```

#### Pipelining

```ruby
responses = connection.requests([
  { method: :get, path: '/users/1' },
  { method: :get, path: '/users/2' },
  { method: :get, path: '/users/3' }
])
```

#### Mocking

```ruby
Excon.stub({ method: :get, path: '/users' },
           { body: '[{"id":1}]', status: 200 })

Excon.defaults[:mock] = true
Excon.get('https://example.com/users')  # Returns stubbed response
```

---

## 4. Comparison Matrix

### 4.1 Architecture Comparison

| Aspect | Faraday | HTTParty | Excon |
|--------|---------|----------|-------|
| **Design Pattern** | Middleware stack | Module mixin | Connection-oriented |
| **HTTP Layer** | Adapter (external gems) | Net::HTTP | Custom sockets |
| **Extensibility** | Middleware & adapters | ConnectionAdapter subclass | Middleware |
| **Socket Control** | Adapter-dependent | Net::HTTP | Full control |
| **Code Size** | ~2K LOC core | ~2.5K LOC | ~4K LOC |

### 4.2 Feature Comparison

| Feature | Faraday | HTTParty | Excon |
|---------|---------|----------|-------|
| **Middleware** | Rack-like | None | Three-phase |
| **Connection Pooling** | Via adapter | No | Built-in |
| **Persistent Connections** | Via adapter | No | Built-in |
| **HTTP Pipelining** | No | No | Yes |
| **Streaming Request** | Adapter-dependent | Yes | Yes |
| **Streaming Response** | Adapter-dependent | Yes | Yes |
| **Parallel Requests** | Via adapter (e.g., Typhoeus) | No | Via pipelining |
| **Non-blocking I/O** | Adapter-dependent | No | Built-in |

### 4.3 Error Handling Comparison

| Aspect | Faraday | HTTParty | Excon |
|--------|---------|----------|-------|
| **Raise by Default** | No | No | No |
| **Status Exceptions** | Via RaiseError middleware | Via `raise_on` | Via `expects` |
| **Timeout Classes** | Single TimeoutError | None (raw Ruby) | Single Timeout |
| **Wrapped Exceptions** | Yes (wrapped_exception attr) | Optional (foul mode) | Yes (socket_error attr) |
| **Response Access in Error** | Yes | Yes | Yes (request + response) |

### 4.4 Timeout Configuration

| Timeout Type | Faraday | HTTParty | Excon |
|--------------|---------|----------|-------|
| **Connect** | `open_timeout` | `open_timeout` | `connect_timeout` |
| **Read** | `read_timeout` | `read_timeout` | `read_timeout` |
| **Write** | `write_timeout` | `write_timeout` | `write_timeout` |
| **Overall** | `timeout` (fallback) | `timeout` | `timeout` (deadline) |
| **DNS** | No | No | `dns_timeouts` |

### 4.5 Resilience Features

| Feature | Faraday | HTTParty | Excon |
|---------|---------|----------|-------|
| **Retry** | Via faraday-retry gem | Manual | Built-in (Idempotent) |
| **Circuit Breaker** | Custom middleware | No | No |
| **Redirect Following** | Via middleware | Built-in | Via middleware |
| **Keep-Alive** | Adapter-dependent | No | Built-in |
| **TCP Tuning** | No | No | Yes (nodelay, keepalive) |

### 4.6 SSL/TLS Configuration

| Setting | Faraday | HTTParty | Excon |
|---------|---------|----------|-------|
| **Verify Peer** | `ssl[:verify]` | `:verify` | `ssl_verify_peer` |
| **CA File** | `ssl[:ca_file]` | `ssl_ca_file` | `ssl_ca_file` |
| **CA Path** | `ssl[:ca_path]` | `ssl_ca_path` | `ssl_ca_path` |
| **Client Cert** | `ssl[:client_cert]` | `pem`, `pkcs12` | `client_cert` |
| **Min Version** | `ssl[:min_version]` | No | `ssl_min_version` |
| **Ciphers** | `ssl[:ciphers]` | `ciphers` | `ciphers` |
| **Hostname Verify** | `ssl[:verify_hostname]` | No | `ssl_verify_hostname` |

---

## 5. When to Use Which

### Use Faraday When...

1. **You need adapter flexibility** - Switch between Net::HTTP, Typhoeus, Patron, etc.
2. **You want a middleware pipeline** - Complex request/response processing
3. **You're building a gem** - Consumers can plug in their preferred adapter
4. **You need parallel requests** - Via Typhoeus or async adapters
5. **You want ecosystem** - Rich middleware ecosystem

### Use HTTParty When...

1. **You want simplicity** - Quick API clients with minimal boilerplate
2. **You like Rails conventions** - Class-level configuration DSL
3. **You need basic features** - GET/POST with JSON, redirects, auth
4. **You're prototyping** - Fast to get started
5. **Response as Hash** - Natural Ruby hash-like access

### Use Excon When...

1. **Performance is critical** - Low-level socket control
2. **You need persistent connections** - Built-in connection pooling
3. **You want explicit control** - No magic, predictable behavior
4. **You need HTTP pipelining** - Multiple requests on one connection
5. **You want built-in retry** - Idempotent middleware
6. **You need TCP tuning** - nodelay, keepalive, etc.

---

## 6. Lessons for Kozo

### From Faraday

1. **Middleware pattern is powerful** - Clean separation of concerns
2. **Adapter pattern provides flexibility** - Users can swap implementations
3. **Options structs** - Type-safe configuration with defaults
4. **RackBuilder model** - Well-understood pattern for Ruby developers
5. **Lazy locking** - Lock middleware stack on first request

### From HTTParty

1. **Module mixin is ergonomic** - Natural Ruby API
2. **Class-level defaults with instance override** - Good inheritance model
3. **Response delegation** - Response acts like parsed data
4. **Built-in redirect handling** - Essential for real-world use
5. **SSRF protection** - Security-conscious design

### From Excon

1. **Socket-level control** - Essential for performance
2. **Deadline-based timeout** - Overall request timeout that caps all operations
3. **Thread-safe socket caching** - Per-thread pools
4. **Three-phase middleware** - request_call, response_call, error_call
5. **Idempotent retry** - Sensible defaults for retriable operations
6. **Explicit configuration** - All valid keys documented, warnings for invalid

### Key Design Decisions for Kozo

1. **Timeouts everywhere** - All three support granular timeouts. Excon's deadline pattern is particularly good.

2. **Error hierarchy matters** - All three have structured error hierarchies. Include both request and response in errors.

3. **Don't raise by default** - All three require opt-in for status code exceptions.

4. **Connection pooling** - Critical for performance. Excon's approach is instructive.

5. **Middleware vs direct** - Faraday and Excon show middleware is worth the complexity for extensibility.

6. **Configuration layers** - Global -> Connection -> Request precedence is standard.

---

## 7. Code Examples Summary

### Faraday

```ruby
conn = Faraday.new('https://api.example.com') do |f|
  f.request :json
  f.response :json
  f.response :raise_error
  f.adapter :net_http
end

response = conn.get('/users') do |req|
  req.params['page'] = 1
  req.options.timeout = 10
end
```

### HTTParty

```ruby
class MyAPI
  include HTTParty
  base_uri 'https://api.example.com'
  default_timeout 10
  format :json
  raise_on [404, 500]
end

response = MyAPI.get('/users', query: { page: 1 })
```

### Excon

```ruby
conn = Excon.new('https://api.example.com',
  persistent: true,
  idempotent: true,
  retry_limit: 3,
  timeout: 30
)

response = conn.get(
  path: '/users',
  query: { page: 1 },
  expects: 200
)
```

---

*Analysis completed 2024-12-27*
