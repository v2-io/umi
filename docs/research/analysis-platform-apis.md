# Platform API Client Analysis: Octokit, Slack Ruby Client, Twilio Ruby

This document provides deep analysis of three exemplary Ruby API clients for major
platforms: GitHub (Octokit), Slack (slack-ruby-client), and Twilio (twilio-ruby).

---

## 1. Error Handling Patterns

### 1.1 Octokit (GitHub)

**Error Hierarchy:**
Octokit has the most sophisticated error class hierarchy, designed around HTTP status codes
with intelligent sub-classification based on response body content.

```
Octokit::Error (base class)
  |
  +-- Octokit::ClientError (4xx)
  |     +-- BadRequest (400)
  |     +-- Unauthorized (401)
  |     |     +-- OneTimePasswordRequired (401 + X-GitHub-OTP header)
  |     +-- Forbidden (403)
  |     |     +-- TooManyRequests (rate limit exceeded)
  |     |     +-- TooManyLoginAttempts
  |     |     +-- TooLargeContent
  |     |     +-- AbuseDetected
  |     |     +-- RepositoryUnavailable
  |     |     +-- UnverifiedEmail
  |     |     +-- AccountSuspended
  |     |     +-- BillingIssue
  |     |     +-- SAMLProtected
  |     |     +-- InstallationSuspended
  |     +-- NotFound (404)
  |     |     +-- BranchNotProtected
  |     +-- MethodNotAllowed (405)
  |     +-- NotAcceptable (406)
  |     +-- Conflict (409)
  |     +-- Deprecated (410)
  |     +-- UnsupportedMediaType (415)
  |     +-- UnprocessableEntity (422)
  |     |     +-- CommitIsNotPartOfPullRequest
  |     |     +-- PathDiffTooLarge
  |     +-- UnavailableForLegalReasons (451)
  |
  +-- Octokit::ServerError (5xx)
        +-- InternalServerError (500)
        +-- NotImplemented (501)
        +-- BadGateway (502)
        +-- ServiceUnavailable (503)
```

**Key Design Patterns:**
1. **Regex-based subclassing**: 403 errors are sub-classified by matching response body text
2. **Error context enrichment**: Rate-limited errors automatically include `RateLimit` context
3. **Credential redaction**: Error messages automatically redact sensitive tokens from URLs
4. **Documentation linking**: Errors include `documentation_url` from GitHub's response
5. **Validation errors array**: Structured `errors` accessor for 422 validation errors

```ruby
# Example: Intelligent error classification
def self.error_for_403(body)
  case body
  when /rate limit exceeded/i, /exceeded a secondary rate limit/i
    Octokit::TooManyRequests
  when /login attempts exceeded/i
    Octokit::TooManyLoginAttempts
  when /abuse/i
    Octokit::AbuseDetected
  # ... more patterns
  else
    Octokit::Forbidden
  end
end
```

### 1.2 Slack Ruby Client

**Error Hierarchy:**
Slack takes a completely different approach - **auto-generated error classes** from API spec.
Over 700 distinct error classes are generated from Slack's API error codes.

```
Faraday::Error
  |
  +-- Slack::Web::Api::Errors::SlackError (base for API errors)
  |     +-- 700+ auto-generated subclasses:
  |           AccessDenied, AccountInactive, AlreadyArchived,
  |           ChannelNotFound, InvalidAuth, RateLimited, ...
  |
  +-- Slack::Web::Api::Errors::TooManyRequestsError (429 special handling)
  |
  +-- Slack::Web::Api::Errors::ServerError
        +-- ParsingError
        +-- TimeoutError
        +-- UnavailableError
```

**Key Design Patterns:**
1. **Lookup table**: `ERROR_CLASSES` hash maps error strings to classes
2. **Inherits from Faraday::Error**: Enables middleware integration
3. **Auto-generation**: Classes generated from `lib/tasks/web.rake`
4. **Rate limit specialization**: `TooManyRequestsError` exposes `retry_after` from headers

```ruby
# Error lookup pattern
error_class = Slack::Web::Api::Errors::ERROR_CLASSES[error_message]
error_class ||= Slack::Web::Api::Errors::SlackError
raise error_class.new(error_message, redact_response(env.response))
```

### 1.3 Twilio Ruby

**Error Hierarchy:**
Twilio has the simplest hierarchy, focusing on REST error structure.

```
StandardError
  |
  +-- Twilio::REST::TwilioError (base)
        +-- Twilio::REST::RestError (main HTTP error)
        +-- Twilio::REST::ObsoleteError (deprecated API)
        +-- Twilio::REST::RestErrorV10 (legacy API version)
```

