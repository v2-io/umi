# Cloud SDK Analysis: AWS SDK Ruby & Google Cloud Ruby

This document analyzes the enterprise-grade patterns used in two major cloud provider SDKs:
- **AWS SDK for Ruby** (aws-sdk-core, ~400 service gems)
- **Google Cloud Ruby** (google-cloud-*, ~500 gems)

Both represent massive, battle-tested codebases with patterns refined over years of production use.

---

## 1. Error Handling Patterns

### AWS SDK Ruby

**Error Class Hierarchy:**

```
RuntimeError / StandardError
  |
  +-- Aws::Errors::ServiceError  (Base for all API errors)
  |     |-- code              # Error code string (e.g., "NoSuchBucket")
  |     |-- context           # Seahorse::Client::RequestContext
  |     |-- data              # Aws::Structure with error details
  |     |-- retryable?        # Boolean for retry logic
  |     +-- throttling?       # Boolean for throttle detection
  |
  +-- Aws::S3::Errors::NoSuchBucket  (Service-specific, generated)
  +-- Aws::STS::Errors::ExpiredTokenException (Service-specific, generated)
  ...
  +-- Seahorse::Client::NetworkingError  (Transport-level errors)
  |     +-- original_error    # The underlying exception
  |
  +-- Aws::Errors::MissingCredentialsError
  +-- Aws::Errors::MissingRegionError
  +-- Aws::Waiters::Errors::WaiterFailed
        +-- FailureStateError
        +-- TooManyAttemptsError
        +-- UnexpectedError
```

**Key Design Patterns:**

1. **Dynamic Error Classes** (`DynamicErrors` module):
   - Uses `const_missing` to create error classes on demand
   - Thread-safe with mutex protection for `const_set`
   - Unknown error codes get classes generated at runtime
   - Allows `rescue Aws::S3::Errors::SomeNewError` without prior definition

2. **Service-Specific Namespacing**:
   - Each service has its own `Errors` module (e.g., `Aws::S3::Errors`)
   - All inherit from a service-specific `ServiceError` class
   - Enables rescue granularity: service-level vs. error-code level

3. **Rich Error Metadata**:
   - `context` provides full request context (params, operation, config)
   - `data` is a typed structure with error-specific fields
   - Error classes can have typed accessor methods for specific fields

4. **API vs Transport Error Distinction**:
   - `ServiceError` = API returned an error (4xx/5xx)
   - `NetworkingError` = Transport failure (connection timeout, DNS, etc.)
   - Separate handling enables different retry strategies

**Code Example (from `lib/aws-sdk-core/errors.rb`):**
```ruby
class ServiceError < RuntimeError
  def initialize(context, message, data = Aws::EmptyStructure.new)
    @code = self.class.code
    @context = context
    @data = data
    @message = message && !message.empty? ? message : self.class.to_s
    super(@message)
  end

  def retryable?
    false  # Overridden by specific error classes
  end

  def throttling?
    false  # Overridden by throttling errors
  end
end
```

### Google Cloud Ruby

**Error Class Hierarchy:**

```
StandardError
  |
  +-- Google::Cloud::Error  (Base for all API errors)
  |     |-- status_code     # HTTP status (via cause)
  |     |-- body            # Response body (via cause)
  |     |-- code            # gRPC error code
  |     |-- details         # gRPC error details
  |     |-- metadata        # gRPC metadata
  |     |-- status_details  # Detailed status info
  |     |-- error_info      # Google::Rpc::ErrorInfo
  |     |-- domain          # Error domain
  |     +-- reason          # Error reason
  |
  +-- Google::Cloud::CanceledError           (gRPC code 1)
  +-- Google::Cloud::UnknownError            (gRPC code 2)
  +-- Google::Cloud::InvalidArgumentError    (gRPC code 3)
  +-- Google::Cloud::DeadlineExceededError   (gRPC code 4)
  +-- Google::Cloud::NotFoundError           (gRPC code 5)
  +-- Google::Cloud::AlreadyExistsError      (gRPC code 6)
  +-- Google::Cloud::PermissionDeniedError   (gRPC code 7)
  +-- Google::Cloud::ResourceExhaustedError  (gRPC code 8, throttling)
  +-- Google::Cloud::FailedPreconditionError (gRPC code 9)
  +-- Google::Cloud::AbortedError            (gRPC code 10)
  +-- Google::Cloud::OutOfRangeError         (gRPC code 11)
  +-- Google::Cloud::UnimplementedError      (gRPC code 12)
  +-- Google::Cloud::InternalError           (gRPC code 13)
  +-- Google::Cloud::UnavailableError        (gRPC code 14)
  +-- Google::Cloud::DataLossError           (gRPC code 15)
  +-- Google::Cloud::UnauthenticatedError    (gRPC code 16)
```

