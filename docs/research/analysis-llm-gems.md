# LLM Ruby Gems Analysis: langchainrb and ruby_llm

This document provides a deep comparative analysis of two modern Ruby gems for unified LLM interfaces: **langchainrb** (patterns-ai-core/langchainrb) and **ruby_llm** (crmne/ruby_llm).

---

## Executive Summary

Both gems represent the newest generation of LLM API abstractions in Ruby. They take fundamentally different architectural approaches:

- **langchainrb**: Comprehensive LangChain-inspired framework with RAG, vector databases, agents, and tools. More batteries-included but heavier.
- **ruby_llm**: Focused, modern Ruby-first design with fluent API, model registry, and Rails integration. Lighter but feature-complete for core chat scenarios.

---

## 1. Provider Abstraction

### langchainrb

**Architecture**: Classical OOP inheritance with a `Langchain::LLM::Base` abstract class.

```ruby
# lib/langchain/llm/base.rb
module Langchain::LLM
  class Base
    attr_accessor :client
    attr_reader :defaults

    def chat(...) raise NotImplementedError end
    def embed(...) raise NotImplementedError end
    def complete(...) raise NotImplementedError end
    def summarize(...) raise NotImplementedError end
  end
end
```

**Provider Implementation Pattern**:
- Each provider (OpenAI, Anthropic, etc.) is a standalone class inheriting from `Base`
- Providers wrap external gem clients (e.g., `ruby-openai`, `anthropic`)
- DEFAULTS constant per provider specifies models and parameters
- Lazy gem loading via `depends_on` helper

```ruby
# lib/langchain/llm/openai.rb
class OpenAI < Base
  DEFAULTS = {
    n: 1,
    chat_model: "gpt-4o-mini",
    embedding_model: "text-embedding-3-small"
  }.freeze

  def initialize(api_key:, llm_options: {}, default_options: {})
    depends_on "ruby-openai", req: "openai"
    @client = ::OpenAI::Client.new(access_token: api_key, **llm_options)
    @defaults = DEFAULTS.merge(default_options)
  end
end
```

**Provider-Specific Features**: Handled via class-specific methods and parameters. No unified capability detection.

**Adding New Providers**: Create new class inheriting from `Base`, implement required methods, add to documentation.

### ruby_llm

**Architecture**: Modular mixin-based composition with a central `Provider` base class.

```ruby
# lib/ruby_llm/provider.rb
class Provider
  include Streaming

  attr_reader :config, :connection

  def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, &)
    # Unified completion interface
  end

  class << self
    def register(name, provider_class)
      providers[name.to_sym] = provider_class
    end

    def for(model)
      model_info = Models.find(model)
      resolve model_info.provider
    end
  end
end
```

**Provider Implementation Pattern**:
- Each provider includes specific concern modules (Chat, Streaming, Tools, Models, etc.)
- Uses Faraday directly (no external gem wrappers)
- Explicit provider registry with `Provider.register`

```ruby
# lib/ruby_llm/providers/openai.rb
class OpenAI < Provider
  include OpenAI::Chat
  include OpenAI::Embeddings
  include OpenAI::Models
  include OpenAI::Moderation
  include OpenAI::Streaming
  include OpenAI::Tools
  include OpenAI::Images
  include OpenAI::Media
  include OpenAI::Transcription

  def api_base
    @config.openai_api_base || 'https://api.openai.com/v1'
  end

  class << self
    def capabilities
      OpenAI::Capabilities
    end

    def configuration_requirements
      %i[openai_api_key]
    end
  end
end

# Registration in main module
RubyLLM::Provider.register :openai, RubyLLM::Providers::OpenAI
```

**Capabilities Module**: Each provider has a `Capabilities` module that provides:
- Model family detection via regex patterns
- Context window sizes
- Token limits
- Feature support (vision, functions, structured output)
- Pricing information

```ruby
# lib/ruby_llm/providers/openai/capabilities.rb
module Capabilities
  MODEL_PATTERNS = {
    gpt4o: /^gpt-4o(?!-(?:mini|audio))/,
    o1: /^o1(?!-(?:mini|pro))/,
    # ...
  }.freeze

  def supports_vision?(model_id)
    case model_family(model_id)
    when 'gpt4o', 'gpt4_turbo' then true
    else false
    end
  end

  def context_window_for(model_id)
    case model_family(model_id)
    when 'gpt4o' then 128_000
    when 'o1' then 200_000
    # ...
    end
  end
end
```