**Key Design Patterns:**
1. **Rich error context**: Includes `code`, `details`, `error_message`, `more_info`, `status_code`
2. **Formatted messages**: Multi-line error messages with all context
3. **Twilio error codes**: API returns numeric error codes separate from HTTP status

```ruby
class RestError < TwilioError
  attr_reader :message, :response, :code, :status_code, :details, :more_info, :error_message

  def format_message(initial_message)
    message = "[HTTP #{status_code}] #{code} : #{initial_message}"
    message += "\n#{error_message}" if error_message
    message += "\n#{details}" if details
    message += "\n#{more_info}" if more_info
    message + "\n\n"
  end
end
```

---

## 2. Rate Limit Handling

### 2.1 Octokit (GitHub)

**RateLimit as First-Class Object:**
```ruby
class RateLimit < Struct.new(:limit, :remaining, :resets_at, :resets_in)
  def self.from_response(response)
    info = new
    if headers = response.headers
      info.limit = headers['X-RateLimit-Limit'].to_i
      info.remaining = headers['X-RateLimit-Remaining'].to_i
      info.resets_at = Time.at(headers['X-RateLimit-Reset'].to_i)
      info.resets_in = [(info.resets_at - Time.now).to_i, 0].max
    end
    info
  end
end
```

**Features:**
- Rate limit info attached to rate-limited errors via `error.context`
- Pagination respects rate limits: stops when `rate_limit.remaining == 0`
- Explicit `rate_limit!` method to check current limits
- Auto-retry via Faraday middleware for `ServerError` exceptions

**Default Middleware Stack:**
```ruby
MIDDLEWARE = Faraday::RackBuilder.new do |builder|
  retry_exceptions = Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [Octokit::ServerError]
  builder.use Faraday::Retry::Middleware, exceptions: retry_exceptions
  builder.use Octokit::Middleware::FollowRedirects
  builder.use Octokit::Response::RaiseError
  builder.use Octokit::Response::FeedParser
  builder.adapter Faraday.default_adapter
end
```

### 2.2 Slack Ruby Client

**Rate Limit Handling in Pagination:**
```ruby
class Cursor
  include Enumerable

  def each
    retry_count = 0
    loop do
      begin
        response = client.send(verb, query)
      rescue Slack::Web::Api::Errors::TooManyRequestsError => e
        raise e if retry_count >= max_retries
        client.logger.debug("#{self.class}##{__method__}") { e.to_s }
        retry_count += 1
        sleep(e.retry_after)  # Uses Retry-After header
        next
      end
      yield response
      # ... pagination logic
    end
  end
end
```

**Features:**
- `TooManyRequestsError` exposes `retry_after` seconds from response headers
- Pagination cursor has built-in retry with backoff
- Configurable `max_retries` (default: 100)
- Sleep interval between pages to avoid rate limits

### 2.3 Twilio Ruby

**No Built-in Rate Limit Handling:**
Twilio's Ruby client does not have built-in rate limit retry logic. Errors are raised
and must be handled by the caller. This reflects Twilio's different approach where
rate limiting is less common due to account-based limits.

---

## 3. API Design Patterns

### 3.1 Octokit (GitHub)

**Client Instantiation:**
```ruby
# Module-level configuration
Octokit.configure do |c|
  c.access_token = "token"
  c.auto_paginate = true
end

# Instance configuration
client = Octokit::Client.new(access_token: "token")

# Netrc support
client = Octokit::Client.new(netrc: true)
```

**Resource Access - Flat Method Pattern:**
```ruby
# Direct method calls on client - NOT nested resources
client.repository("owner/repo")
client.create_repository("name", organization: "org")
client.repositories("user")
client.star("owner/repo")
client.branch_protection("owner/repo", "main")
```

**Authentication Patterns:**
```ruby
# Token authentication
client.access_token = "oauth_token"

# JWT/Bearer (GitHub Apps)
client.bearer_token = "jwt_token"

# Basic auth
client.login = "username"
client.password = "password"

# OAuth app credentials
client.client_id = "id"
client.client_secret = "secret"
```

**Sawyer Integration:**
Octokit uses Sawyer as its HTTP layer, which provides:
- Automatic JSON parsing to `Sawyer::Resource` objects
- Hypermedia link parsing (HATEOAS)
- Resource relation navigation

### 3.2 Slack Ruby Client

**Client Instantiation:**
```ruby
# Global configuration
Slack.configure do |config|
  config.token = "xoxb-..."
end

# Or per-client
client = Slack::Web::Client.new(token: "xoxb-...")
```