**Key Design Patterns:**

1. **gRPC Status Code Mapping**:
   - Direct 1:1 mapping from gRPC canonical error codes
   - Each error class has a `code` method returning its numeric code
   - Enables consistent cross-language error handling

2. **HTTP/gRPC Dual Support**:
   - `Error.from_error` factory method detects transport type
   - Uses `status_code` for HTTP, `code` for gRPC
   - Unified error experience regardless of transport

3. **Cause Chain Preservation**:
   - Error metadata accessed via Ruby's `cause` mechanism
   - `status_code`, `body`, `header` delegate to cause
   - Maintains full error provenance

4. **Service-Specific Errors**:
   - Minimal: only for domain-specific cases
   - Example: `Storage::FileVerificationError` with `type`, `gcloud_digest`, `local_digest`
   - Most errors use base hierarchy

**Code Example (from `lib/google/cloud/errors.rb`):**
```ruby
def self.from_error error
  klass = if error.respond_to? :code
            grpc_error_class_for error.code
          elsif error.respond_to? :status_code
            gapi_error_class_for error.status_code
          else
            self
          end
  klass.new error.message
end

def self.grpc_error_class_for grpc_error_code
  [
    self, CanceledError, UnknownError, InvalidArgumentError,
    DeadlineExceededError, NotFoundError, AlreadyExistsError,
    PermissionDeniedError, ResourceExhaustedError,
    FailedPreconditionError, AbortedError, OutOfRangeError,
    UnimplementedError, InternalError, UnavailableError, DataLossError,
    UnauthenticatedError
  ][grpc_error_code] || self
end
```

### Comparison Summary

| Aspect | AWS SDK | Google Cloud |
|--------|---------|--------------|
| Base Class | `Aws::Errors::ServiceError` | `Google::Cloud::Error` |
| Dynamic Classes | Yes, via `const_missing` | No, fixed hierarchy |
| Service Namespacing | Per-service error modules | Shared base classes |
| Error Codes | String-based (e.g., "NoSuchBucket") | Numeric gRPC codes |
| Transport Detection | Explicit error types | Cause chain inspection |
| Metadata Access | Direct attributes | Delegated to cause |

---

## 2. Resilience Features

### AWS SDK Ruby

**Retry Configuration:**

```ruby
# Three retry modes available:
option(:retry_mode, default: 'legacy')
# - 'legacy': Pre-existing behavior, simple exponential backoff
# - 'standard': Cross-SDK standardized with retry quotas
# - 'adaptive': + automatic client-side throttling

option(:retry_limit, default: 3)      # Legacy mode
option(:max_attempts, default: 3)     # Standard/adaptive modes
option(:retry_base_delay, default: 0.3)
option(:retry_max_delay, default: 0)  # 0 = no limit
option(:retry_jitter, default: :none) # :none, :equal, :full
```

**Jitter Implementations:**
```ruby
EQUAL_JITTER = ->(delay) { (delay / 2) + Kernel.rand(0..(delay / 2)) }
FULL_JITTER  = ->(delay) { Kernel.rand(0..delay) }
NO_JITTER    = ->(delay) { delay }
```