**Adding New Providers**:
1. Create provider class including needed mixins
2. Implement concern modules (Chat, Streaming, etc.)
3. Create Capabilities module
4. Register with `Provider.register`

**Comparison**: ruby_llm's approach is more modular and discoverable. The mixin pattern allows code reuse across similar providers. langchainrb's approach is simpler but leads to more code duplication.

---

## 2. Error Handling

### langchainrb

**Minimal error normalization** - errors largely bubble up from underlying gems:

```ruby
# lib/langchain/llm/base.rb
class ApiError < StandardError; end

# Per-provider handling
def with_api_error_handling
  response = yield
  return if response.nil? || response.empty?

  raise Langchain::LLM::ApiError.new "OpenAI API error: #{response.dig("error", "message")}" if response&.dig("error")
  response
end
```

**Issues**:
- Single generic `ApiError` class
- No rate limit specific handling
- No timeout handling
- No automatic retries

### ruby_llm

**Comprehensive error hierarchy with Faraday middleware**:

```ruby
# lib/ruby_llm/error.rb
class Error < StandardError
  attr_reader :response
end

# HTTP status-specific errors
class BadRequestError < Error; end
class UnauthorizedError < Error; end
class PaymentRequiredError < Error; end
class ForbiddenError < Error; end
class RateLimitError < Error; end    # 429
class ServerError < Error; end        # 500
class ServiceUnavailableError < Error; end  # 502-503
class OverloadedError < Error; end    # 529 (Anthropic specific)

# Faraday middleware for error normalization
class ErrorMiddleware < Faraday::Middleware
  def call(env)
    @app.call(env).on_complete do |response|
      self.class.parse_error(provider: @provider, response: response)
    end
  end

  def self.parse_error(provider:, response:)
    message = provider&.parse_error(response)

    case response.status
    when 200..399 then message
    when 400 then raise BadRequestError.new(response, message)
    when 401 then raise UnauthorizedError.new(response, message)
    when 429 then raise RateLimitError.new(response, message)
    when 529 then raise OverloadedError.new(response, message)
    # ...
    end
  end
end
```

**Rate Limiting**: Built into connection with Faraday retry middleware:

```ruby
# lib/ruby_llm/connection.rb
def setup_retry(faraday)
  faraday.request :retry, {
    max: @config.max_retries,            # Default: 3
    interval: @config.retry_interval,     # Default: 0.1s
    interval_randomness: 0.5,
    backoff_factor: @config.retry_backoff_factor,  # Default: 2
    exceptions: retry_exceptions,
    retry_statuses: [429, 500, 502, 503, 504, 529]
  }
end

def retry_exceptions
  [
    Errno::ETIMEDOUT,
    Timeout::Error,
    Faraday::TimeoutError,
    Faraday::ConnectionFailed,
    RubyLLM::RateLimitError,
    RubyLLM::ServerError,
    RubyLLM::ServiceUnavailableError,
    RubyLLM::OverloadedError
  ]
end
```

**Timeout Handling**:

```ruby
def setup_timeout(faraday)
  faraday.options.timeout = @config.request_timeout  # Default: 300s (5 min)
end
```

**Comparison**: ruby_llm has significantly better error handling with proper error classification, automatic retries with exponential backoff, and timeout configuration. langchainrb leaves most of this to the user.

---

## 3. Streaming Support

### langchainrb

**Block/callback pattern with chunk accumulation**:

```ruby
# lib/langchain/llm/openai.rb
def chat(params = {}, &block)
  if block
    @response_chunks = []
    parameters[:stream_options] = {include_usage: true}
    parameters[:stream] = proc do |chunk, _bytesize|
      chunk_content = chunk.dig("choices", 0) || {}
      @response_chunks << chunk
      yield chunk_content
    end
  end

  response = client.chat(parameters: parameters)
  response = response_from_chunks if block

  Langchain::LLM::Response::OpenAIResponse.new(response)
end

private

def response_from_chunks
  # Reconstructs full response from accumulated chunks
  grouped_chunks = @response_chunks.group_by { |chunk| chunk.dig("choices", 0, "index") }
  # ... reassembly logic
end
```

