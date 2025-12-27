# Official AI SDK Ruby Gems Analysis

**Date:** 2025-12-27
**SDKs Analyzed:**
- Anthropic Ruby SDK v1.16.2 (`anthropic` gem)
- OpenAI Ruby SDK v0.42.0 (`openai` gem)

## Executive Summary

Both SDKs share a nearly identical architecture, built on the "Stainless" code generation framework. They represent modern Ruby best practices from well-funded engineering teams. Key architectural highlights:

- **Shared codebase structure**: Both use Stainless SDK generator, resulting in ~95% identical internal patterns
- **Ruby 3.2+ required**: Uses modern Ruby features extensively
- **Type-safe by design**: Ships with RBI (Sorbet) and RBS signatures
- **SSE-based streaming**: Enumerable interface over Server-Sent Events
- **Connection pooling**: Uses `connection_pool` gem with `net/http`
- **Single external dependency**: Only `connection_pool` (and `base64` for OpenAI)

---

## 1. SDK Architecture

### 1.1 Client Structure

Both SDKs follow identical patterns:

```
lib/
  {sdk}.rb                      # Entry point, requires everything
  {sdk}/
    client.rb                   # Main client class, inherits BaseClient
    version.rb                  # VERSION constant
    errors.rb                   # Error hierarchy
    streaming.rb                # Module alias to helpers
    request_options.rb          # Per-request configuration
    file_part.rb                # File upload handling

    resources/                  # API endpoints as resource classes
      messages.rb               # Anthropic: messages resource
      chat/completions.rb       # OpenAI: chat completions resource

    models/                     # Data models (~200-400 classes)
      message.rb
      ...

    internal/                   # Private implementation
      transport/
        base_client.rb          # Core HTTP client
        pooled_net_requester.rb # Connection pooling
      type/
        base_model.rb           # Model superclass
        base_stream.rb          # Stream module
        converter.rb            # Type coercion
        ...
      util.rb                   # Utility functions
      stream.rb                 # SSE stream implementation

    helpers/                    # High-level conveniences
      streaming/
        message_stream.rb       # Rich stream events
      input_schema/             # Tool/structured output helpers
```

### 1.2 Resource Organization

Resources are nested to mirror API structure:

```ruby
# Anthropic
client.messages.create(...)
client.messages.stream(...)
client.messages.batches.list(...)
client.beta.messages.tool_runner(...)

# OpenAI
client.chat.completions.create(...)
client.chat.completions.stream(...)
client.responses.stream(...)
client.fine_tuning.jobs.list(...)
```

Each resource:
- Holds a reference to the parent client
- Has a constructor accepting `client:` keyword
- Calls `@client.request(...)` for all HTTP operations

### 1.3 Code Generation

Both SDKs are **code-generated** using Stainless:

**Evidence:**
- Manifest files: `manifest.yaml`, `release-please-config.json`
- Identical internal patterns across both gems
- `x-stainless-*` headers in all requests
- Comment patterns like "Some parameter documentations has been truncated"

**Generated vs Hand-written:**
- Models (`lib/*/models/*.rb`) - Generated
- Resources (`lib/*/resources/*.rb`) - Generated with hooks for customization
- Internal transport (`lib/*/internal/transport/`) - Generated
- Streaming helpers (`lib/*/helpers/streaming/`) - Mix of generated and hand-written

---

## 2. Streaming Support

### 2.1 Implementation Architecture

```
HTTP Response
     |
     v
PooledNetRequester.execute()  ---> Enumerator yielding response bytes
     |
     v
Internal::Util.fused_enum()   ---> SSE line parsing
     |
     v
Internal::Stream#iterator     ---> Event parsing, JSON decode, type coercion
     |
     v
Helpers::Streaming::*Stream   ---> High-level events, accumulation
```

### 2.2 Server-Sent Events Handling

Both SDKs parse SSE manually rather than using a library:

```ruby
# Anthropic Internal::Stream
case msg
in {event: "message_start" | "message_delta" | ..., data: String => data}
  decoded = JSON.parse(data, symbolize_names: true)
  y << Anthropic::Internal::Type::Converter.coerce(@model, decoded)
in {event: "ping"}
  next
in {event: "error", data: String => data}
  raise Anthropic::Errors::APIStatusError.for(...)
end
```

```ruby
# OpenAI Internal::Stream
case msg
in {data: String => data} if data.start_with?("[DONE]")
  consume = true
  next
in {data: String => data}
  decoded = JSON.parse(data, symbolize_names: true)
  y << OpenAI::Internal::Type::Converter.coerce(@model, decoded)
end
```

### 2.3 Block/Callback Patterns

Streams implement Ruby's `Enumerable`:

```ruby
# Both SDKs - BaseStream module
module BaseStream
  include Enumerable

  def each(&blk)
    unless block_given?
      raise ArgumentError.new("A block must be given to ##{__method__}")
    end
    @iterator.each(&blk)
  end

  def to_enum = @iterator
  def close = Anthropic::Internal::Util.close_fused!(@iterator)
end
```

**Usage patterns:**

```ruby
# Basic iteration
stream.each { |event| process(event) }

# Text-only iteration (convenience method)
stream.text.each { |delta| print(delta) }

# Early termination (properly closes stream)
stream.each do |event|
  break if done?
end

# Accumulation
message = stream.accumulated_message  # Blocks until complete
```

### 2.4 Partial Response Assembly

Both SDKs maintain accumulator state in stream helpers:

```ruby
# Anthropic MessageStream
def accumulate_event(event:, current_snapshot:)
  case event
  in RawMessageStartEvent
    return Converter.coerce(Message, event.message)
  in RawContentBlockDeltaEvent
    content = current_snapshot.content[event.index]
    case event.delta
    in TextDelta
      content.text += delta.text
    in InputJSONDelta
      content._json_buf += delta.partial_json
    end
  in RawMessageDeltaEvent
    current_snapshot.stop_reason = event.delta.stop_reason
    current_snapshot.usage.output_tokens = event.usage.output_tokens
  end
  current_snapshot
end
```

### 2.5 Higher-Level Stream Events

Both SDKs emit custom "typed" events beyond raw SSE:

**Anthropic:**
- `TextEvent` - Text delta with snapshot
- `InputJsonEvent` - Tool input JSON delta
- `ThinkingEvent` - Extended thinking delta
- `CitationEvent` - Citation delta
- `ContentBlockStopEvent` - Block completed
- `MessageStopEvent` - Full message accumulated

**OpenAI:**
- `ChatChunkEvent` - Raw chunk with snapshot
- `ChatContentDeltaEvent` - Content delta
- `ChatRefusalDeltaEvent` - Refusal delta
- `ChatFunctionToolCallArgumentsDeltaEvent` - Tool args delta
- `ChatContentDoneEvent` - Content completed
- `ChatLogprobsContentDeltaEvent` - Logprobs

---

## 3. Error Handling

### 3.1 Error Class Hierarchy

```ruby
# Both SDKs (nearly identical)
module Errors
  class Error < StandardError
  end

  class ConversionError < Error
    # Type coercion failures
  end

  class APIError < Error
    attr_accessor :url, :status, :headers, :body
  end

  class APIConnectionError < APIError
    # Network failures, nil status
  end

  class APITimeoutError < APIConnectionError
    # Timeout, nil status
  end

  class APIStatusError < APIError
    # HTTP error responses

    def self.for(url:, status:, ...)
      case status
      in 400 then BadRequestError.new(...)
      in 401 then AuthenticationError.new(...)
      in 403 then PermissionDeniedError.new(...)
      in 404 then NotFoundError.new(...)
      in 409 then ConflictError.new(...)
      in 422 then UnprocessableEntityError.new(...)
      in 429 then RateLimitError.new(...)
      in (500..) then InternalServerError.new(...)
      else APIStatusError.new(...)
      end
    end
  end

  class BadRequestError < APIStatusError; HTTP_STATUS = 400; end
  class AuthenticationError < APIStatusError; HTTP_STATUS = 401; end
  class PermissionDeniedError < APIStatusError; HTTP_STATUS = 403; end
  class NotFoundError < APIStatusError; HTTP_STATUS = 404; end
  class ConflictError < APIStatusError; HTTP_STATUS = 409; end
  class UnprocessableEntityError < APIStatusError; HTTP_STATUS = 422; end
  class RateLimitError < APIStatusError; HTTP_STATUS = 429; end
  class InternalServerError < APIStatusError; HTTP_STATUS = (500..); end
end
```

### 3.2 Rate Limit Handling

Rate limit info is available via error attributes:

```ruby
rescue Anthropic::Errors::RateLimitError => e
  e.status   # 429
  e.headers  # Contains retry-after, rate limit headers
  e.body     # API error response
end
```

### 3.3 Retry Configuration

Built into BaseClient:

```ruby
class Client < Internal::Transport::BaseClient
  DEFAULT_MAX_RETRIES = 2
  DEFAULT_INITIAL_RETRY_DELAY = 0.5
  DEFAULT_MAX_RETRY_DELAY = 8.0

  def initialize(
    max_retries: DEFAULT_MAX_RETRIES,
    initial_retry_delay: DEFAULT_INITIAL_RETRY_DELAY,
    max_retry_delay: DEFAULT_MAX_RETRY_DELAY,
    ...
  )
end
```

Retry logic in `BaseClient#send_request`:

```ruby
def should_retry?(status, headers:)
  case [headers["x-should-retry"], status]
  in [true | false, _] then headers["x-should-retry"]
  in [_, 408 | 409 | 429 | (500..)] then true
  else false
  end
end

def retry_delay(headers, retry_count:)
  # Try retry-after-ms header (non-standard extension)
  # Try retry-after header (seconds or HTTP date)
  # Fall back to exponential backoff with jitter
  scale = retry_count ** 2
  jitter = 1 - (0.25 * rand)
  (@initial_retry_delay * scale * jitter).clamp(0, @max_retry_delay)
end
```

### 3.4 Token Limit Errors

Handled via streaming helpers with custom exceptions:

```ruby
# OpenAI ChatCompletionStreamState
def handle_finish_reason(finish_reason)
  case finish_reason
  when :length
    raise LengthFinishReasonError.new(completion: @chat_completion)
  when :content_filter
    raise ContentFilterFinishReasonError.new
  end
end
```

---

## 4. Configuration

### 4.1 API Key Handling

```ruby
# Anthropic
Anthropic::Client.new(
  api_key: ENV["ANTHROPIC_API_KEY"],     # Default
  auth_token: ENV["ANTHROPIC_AUTH_TOKEN"] # Optional OAuth
)

# OpenAI
OpenAI::Client.new(
  api_key: ENV["OPENAI_API_KEY"],  # Required, raises if nil
  organization: ENV["OPENAI_ORG_ID"],
  project: ENV["OPENAI_PROJECT_ID"]
)
```

### 4.2 Base URL Configuration

```ruby
# Both SDKs
Client.new(base_url: ENV["{SDK}_BASE_URL"] || "https://api.{sdk}.com")
```

### 4.3 Timeout Settings

```ruby
Client.new(
  timeout: 600.0  # Default 10 minutes per request
)

# Per-request override
client.messages.create(..., request_options: { timeout: 30.0 })
```

### 4.4 HTTP Client Configuration

Uses standard library `net/http` with `connection_pool` gem:

```ruby
# PooledNetRequester
KEEP_ALIVE_TIMEOUT = 30
DEFAULT_MAX_CONNECTIONS = [Etc.nprocessors, 99].max

def initialize(size: DEFAULT_MAX_CONNECTIONS)
  @pools = {}  # Origin -> ConnectionPool
  @cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
end

def with_pool(url, deadline:, &blk)
  origin = Util.uri_origin(url)
  pool = @pools[origin] ||= ConnectionPool.new(size: @size) { connect(...) }
  pool.with(timeout: deadline - now, &blk)
end
```

---

## 5. Request/Response Patterns

### 5.1 Request Building

```ruby
def request(req)
  # Validate request structure
  validate!(req)

  # Build HTTP request
  request = build_request(req.except(:options), opts)

  # Send with retries
  status, response, stream = send_request(
    request,
    redirect_count: 0,
    retry_count: 0
  )

  # Handle response based on mode
  case req
  in {stream: Class => st}
    st.new(model: model, stream: decoded, ...)
  in {page: Class => page}
    page.new(client: self, page_data: decoded, ...)
  else
    Converter.coerce(model, decoded)
  end
end
```

### 5.2 Response Parsing

All models inherit from `Internal::Type::BaseModel`:

```ruby
class BaseModel
  def self.coerce(value, state:)
    return value if value.is_a?(self)

    val = Util.coerce_hash(value)
    instance = new

    fields.each do |name, field|
      item = val.fetch(api_name, nil)
      converted = Converter.coerce(field[:type], item, state: state)
      instance.send(:"#{name}=", converted)
    end

    instance
  end
end
```

### 5.3 Type Safety Approaches

**Field definitions:**
```ruby
class Message < BaseModel
  required :id, String
  required :content, ArrayOf[ContentBlock]
  required :model, Model
  required :role, const: :assistant
  required :type, const: :message
  optional :stop_reason, StopReason

  response_only do
    required :usage, Usage
  end
end
```

**Type converters:**
```ruby
module Type
  class ArrayOf[T]
    def coerce(value, state:)
      value.map { Converter.coerce(@item_type, _1, state: state) }
    end
  end

  class HashOf[K, V]
    def coerce(value, state:)
      value.transform_values { Converter.coerce(@value_type, _1, state: state) }
    end
  end

  class Union[*Types]
    def coerce(value, state:)
      # Try each variant, use best match
    end
  end
end
```

---

## 6. Modern Ruby Patterns

### 6.1 Ruby 3.2+ Features Used

**Pattern Matching (extensively):**
```ruby
case [status, method]
in [301 | 302, :post] | [303, _]
  # Redirect handling
end

case type_info
in Proc | Converter | Class
  # Type handling
end
```