**Retry Quota System (Standard/Adaptive modes):**
```ruby
class RetryQuota
  INITIAL_RETRY_TOKENS = 500
  RETRY_COST = 5
  NO_RETRY_INCREMENT = 1
  TIMEOUT_RETRY_COST = 10  # Network errors cost more

  def checkout_capacity(error_inspector)
    capacity_amount = error_inspector.networking? ? TIMEOUT_RETRY_COST : RETRY_COST
    return 0 if capacity_amount > @available_capacity
    @available_capacity -= capacity_amount
    capacity_amount
  end

  def release(capacity_amount)
    return if @available_capacity == @max_capacity
    @available_capacity += capacity_amount || NO_RETRY_INCREMENT
    @available_capacity = [@available_capacity, @max_capacity].min
  end
end
```

**Retryable Error Detection:**
```ruby
class ErrorInspector
  EXPIRED_CREDS = Set.new(['InvalidClientTokenId', 'ExpiredToken', ...])
  THROTTLING_ERRORS = Set.new(['Throttling', 'TooManyRequestsException', 'SlowDown', ...])
  CHECKSUM_ERRORS = Set.new(['CRC32CheckFailed', 'BadDigest'])
  NETWORKING_ERRORS = Set.new(['RequestTimeout', 'InternalError', ...])
  CLOCK_SKEW_ERRORS = Set.new(['RequestTimeTooSkewed', 'SignatureDoesNotMatch', ...])

  def retryable?(context)
    server? ||                    # 5xx errors
    modeled_retryable? ||         # Error marked retryable in API model
    throttling_error? ||          # Known throttling errors
    networking? ||                # Network/transport failures
    checksum? ||                  # Checksum mismatches
    endpoint_discovery?(context) ||
    (expired_credentials? && refreshable_credentials?(context)) ||
    clock_skew?(context)
  end
end
```

**Exponential Backoff:**
```ruby
MAX_BACKOFF = 20  # seconds

def exponential_backoff(retries)
  [Kernel.rand * 2**retries, MAX_BACKOFF].min
end
```

**Clock Skew Correction:**
- Automatic detection of server/client clock drift
- Adjusts request timestamps after signature failures
- Enabled by default in standard/adaptive modes

### Google Cloud Ruby

**Retry Configuration (REST-based clients like Storage):**
```ruby
def initialize(project, credentials,
               retries: nil,              # Number of retries (default: 3)
               timeout: nil,              # Overall timeout
               open_timeout: nil,         # Connection timeout
               read_timeout: nil,         # Read timeout
               send_timeout: nil,         # Send timeout
               max_elapsed_time: nil,     # Total retry window
               base_interval: nil,        # Initial retry delay
               max_interval: nil,         # Max retry delay
               multiplier: nil)           # Backoff multiplier
```

**Retry Configuration (gRPC-based clients):**
```ruby
# Per-RPC retry policies in generated clients
default_config.rpcs.create_topic.timeout = 60.0
default_config.rpcs.create_topic.retry_policy = {
  initial_delay: 0.1,    # seconds
  max_delay: 60.0,       # seconds
  multiplier: 1.3,
  retry_codes: [14]      # UNAVAILABLE only
}

default_config.rpcs.publish.retry_policy = {
  initial_delay: 0.1,
  max_delay: 60.0,
  multiplier: 4,
  retry_codes: [10, 1, 13, 8, 2, 14, 4]  # Multiple retriable codes
}
# 1=CANCELLED, 2=UNKNOWN, 4=DEADLINE_EXCEEDED, 8=RESOURCE_EXHAUSTED,
# 10=ABORTED, 13=INTERNAL, 14=UNAVAILABLE
```

**Retry Scope:**
- REST clients: Configured at service level
- gRPC clients: Configured per-RPC method
- Different operations can have different retry strategies

### Comparison Summary