**Issues**:
- Instance variable pollution (`@response_chunks`)
- Manual chunk reassembly per provider
- No unified streaming abstraction

### ruby_llm

**Dedicated Streaming module with StreamAccumulator**:

```ruby
# lib/ruby_llm/streaming.rb
module Streaming
  def stream_response(connection, payload, additional_headers = {}, &block)
    accumulator = StreamAccumulator.new

    response = connection.post stream_url, payload do |req|
      req.options.on_data = handle_stream do |chunk|
        accumulator.add chunk
        block.call chunk
      end
    end

    accumulator.to_message(response)
  end

  def handle_stream(&block)
    to_json_stream do |data|
      block.call(build_chunk(data)) if data
    end
  end
end

# lib/ruby_llm/stream_accumulator.rb
class StreamAccumulator
  def initialize
    @content = +''
    @tool_calls = {}
    @input_tokens = nil
    @output_tokens = nil
  end

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
    Message.new(
      role: :assistant,
      content: content.empty? ? nil : content,
      model_id: model_id,
      tool_calls: tool_calls_from_stream,
      input_tokens: @input_tokens,
      output_tokens: @output_tokens,
      raw: response
    )
  end
end
```

**Provider-specific streaming hooks**:

```ruby
# lib/ruby_llm/providers/openai/streaming.rb
module Streaming
  def build_chunk(data)
    Chunk.new(
      role: :assistant,
      model_id: data['model'],
      content: data.dig('choices', 0, 'delta', 'content'),
      tool_calls: parse_tool_calls(data.dig('choices', 0, 'delta', 'tool_calls')),
      input_tokens: data.dig('usage', 'prompt_tokens'),
      output_tokens: data.dig('usage', 'completion_tokens')
    )
  end

  def parse_streaming_error(data)
    error_data = JSON.parse(data)
    case error_data.dig('error', 'type')
    when 'rate_limit_exceeded' then [429, error_data['error']['message']]
    else [400, error_data['error']['message']]
    end
  end
end
```

**Uses EventStreamParser gem** for robust SSE handling with proper buffering.

**Comparison**: ruby_llm has a cleaner streaming abstraction with proper separation of concerns. The StreamAccumulator pattern is elegant and reusable.

---

## 4. Configuration

### langchainrb

**Per-instance configuration only**:

```ruby
llm = Langchain::LLM::OpenAI.new(
  api_key: ENV["OPENAI_API_KEY"],
  llm_options: {},      # Passed to underlying client
  default_options: {}   # Override DEFAULTS
)
```

**No global configuration**. Each LLM instance manages its own settings.

### ruby_llm

**Global configuration with per-request overrides**:

```ruby
# lib/ruby_llm/configuration.rb
class Configuration
  attr_accessor :openai_api_key,
                :openai_api_base,
                :anthropic_api_key,
                :gemini_api_key,
                # ... all provider keys

                # Default models
                :default_model,
                :default_embedding_model,

                # Connection settings
                :request_timeout,
                :max_retries,
                :retry_interval,
                :retry_backoff_factor,
                :http_proxy,

                # Logging
                :logger,
                :log_level

  def initialize
    @request_timeout = 300
    @max_retries = 3
    @retry_interval = 0.1
    @retry_backoff_factor = 2
    @default_model = 'gpt-4.1-nano'
    # ...
  end
end

# Usage
RubyLLM.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.anthropic_api_key = ENV['ANTHROPIC_API_KEY']
  config.request_timeout = 120
end
```

**Per-request overrides via fluent API**:

```ruby
chat = RubyLLM.chat
  .with_model('gpt-4o')
  .with_temperature(0.7)
  .with_params(max_tokens: 1000)
  .with_headers('X-Custom' => 'value')
```

**Context for isolated configuration**:

```ruby
context = RubyLLM.context do |config|
  config.openai_api_key = 'different-key'
  config.request_timeout = 60
end

chat = context.chat(model: 'gpt-4o')
```