**Endless method definitions:**
```ruby
def close = Internal::Util.close_fused!(@iterator)
def to_enum = @iterator
def monotonic_secs = Process.clock_gettime(Process::CLOCK_MONOTONIC)
private def auth_headers = {}
```

**Numbered block parameters:**
```ruby
headers.each { req[_1] = _2 }
known_fields.select { _2.fetch(:required) }
```

### 6.2 Keyword Arguments

All public APIs use keyword arguments:

```ruby
def create(
  max_tokens:,
  messages:,
  model:,
  metadata: nil,
  stop_sequences: nil,
  system_: nil,  # Trailing underscore avoids Ruby keyword
  temperature: nil,
  request_options: {}
)
```

### 6.3 Pattern Matching Support

Models support `deconstruct_keys` for pattern matching:

```ruby
class BaseModel
  def deconstruct_keys(keys)
    (keys || known_fields.keys)
      .filter_map { |k| [k, public_send(k)] if known_fields.key?(k) }
      .to_h
  end
end

# Usage
message => { content:, model:, stop_reason: }
```

### 6.4 Async Support

**Not present.** Both SDKs are synchronous only. Key observations:

- No Async/Fibers usage
- No integration with async gems (async, concurrent-ruby)
- Streaming is blocking Enumerable-based
- Would require significant refactoring for async

---

## 7. Key Patterns for Reference

### 7.1 Fused Enumerator Pattern

Both SDKs use a "fused" enumerator that can be closed externally:

```ruby
def fused_enum(enum, external: false)
  finished = Concurrent::AtomicBoolean.new(false)

  Enumerator.new do |y|
    enum.each do |item|
      break if finished.true?
      y << item
    end
  end.tap do |result|
    result.define_singleton_method(:close) { finished.make_true }
  end
end
```

### 7.2 Deadline-Based Timeouts

Instead of per-operation timeouts:

```ruby
deadline = Util.monotonic_secs + timeout

# Calibrate socket timeout before each operation
def calibrate_socket_timeout(conn, deadline)
  remaining = deadline - Util.monotonic_secs
  conn.open_timeout = conn.read_timeout = remaining
end
```

### 7.3 JSON Schema Generation

Both SDKs can generate JSON Schema from model classes:

```ruby
class GetWeatherInput < Anthropic::BaseModel
  required :location, String, doc: "City and state"
  optional :unit, EnumOf[:celsius, :fahrenheit]
end

GetWeatherInput.to_json_schema
# => {
#   type: "object",
#   properties: {
#     location: { type: "string", description: "City and state" },
#     unit: { type: "string", enum: ["celsius", "fahrenheit"] }
#   },
#   required: ["location"],
#   additionalProperties: false
# }
```

### 7.4 Tool/Function Calling

**Anthropic BaseTool:**
```ruby
class Calculator < Anthropic::BaseTool
  input_schema CalculatorInput

  def call(expr)
    expr.lhs.public_send(expr.operator, expr.rhs)
  end
end
```

**OpenAI Structured Output:**
```ruby
class MathResult < OpenAI::BaseModel
  required :result, Float
  required :explanation, String
end

client.chat.completions.create(
  response_format: MathResult,
  ...
)
```

---

## 8. Implications for Umi

### 8.1 Patterns Worth Adopting

1. **Enumerable streaming** - Natural Ruby iteration
2. **Fused enumerators** - Clean external cancellation
3. **Deadline-based timeouts** - Consistent across operations
4. **Pattern matching error dispatch** - Clean error factory
5. **BaseModel with coercion** - Type-safe response handling
6. **JSON Schema generation** - For MCP tool definitions

### 8.2 Differences from Umi Approach

| Aspect | Anthropic/OpenAI SDKs | Umi Proctor |
|--------|----------------------|-------------|
| Concurrency | Blocking, thread-safe pooling | Ractor-based isolation |
| Timeout | Deadline-based, per-operation | Tagged tuple return |
| Error handling | Exceptions | Tagged tuples (OTP-style) |
| Streaming | Enumerable over SSE | Port-based message passing |

### 8.3 Integration Opportunities

Umi's MCPClient could adopt:
- JSON Schema generation patterns for tool definitions
- Type coercion patterns for response handling
- Streaming event patterns for long-running operations

---

## Appendix: File Counts and Sizes

```
anthropic-sdk:
  lib/anthropic.rb         450 lines (requires ~400 model files)
  lib/anthropic/client.rb  140 lines
  lib/anthropic/errors.rb  230 lines
  Total .rb files: ~500

openai-sdk:
  lib/openai.rb            790 lines (requires ~700 model files)
  lib/openai/client.rb     180 lines
  lib/openai/errors.rb     270 lines
  Total .rb files: ~800
```

Both SDKs ship with:
- RBI type definitions (Sorbet)
- RBS type signatures (Ruby 3 stdlib)
- YARD documentation
- Examples directory