| Aspect | AWS SDK | Google Cloud |
|--------|---------|--------------|
| Retry Modes | 3 modes (legacy/standard/adaptive) | Per-method configuration |
| Max Retries | Configurable (default: 3) | Configurable (default: 3) |
| Backoff | Exponential with jitter options | Exponential with multiplier |
| Quota System | Yes (standard/adaptive) | No |
| Per-RPC Config | No (client-level) | Yes (gRPC clients) |
| Clock Skew | Automatic correction | Not automatic |
| Throttle Detection | Pattern matching on error codes | gRPC code 8 (RESOURCE_EXHAUSTED) |

---

## 3. Configuration Architecture

### AWS SDK Ruby

**Plugin-Based Architecture:**

```ruby
class Seahorse::Client::Plugin
  def add_options(config)           # Register configuration options
  def add_handlers(handlers, config) # Register request handlers
  def before_initialize(client_class, options)
  def after_initialize(client)
end

# Option definition
option(:retry_limit,
  default: 3,
  doc_type: Integer,
  docstring: "The maximum number of times to retry...")
```

**Configuration Resolution Order:**
1. Explicit constructor arguments
2. Environment variables (`AWS_REGION`, `AWS_ACCESS_KEY_ID`, etc.)
3. Shared config file (`~/.aws/config`)
4. Credentials file (`~/.aws/credentials`)
5. Instance profile (EC2 metadata service)
6. ECS container credentials

**Credential Provider Chain:**
```ruby
class CredentialProviderChain
  def providers
    [
      [:static_credentials, {}],
      [:static_profile_assume_role_web_identity_credentials, {}],
      [:static_profile_sso_credentials, {}],
      [:static_profile_assume_role_credentials, {}],
      [:static_profile_credentials, {}],
      [:static_profile_login_credentials, {}],
      [:static_profile_process_credentials, {}],
      [:env_credentials, {}],
      [:assume_role_web_identity_credentials, {}],
      [:sso_credentials, {}],
      [:assume_role_credentials, {}],
      [:shared_credentials, {}],
      [:login_credentials, {}],
      [:process_credentials, {}],
      [:instance_profile_credentials, {...}]
    ]
  end

  def resolve
    providers.each do |method_name, options|
      provider = send(method_name, options)
      return provider if provider&.set?
    end
    nil
  end
end
```

**Environment Variables:**
```ruby
# Credentials
AWS_ACCESS_KEY_ID / AMAZON_ACCESS_KEY_ID / AWS_ACCESS_KEY
AWS_SECRET_ACCESS_KEY / AMAZON_SECRET_ACCESS_KEY / AWS_SECRET_KEY
AWS_SESSION_TOKEN / AMAZON_SESSION_TOKEN

# Configuration
AWS_REGION / AWS_DEFAULT_REGION
AWS_PROFILE / AWS_DEFAULT_PROFILE
AWS_RETRY_MODE
AWS_MAX_ATTEMPTS
AWS_EC2_METADATA_DISABLED
```

### Google Cloud Ruby

**Config Object Pattern:**

```ruby
class Google::Cloud::Config < BasicObject
  def add_field!(key, initial = nil, opts = {}, &block)
    # Validates key format
    # Sets up validator based on initial value or options
    # Creates accessor methods
  end

  def add_config!(key, config = nil)
    # Adds nested configuration
  end
end

# Usage
Google::Cloud.configure do |config|
  config.add_field! :project_id, nil
  config.add_field! :credentials, nil
  config.add_config! :storage do |storage_config|
    storage_config.add_field! :retries, 3
    storage_config.add_field! :timeout, nil
  end
end
```

**Service Configuration:**
```ruby
# Global configuration
Google::Cloud.configure.project_id = "my-project"

# Service-specific configuration
Google::Cloud::Storage.configure do |config|
  config.retries = 5
  config.timeout = 60
  config.credentials = "/path/to/keyfile.json"
end

# Instance configuration (overrides global/service)
storage = Google::Cloud::Storage.new(
  project_id: "my-project",
  credentials: my_credentials,
  retries: 10
)
```