**Credential management**: Configuration filters sensitive fields from `instance_variables`:

```ruby
def instance_variables
  super.reject { |ivar| ivar.to_s.match?(/_id|_key|_secret|_token$/) }
end
```

**Comparison**: ruby_llm has a more sophisticated configuration system with global defaults, per-request overrides, and context isolation. langchainrb's per-instance approach is simpler but less flexible.

---

## 5. Advanced Features

### RAG (Retrieval Augmented Generation)

**langchainrb** - Full RAG support with multiple vector databases:

```ruby
# Supported vector DBs
# - Chroma, Elasticsearch, HNSWLib, Milvus, Pgvector, Pinecone, Qdrant, Weaviate

# lib/langchain/vectorsearch/base.rb
class Base
  attr_reader :client, :index_name, :llm

  # Core operations
  def add_texts(...) raise NotImplementedError end
  def similarity_search(...) raise NotImplementedError end
  def similarity_search_by_vector(...) raise NotImplementedError end

  # RAG entry point
  def ask(question:, k: 4, &block)
    search_results = similarity_search(query: question, k: k)
    context = search_results.map(&:content).join("\n---\n")
    prompt = generate_rag_prompt(question: question, context: context)
    llm.chat(messages: [{role: "user", content: prompt}], &block)
  end

  # HyDE (Hypothetical Document Embeddings)
  def similarity_search_with_hyde(query:, k: 4)
    hyde_completion = llm.complete(prompt: generate_hyde_prompt(question: query))
    similarity_search(query: hyde_completion.completion, k: k)
  end
end
```

**ruby_llm** - No built-in RAG. Focused on core LLM operations.

### Tools/Functions

**langchainrb** - DSL-based tool definition:

```ruby
# lib/langchain/tool_definition.rb
module Langchain::ToolDefinition
  def define_function(method_name, description:, &block)
    function_schemas.add_function(method_name:, description:, &block)
  end

  class ParameterBuilder
    def property(name, type:, description:, required: false, &block)
      # Build JSON Schema for function parameters
    end
  end
end

# Example tool
class Database
  extend Langchain::ToolDefinition

  define_function :execute, description: "Executes SQL query" do
    property :input, type: "string", description: "SQL query", required: true
  end

  def execute(input:)
    tool_response(content: db[input].to_a)
  rescue Sequel::DatabaseError => e
    tool_response(content: e.message)
  end
end
```

**Built-in tools**: Calculator, Database, FileSystem, GoogleSearch, NewsRetriever, RubyCodeInterpreter, Tavily, Vectorsearch, Weather, Wikipedia

**ruby_llm** - Class-based tool definition with schema support:

```ruby
# lib/ruby_llm/tool.rb
class Tool
  class << self
    def description(text = nil)
      return @description unless text
      @description = text
    end

    def param(name, type:, desc:, required: true)
      parameters[name] = Parameter.new(name, type:, desc:, required:)
    end

    # Alternative: JSON Schema or DSL block
    def params(schema = nil, &block)
      @params_schema_definition = SchemaDefinition.new(schema:, block:)
    end
  end

  def call(args)
    execute(**args.transform_keys(&:to_sym))
  end

  def execute(...)
    raise NotImplementedError
  end

  # Stop conversation after tool execution
  protected def halt(message)
    Halt.new(message)
  end
end

# Example
class WeatherTool < RubyLLM::Tool
  description "Get current weather"
  param :location, type: 'string', desc: 'City name'

  def execute(location:)
    # Fetch weather...
  end
end
```

### Agent/Assistant Pattern

**langchainrb** - Full agent with state machine:

```ruby
# lib/langchain/assistant.rb
class Assistant
  attr_reader :llm, :messages, :state, :tools

  def initialize(llm:, tools: [], instructions: nil, tool_choice: "auto")
    @llm_adapter = LLM::Adapter.build(llm)
    @state = :ready
  end

  def run(auto_tool_execution: false)
    @state = :in_progress
    @state = handle_state until run_finished?(auto_tool_execution)
    messages
  end

  private

  def handle_state
    case @state
    when :in_progress then process_latest_message
    when :requires_action then execute_tools
    end
  end

  def execute_tools
    run_tools(messages.last.tool_calls)
    :in_progress
  rescue => e
    :failed
  end
end
```