**Resource Access - Namespaced Method Pattern:**
```ruby
# Methods namespaced by API group
client.chat_postMessage(channel: '#general', text: 'Hello')
client.conversations_list
client.users_info(user: 'U123')
client.auth_test
```

**Code Generation:**
All API endpoint methods are auto-generated from Slack's API reference:
```ruby
# lib/slack/web/api/endpoints/chat.rb
# This file was auto-generated by lib/tasks/web.rake

def chat_postMessage(options = {})
  raise ArgumentError, 'Required arguments :channel missing' if options[:channel].nil?
  raise ArgumentError, 'At least one of :attachments, :blocks, :text is required' if ...
  options = encode_options_as_json(options, %i[attachments blocks metadata])
  post('chat.postMessage', options)
end
```

**Argument Validation:**
Every method includes explicit argument validation with helpful error messages.

### 3.3 Twilio Ruby

**Client Instantiation:**
```ruby
# Global configuration
Twilio.configure do |config|
  config.account_sid = "ACxxx"
  config.auth_token = "token"
end

# Direct instantiation
client = Twilio::REST::Client.new("ACxxx", "token")
```

**Resource Access - Nested Resource Pattern:**
```ruby
# Deeply nested REST resource access
client.api.account.calls.create(to: '+1...', from: '+1...', url: '...')
client.api.account.messages.list
client.api.account.calls('CA123').fetch

# With account context
client.api.v2010.account.calls.create(...)
```

**OpenAPI Code Generation:**
All resources are generated from Twilio's OpenAPI spec:
```ruby
# This code was generated by OpenAPI Generator
class CallList < ListResource
  def create(to: nil, from: nil, method: :unset, ...)
    data = Twilio::Values.of({
      'To' => to,
      'From' => from,
      ...
    })
    # ...
  end
end
```

---

## 4. Pagination Patterns

### 4.1 Octokit (GitHub)

**Auto-Pagination with Rate Limit Awareness:**
```ruby
# Enable globally
Octokit.auto_paginate = true

# Or per-request
client.repositories("user", per_page: 100)

# Pagination respects rate limits
def paginate(url, options = {})
  data = request(:get, url, opts)
  if @auto_paginate
    while @last_response.rels[:next] && rate_limit.remaining > 0
      @last_response = @last_response.rels[:next].get
      data.concat(@last_response.data)
    end
  end
  data
end
```

**Features:**
- Uses Link header relations (hypermedia)
- Configurable `per_page` (default 30, max 100)
- Stops before exhausting rate limit

### 4.2 Slack Ruby Client

**Cursor-Based Pagination with Enumerable:**
```ruby
# Returns Enumerator for lazy pagination
client.conversations_list(limit: 100).each do |response|
  response.channels.each { |channel| ... }
end

# Or collect all at once
all_channels = client.conversations_list.to_a.flat_map(&:channels)
```

**Cursor Implementation:**
```ruby
class Cursor
  include Enumerable

  def each
    next_cursor = nil
    loop do
      response = client.send(verb, { limit: page_size, cursor: next_cursor })
      yield response
      break unless response.response_metadata
      next_cursor = response.response_metadata.next_cursor
      break if next_cursor.nil? || next_cursor == ''
    end
  end
end
```

### 4.3 Twilio Ruby

**Page Object with Next/Previous Navigation:**
```ruby
class Page
  include Enumerable

  def next_page
    return nil unless next_page_url
    response = @version.domain.request('GET', next_page_url)
    self.class.new(@version, response, @solution)
  end

  def previous_page
    # Similar implementation
  end
end

# Stream helper for iteration with limits
class RecordStream
  include Enumerable

  def each
    while @page
      @page.each do |record|
        yield record
        return if @limit && current >= @limit
      end
      @page = @page.next_page
    end
  end
end
```

**Usage:**
```ruby
# Get specific page
page = client.api.account.calls.page(page_size: 50)

# Stream with limits
client.api.account.calls.stream(limit: 100).each { |call| ... }

# List all (dangerous for large collections)
calls = client.api.account.calls.list
```

---

## 5. Response Handling

### 5.1 Octokit - Sawyer::Resource

Responses are automatically wrapped in `Sawyer::Resource` objects with:
- Dot notation access (`response.login`, `response.repos_url`)
- Hash-like access (`response[:login]`)
- Hypermedia link following (`response.rels[:repos].get`)

### 5.2 Slack Ruby Client - Hashie::Mash

Responses wrapped in `Slack::Messages::Message < Hashie::Mash`:
- Dot notation access
- Hash access
- Method access for any key