**Credential Resolution:**
```ruby
class Credentials
  PATH_ENV_VARS = ["GOOGLE_CLOUD_KEYFILE", "GCLOUD_KEYFILE"]
  JSON_ENV_VARS = ["GOOGLE_CLOUD_KEYFILE_JSON", "GCLOUD_KEYFILE_JSON"]
  DEFAULT_PATHS = ["~/.config/gcloud/application_default_credentials.json"]

  def self.default(scope: nil)
    # 1. Try PATH_ENV_VARS (file paths)
    # 2. Try JSON_ENV_VARS (JSON content)
    # 3. Try DEFAULT_PATHS
    # 4. Fall back to Google::Auth.get_application_default
  end
end
```

**gRPC Client Configuration:**
```ruby
# Class-level configuration
Google::Cloud::PubSub::V1::TopicAdmin::Client.configure do |config|
  config.timeout = 10.0
  config.rpcs.create_topic.timeout = 60.0
end

# Instance-level configuration
client = Google::Cloud::PubSub::V1::TopicAdmin::Client.new do |config|
  config.credentials = my_creds
  config.timeout = 30.0
end
```

### Comparison Summary

| Aspect | AWS SDK | Google Cloud |
|--------|---------|--------------|
| Architecture | Plugin-based composition | Config object hierarchy |
| Inheritance | Plugins can inherit/extend | Config inherits defaults |
| Scope | Client-level options | Global -> Service -> Instance |
| Credential Chain | 14+ providers in order | 4 sources + ADC fallback |
| Env Vars | Extensive coverage | Limited |
| Config Files | ~/.aws/config, ~/.aws/credentials | ~/.config/gcloud/ |
| Validation | Via plugin options | Via validators on Config |

---

## 4. Code Generation

### AWS SDK Ruby

**Generator Framework:**
- Custom code generator using Mustache templates
- API definitions in JSON format (from botocore)
- Separate files for: api-2.json, docs-2.json, paginators-1.json, waiters-2.json

**Generated Files per Service:**
```
lib/aws-sdk-{service}/
  client.rb          # Main client class with operation methods
  client_api.rb      # API model loading
  types.rb           # Request/response structures
  errors.rb          # Service-specific error classes
  resource.rb        # High-level resource abstraction
  waiters.rb         # Polling waiters
  endpoints.rb       # Endpoint resolution
  endpoint_provider.rb
  endpoint_parameters.rb
  plugins/endpoints.rb
```

**Template Example (`errors_module.mustache`):**
```mustache
module Errors
  extend Aws::Errors::DynamicErrors

  {{#errors}}
  class {{name}} < ServiceError
    def initialize(context, message, data = Aws::EmptyStructure.new)
      super(context, message, data)
    end
    {{#members}}
    def {{name}}
      @data[:{{name}}]
    end
    {{/members}}
    {{#retryable}}
    def retryable?
      true
    end
    {{/retryable}}
  end
  {{/errors}}
end
```

**API Definition Format (api-2.json excerpt):**
```json
{
  "version": "2.0",
  "metadata": {
    "apiVersion": "2011-06-15",
    "serviceFullName": "AWS Security Token Service",
    "protocol": "query"
  },
  "operations": {
    "AssumeRole": {
      "input": {"shape": "AssumeRoleRequest"},
      "output": {"shape": "AssumeRoleResponse"},
      "errors": [
        {"shape": "MalformedPolicyDocumentException"},
        {"shape": "PackedPolicyTooLargeException"}
      ]
    }
  },
  "shapes": {
    "AssumeRoleRequest": {
      "type": "structure",
      "required": ["RoleArn", "RoleSessionName"],
      "members": {...}
    }
  }
}
```

**Build Process:**
1. `services.json` maps service names to API directories
2. Generator loads API definition JSON
3. Templates produce Ruby source files
4. One gem per service (~400 gems total)