**LLM Adapters** normalize differences between providers:

```ruby
# lib/langchain/assistant/llm/adapter.rb
class Adapter
  def self.build(llm)
    case llm
    when Langchain::LLM::Anthropic then Adapters::Anthropic.new
    when Langchain::LLM::OpenAI then Adapters::OpenAI.new
    when Langchain::LLM::GoogleGemini then Adapters::GoogleGemini.new
    # ...
    end
  end
end
```

**ruby_llm** - Simpler Chat class with tool execution:

```ruby
# lib/ruby_llm/chat.rb
class Chat
  def ask(message = nil, with: nil, &)
    add_message role: :user, content: build_content(message, with)
    complete(&)
  end

  def with_tool(tool)
    @tools[tool_instance.name.to_sym] = tool_instance
    self
  end

  def complete(&)
    response = @provider.complete(messages, tools: @tools, ...)
    add_message response

    if response.tool_call?
      handle_tool_calls(response, &)
    else
      response
    end
  end

  private

  def handle_tool_calls(response, &)
    response.tool_calls.each_value do |tool_call|
      @on[:tool_call]&.call(tool_call)
      result = execute_tool(tool_call)
      @on[:tool_result]&.call(result)
      add_message role: :tool, content: result, tool_call_id: tool_call.id
    end

    complete(&)  # Continue conversation
  end
end
```

**Event callbacks for observability**:

```ruby
chat = RubyLLM.chat
  .with_tool(WeatherTool)
  .on_new_message { puts "Message started" }
  .on_end_message { |msg| puts "Message: #{msg.content}" }
  .on_tool_call { |tc| puts "Calling: #{tc.name}" }
  .on_tool_result { |result| puts "Result: #{result}" }
```

### Memory/Context Management

**langchainrb** - Messages array with manual management:

```ruby
assistant.add_message(role: "user", content: "Hello")
assistant.clear_messages!
assistant.instructions = "New system prompt"
```

**ruby_llm** - Messages with Rails persistence integration:

```ruby
# lib/ruby_llm/active_record/acts_as.rb
class Chat < ApplicationRecord
  acts_as_chat messages: :messages
end

class Message < ApplicationRecord
  acts_as_message chat: :chat, tool_calls: :tool_calls
end

# Usage
chat = Chat.create!
llm_chat = chat.to_llm
llm_chat.ask("Hello")
# Messages automatically persisted
```

---

## 6. Ruby Idioms and Modern Patterns

### langchainrb

**Classical Ruby patterns**:
- Traditional class inheritance
- `attr_reader`/`attr_accessor` for state
- YARD documentation
- Block parameters for streaming

**Lazy gem loading**:

```ruby
# lib/langchain/dependency_helper.rb
def depends_on(gem_name, req: true)
  gem(gem_name)
  # Version checking with Bundler
  gem_requirement = Bundler.load.dependencies.find { |g| g.name == gem_name }&.requirement
  raise VersionError unless gem_requirement.satisfied_by?(gem_version)
  require(lib_name) if lib_name
end
```

### ruby_llm

**Modern Ruby 3.x patterns**:

1. **Fluent API with method chaining**:
```ruby
chat = RubyLLM.chat
  .with_model('gpt-4o')
  .with_temperature(0.7)
  .with_tool(Calculator)
  .with_instructions("You are helpful")
```

2. **Endless methods and pattern matching ready**:
```ruby
def tool_call? = !tool_calls.nil? && !tool_calls.empty?
```

3. **Keyword splat forwarding**:
```ruby
def execute(...)
  raise NotImplementedError
end
```

4. **Zeitwerk autoloading**:
```ruby
loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect('openai' => 'OpenAI', 'api' => 'API')
loader.setup
```

5. **Enumerable integration**:
```ruby
class Chat
  include Enumerable

  def each(&) = messages.each(&)
end

class Models
  include Enumerable

  def each(&) = all.each(&)
end
```