### 5.3 Twilio Ruby - Instance Classes

Each resource type has dedicated Instance class:
```ruby
class CallInstance < InstanceResource
  attr_reader :sid, :date_created, :to, :from, :status, :duration, ...

  def fetch
    # Reload from API
  end

  def update(...)
    # Update resource
  end
end
```

---

## 6. Configuration DSL

### 6.1 Octokit

```ruby
Octokit.configure do |c|
  c.access_token = ENV['GITHUB_TOKEN']
  c.api_endpoint = 'https://github.example.com/api/v3/'
  c.auto_paginate = true
  c.per_page = 100
  c.middleware = custom_middleware_stack
  c.connection_options = { ssl: { verify: true } }
  c.default_media_type = 'application/vnd.github.v3+json'
  c.user_agent = 'My App'
  c.netrc = true
  c.netrc_file = '~/.netrc'
end
```

### 6.2 Slack Ruby Client

```ruby
Slack::Web::Client.configure do |config|
  config.token = ENV['SLACK_TOKEN']
  config.timeout = 30
  config.open_timeout = 10
  config.default_page_size = 100
  config.default_max_retries = 100
  config.logger = Logger.new(STDOUT)
  config.proxy = 'http://proxy.example.com'
  config.ca_path = '/path/to/certs'
  config.adapter = :typhoeus
end
```

### 6.3 Twilio Ruby

```ruby
Twilio.configure do |config|
  config.account_sid = ENV['TWILIO_ACCOUNT_SID']
  config.auth_token = ENV['TWILIO_AUTH_TOKEN']
  config.region = 'au1'
  config.edge = 'sydney'
  config.logger = Logger.new(STDOUT)
  config.http_client = custom_http_client
end
```

---

## 7. Documentation & Discoverability

### 7.1 Octokit

**YARD Documentation:**
- Every method has `@param`, `@return`, `@see` tags
- API links in documentation
- Example code in docstrings
- Alias documentation

```ruby
# Get a single repository
#
# @see https://developer.github.com/v3/repos/#get
# @param repo [Integer, String, Hash, Repository] A GitHub repository
# @return [Sawyer::Resource] Repository information
def repository(repo, options = {})
  get Repository.path(repo), options
end
alias repo repository
```

### 7.2 Slack Ruby Client

**Auto-Generated Documentation:**
- Methods include parameter descriptions from API spec
- Links to official API docs and JSON spec
- Generated from `slack-api-ref` repository

```ruby
# @option options [channel] :channel
#   Channel containing the message to be deleted.
# @option options [timestamp] :ts
#   Timestamp of the message to be deleted.
# @see https://api.slack.com/methods/chat.delete
# @see https://github.com/slack-ruby/slack-api-ref/blob/master/methods/chat/chat.delete.json
def chat_delete(options = {})
```

### 7.3 Twilio Ruby

**OpenAPI-Generated Documentation:**
- Detailed parameter descriptions
- Links to Twilio documentation
- Generated from OpenAPI spec

---

## 8. Key Takeaways for Umi

### Error Handling

1. **Hierarchical errors enable pattern matching**
   - Octokit's sub-classification of 403 errors is particularly useful
   - Consider: `[:error, :rate_limited, context]` vs `[:error, :forbidden, reason]`

2. **Error context is crucial**
   - Always include rate limit info in rate limit errors
   - Include retry guidance (retry_after header)

3. **Auto-generation from spec is powerful but inflexible**
   - Slack's 700+ error classes vs Octokit's intelligent classification

### Rate Limiting

1. **Rate limits should be first-class citizens**
   - Not just an error, but queryable state
   - Pagination should respect limits

2. **Built-in retry with backoff**
   - Use Retry-After header when available
   - Configurable max retries

### API Design

1. **Flat vs Nested resources**
   - Octokit: `client.repository("owner/repo")` - simpler, more Ruby-like
   - Twilio: `client.api.account.calls` - mirrors REST structure

2. **Code generation is common**
   - Slack and Twilio both generate from API specs
   - Octokit is hand-maintained

3. **Response wrapping**
   - Hashie::Mash or similar for flexible access
   - Sawyer::Resource for hypermedia support

### Configuration

1. **Global + per-instance configuration**
   - Module-level defaults
   - Instance overrides

2. **Environment variable defaults**
   - Octokit checks `OCTOKIT_*` env vars
   - Makes 12-factor app deployment easy

### Documentation

1. **YARD is standard**
   - `@param`, `@return`, `@see` tags
   - Links to API documentation

2. **Examples in docs**
   - Show real usage patterns
   - Document aliases