### Google Cloud Ruby

**Generator Framework:**
- GAPIC (Google API Client) generator for gRPC services
- Protocol Buffer definitions as source
- Ruby-specific generator produces idiomatic code

**Generated Files per Service:**
```
lib/google/cloud/{service}/v1/
  {service}.rb                  # Entry point
  {operation}_admin.rb          # Service wrapper
  {operation}_admin/
    client.rb                   # gRPC client implementation
    credentials.rb              # Service credentials
    paths.rb                    # Resource path helpers
    helpers.rb                  # Optional customizations
```

**Generation Markers:**
```ruby
# frozen_string_literal: true

# Copyright 2025 Google LLC
# ...

# Auto-generated by gapic-generator-ruby. DO NOT EDIT!

require "gapic/common"
require "gapic/config"
```

**Generated Client Pattern:**
```ruby
class Client
  # Class-level configuration
  def self.configure
    @configure ||= begin
      default_config = Client::Configuration.new parent_config

      # Per-RPC defaults from API definition
      default_config.rpcs.create_topic.timeout = 60.0
      default_config.rpcs.create_topic.retry_policy = {
        initial_delay: 0.1,
        max_delay: 60.0,
        multiplier: 1.3,
        retry_codes: [14]
      }

      default_config
    end
    yield @configure if block_given?
    @configure
  end

  # Instance method implementation
  def create_topic request, options = nil
    raise ::ArgumentError, "request must be provided" if request.nil?

    request = ::Gapic::Protobuf.coerce request, to: ::Google::Cloud::PubSub::V1::Topic

    options = ::Gapic::CallOptions.new(**options.to_h) if options.respond_to? :to_h

    # Apply configuration
    options.apply_defaults timeout: @config.rpcs.create_topic.timeout,
                          metadata: metadata,
                          retry_policy: @config.rpcs.create_topic.retry_policy

    @stub.call_rpc :create_topic, request, options: options do |response, operation|
      yield response, operation if block_given?
    end
  rescue ::GRPC::BadStatus => e
    raise ::Google::Cloud::Error.from_error(e)
  end
end
```

**Hand-Written vs Generated:**
- `google-cloud-storage`: Mostly hand-written (REST-based, older)
- `google-cloud-pubsub-v1`: Fully generated (gRPC-based)
- Hand-written gems wrap generated ones with higher-level APIs

### Comparison Summary

| Aspect | AWS SDK | Google Cloud |
|--------|---------|--------------|
| Source Format | JSON (botocore) | Protocol Buffers |
| Generator | Custom Mustache | GAPIC (gapic-generator-ruby) |
| Template System | Mustache templates | Ruby-based templates |
| Per-Service Gems | Yes (~400 gems) | Yes (~500 gems) |
| Generation Markers | Header comments | Header comments |
| Customization | Via plugins | Via helpers.rb |

---

## 5. API Design Patterns

### AWS SDK Ruby

**Resource Pattern (High-Level API):**
```ruby
# Resource-oriented interface
s3 = Aws::S3::Resource.new
bucket = s3.bucket('my-bucket')
object = bucket.object('my-key')
object.upload_file('/path/to/file')

# vs. Client-oriented interface
client = Aws::S3::Client.new
client.put_object(bucket: 'my-bucket', key: 'my-key', body: file)
```

**Pagination (Automatic Enumeration):**
```ruby
# PageableResponse module adds Enumerable behavior
response = s3.list_objects(bucket: 'my-bucket')

# Automatic pagination via each
response.each do |page|
  page.contents.each do |object|
    puts object.key
  end
end

# Manual pagination
while response.next_page?
  response = response.next_page
end
```

**Waiters (Polling):**
```ruby
# Wait for instance to be running
ec2.wait_until(:instance_running, instance_ids: ['i-12345'])

# With configuration
ec2.wait_until(:instance_running,
  instance_ids: ['i-12345'],
  max_attempts: 40,
  delay: 15
)

# Custom waiter
client.waiter(:instance_running, instance_ids: [...]).wait do |w|
  w.max_attempts = 10
  w.delay = 5
  w.before_wait do |attempts, response|
    puts "Attempt #{attempts}..."
  end
end
```