6. **Struct for simple data**:
```ruby
Chunk = Struct.new(:role, :content, :model_id, :tool_calls,
                   :input_tokens, :output_tokens, keyword_init: true)
```

7. **Protected visibility for subclass hooks**:
```ruby
protected def halt(message)
  Halt.new(message)
end
```

---

## 7. Resilience Gaps and Improvement Opportunities

### langchainrb

**Critical gaps**:

1. **No retry handling** - All errors bubble up immediately
2. **No rate limit awareness** - No backoff, no queuing
3. **No timeout configuration** - Relies on underlying gem defaults
4. **No circuit breaker** - Repeated failures not detected
5. **No connection pooling** - New connections per request
6. **Provider-coupled** - Hard dependency on external gems (ruby-openai, anthropic)

**Memory issues**:
- Instance variable `@response_chunks` pollution in streaming
- No cleanup on error paths

### ruby_llm

**Partial solutions in place**:

1. **Retry with backoff** - Via Faraday middleware, but:
   - No jitter beyond `interval_randomness`
   - No circuit breaker
   - Retries are synchronous/blocking

2. **Timeout configuration** - Global only, no per-request timeout

3. **Error hierarchy** - Good, but:
   - No structured error context (request_id, etc.)
   - No error aggregation for observability

**Missing entirely**:

1. **Bulkhead/isolation** - No per-provider connection limits
2. **Circuit breaker** - Repeated failures not tracked
3. **Request queuing** - No rate limit preemption
4. **Health checks** - No provider availability detection
5. **Graceful degradation** - No fallback provider support

### Recommendations for Umi

Given Umi's focus on OTP-style resilience patterns:

1. **Connection as Ractor-citizen**: Wrap HTTP connections in Proctor-like supervision

2. **Provider health detection**: Use `Ractor.monitor` pattern for connection liveness

3. **Circuit breaker**: Track failure rates per provider, trip circuit on threshold

4. **Bulkhead per provider**: Limit concurrent requests to prevent cascade

5. **Timeout everywhere**: Per-request timeouts with Umi's timer thread pattern

6. **Tagged tuple responses**:
```ruby
case llm.chat(messages)
in [:ok, response] then process(response)
in [:error, :rate_limited, retry_after:] then wait_and_retry(retry_after)
in [:error, :timeout] then try_fallback_provider
in [:error, :circuit_open] then return_cached_or_fail
end
```

---

## 8. API Design Comparison Summary

| Feature | langchainrb | ruby_llm |
|---------|-------------|----------|
| Provider abstraction | Class inheritance | Mixin composition |
| Configuration | Per-instance | Global + overrides |
| Error handling | Minimal | Comprehensive |
| Retry/backoff | None | Faraday middleware |
| Streaming | Block callback | StreamAccumulator |
| Tool definition | DSL (`define_function`) | Class-based |
| Vector DB/RAG | 8 integrations | None |
| Model registry | None | JSON + API refresh |
| Rails integration | None | acts_as_* pattern |
| Async support | None | None |

---

## 9. Code Quality Observations

### langchainrb

- **Well documented** with YARD
- **Comprehensive test suite** with VCR cassettes
- **Rails engine** for asset pipeline integration
- **Some TODO comments** indicating incomplete features

### ruby_llm

- **Clean separation** of concerns via modules
- **Consistent fluent API** throughout
- **Model data** from external API (Parsera) + local JSON
- **Generator support** for Rails setup
- **Instance variable filtering** for security

---

## 10. Conclusion

**For comprehensive LLM applications** with RAG, vector search, and multiple tools: **langchainrb** provides more batteries included.

**For focused chat applications** with modern Ruby style and Rails integration: **ruby_llm** is more elegant and maintainable.

**For resilience-focused applications** (Umi's domain): Neither gem provides adequate resilience patterns. Both would benefit from:
- Circuit breakers
- Bulkhead isolation
- Proper timeout hierarchies
- Health-aware routing
- Graceful degradation

The opportunity for Umi is to provide these resilience patterns as a layer that could wrap either gem's providers, bringing OTP-style reliability to Ruby LLM applications.

---

*Analysis completed: 2024-12-27*
*Gems analyzed: langchainrb (HEAD), ruby_llm (HEAD)*