**Block Patterns:**
```ruby
# Block for streaming downloads
File.open('/path/to/file', 'wb') do |file|
  s3.get_object(bucket: 'my-bucket', key: 'my-key') do |chunk|
    file.write(chunk)
  end
end

# Block for response handling
s3.list_objects(bucket: 'my-bucket') do |response|
  # Called for each page
end
```

**Method Signatures:**
```ruby
# Named parameters (kwargs)
def put_object(bucket:, key:, body: nil, **options)

# Options hash approach (older)
def put_object(options = {})
  bucket = options[:bucket]
  key = options[:key]
```

### Google Cloud Ruby

**Project/Service Pattern:**
```ruby
# Storage (hand-written, high-level)
storage = Google::Cloud::Storage.new
bucket = storage.bucket "my-bucket"
file = bucket.file "my-file"

# Pub/Sub (generated, lower-level)
client = Google::Cloud::PubSub::V1::TopicAdmin::Client.new
topic = client.create_topic name: "projects/my-project/topics/my-topic"
```

**Request Object Pattern:**
```ruby
# Hash-based request
client.create_topic(name: "projects/my-project/topics/my-topic")

# Request object
request = Google::Cloud::PubSub::V1::Topic.new(
  name: "projects/my-project/topics/my-topic",
  labels: { "env" => "prod" }
)
client.create_topic(request)
```

**Pagination (Lazy Enumeration):**
```ruby
# Storage (hand-written)
bucket.files.each do |file|
  puts file.name
end

# Generated clients use page tokens
response = client.list_topics(project: "projects/my-project")
response.each do |topic|
  puts topic.name
end
# Automatic fetching of next pages
```

**Block Patterns:**
```ruby
# Configuration blocks
storage = Google::Cloud::Storage.new do |config|
  config.project_id = "my-project"
end

# Response handling
client.create_topic(request) do |response, operation|
  puts "Topic created: #{response.name}"
  puts "gRPC operation: #{operation.inspect}"
end

# Streaming downloads
file.download do |chunk|
  # Process chunk
end
```

**Path Helpers (Generated):**
```ruby
module Paths
  def project_path(project:)
    "projects/#{project}"
  end

  def topic_path(project:, topic:)
    "projects/#{project}/topics/#{topic}"
  end

  def subscription_path(project:, subscription:)
    "projects/#{project}/subscriptions/#{subscription}"
  end
end
```

### Comparison Summary

| Aspect | AWS SDK | Google Cloud |
|--------|---------|--------------|
| Primary Pattern | Client + Resource | Project/Service |
| Method Style | Keyword args | Request objects or kwargs |
| Pagination | PageableResponse mixin | Iterator/Enumerable |
| Waiters | Built-in DSL | Not standard |
| Streaming | Block yields chunks | Block yields chunks |
| Path Helpers | N/A | Generated module |
| Response Type | Struct-like objects | Protobuf messages or Structs |

---

## 6. Ruby Idioms

### AWS SDK Ruby

**Struct-Based Responses:**
```ruby
# Aws::Structure provides hash-like access
response = client.get_object(bucket: 'b', key: 'k')
response.body           # Attribute access
response[:body]         # Hash-like access
response.to_h           # Convert to hash
response.members        # List attributes
```

**Frozen String Literals:**
```ruby
# All generated files include:
# frozen_string_literal: true
```

**Lazy Autoloading:**
```ruby
module Aws
  autoload :STS, 'aws-sdk-sts'
  autoload :S3, 'aws-sdk-s3'
end
```

**Method Delegation:**
```ruby
extend Forwardable
def_delegators :@config, :region, :credentials
```

**Block Form with Cleanup:**
```ruby
# Ensures resources are cleaned up
Aws::S3::Resource.new.bucket('b').object('k').presigned_url(:get)
```

### Google Cloud Ruby

**BasicObject for Config:**
```ruby
# Config inherits from BasicObject to avoid method pollution
class Config < BasicObject
  # No to_s, inspect, is_a?, etc.
  # Clean namespace for configuration keys
end
```

**Protobuf Integration:**
```ruby
# Request coercion
request = ::Gapic::Protobuf.coerce request, to: ::Google::Cloud::PubSub::V1::Topic

# Response is a protobuf message
response.name         # String
response.to_h         # Convert to hash
response.to_json      # Serialize
```

**Module-Based Service Organization:**
```ruby
module Google
  module Cloud
    module Storage
      # Version constant
      VERSION = "1.45.0"

      # Factory method
      def self.new(project_id: nil, credentials: nil, ...)
        # ...
      end

      # Configuration
      def self.configure
        yield Google::Cloud.configure.storage if block_given?
        Google::Cloud.configure.storage
      end
    end
  end
end
```

**Forwardable Pattern:**
```ruby
extend Forwardable
def_delegators :@client,
               :token_credential_uri, :audience,
               :scope, :issuer, :signing_key
```

---

## 7. Implications for Umi

Based on this analysis, here are patterns that could inform Umi's design:

### Error Handling Recommendations

1. **Hierarchical Error Classes**: Base error with rich metadata (context, code, details)
2. **Semantic Error Types**: Separate errors for timeouts, connection failures, protocol errors
3. **Retryable/Throttling Markers**: Methods on errors to support retry logic
4. **Error Factory**: `Error.from_error(e)` pattern for wrapping transport errors

### Resilience Recommendations

1. **Configurable Retry Modes**: Simple vs. sophisticated with quotas
2. **Per-Operation Policies**: Different operations may need different strategies
3. **Jitter Options**: Support for equal, full, or no jitter
4. **Quota/Circuit Breaker**: Track failure rates to prevent cascade failures

### Configuration Recommendations

1. **Layered Defaults**: Global -> Service -> Instance
2. **Environment Variable Support**: Standard names with fallbacks
3. **Credential Chain**: Multiple providers tried in order
4. **Validation**: Type checking and constraints on config values

### API Design Recommendations

1. **Keyword Arguments**: Modern Ruby style with clear intent
2. **Block Patterns**: For streaming, callbacks, and cleanup
3. **Pagination**: Lazy enumeration with Enumerable
4. **Pattern Matching**: For tagged tuples (already in Umi's design)

---

## Appendix: File Locations

### AWS SDK Ruby
- Error handling: `gems/aws-sdk-core/lib/aws-sdk-core/errors.rb`
- Retry logic: `gems/aws-sdk-core/lib/aws-sdk-core/plugins/retry_errors.rb`
- Error inspector: `gems/aws-sdk-core/lib/aws-sdk-core/plugins/retries/error_inspector.rb`
- Retry quota: `gems/aws-sdk-core/lib/aws-sdk-core/plugins/retries/retry_quota.rb`
- Credentials: `gems/aws-sdk-core/lib/aws-sdk-core/credential_provider_chain.rb`
- Plugin base: `gems/aws-sdk-core/lib/seahorse/client/plugin.rb`
- Client base: `gems/aws-sdk-core/lib/seahorse/client/base.rb`
- Code templates: `build_tools/aws-sdk-code-generator/templates/`

### Google Cloud Ruby
- Base errors: `google-cloud-errors/lib/google/cloud/errors.rb`
- Storage errors: `google-cloud-storage/lib/google/cloud/storage/errors.rb`
- Configuration: `google-cloud-core/lib/google/cloud/config.rb`
- Credentials: `google-cloud-core/lib/google/cloud/credentials.rb`
- Generated client: `google-cloud-pubsub-v1/lib/google/cloud/pubsub/v1/topic_admin/client.rb`
