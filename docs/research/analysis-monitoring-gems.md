# Analysis of Error Monitoring Gems: Resilience Patterns

This document analyzes the resilience patterns found in three production-grade Ruby error
monitoring gems: **sentry-ruby**, **newrelic_rpm**, and **rollbar**. These gems share a
critical constraint: they must NEVER crash or degrade the host application they monitor.

## Executive Summary

All three gems share common resilience patterns:
1. **Background workers** with thread pools or dedicated threads
2. **Exception swallowing** at critical boundaries
3. **Rate limiting** with backoff strategies
4. **Graceful degradation** when overloaded
5. **Payload truncation** to prevent memory issues
6. **Sensitive data scrubbing** before transmission

---

## 1. Failure Isolation

### Sentry-Ruby

**Location:** `sentry-ruby/lib/sentry/background_worker.rb`, `sentry-ruby/lib/sentry/client.rb`

Sentry uses the `concurrent-ruby` gem's ThreadPoolExecutor for isolation:

```ruby
# From background_worker.rb
@executor = Concurrent::ThreadPoolExecutor.new(
  min_threads: 0,
  max_threads: @number_of_threads,
  max_queue: @max_queue,
  fallback_policy: :discard  # KEY: Silently drop when queue full
)

def perform(&block)
  @executor.post do
    begin
      _perform(&block)
    rescue Exception => e
      log_error("exception happened in background worker", e, debug: @debug)
      # Exception is swallowed - never propagates to host app
    end
  end
end
```

**Key Pattern:** The `fallback_policy: :discard` ensures that when the queue is full,
new events are silently dropped rather than blocking or raising.

In `client.rb`, exception handling wraps all capture operations:

```ruby
def capture_event(event, scope, hint = {})
  # ... event processing ...
rescue => e
  log_error("Event capturing failed", e, debug: configuration.debug)
  nil  # Returns nil instead of raising
end

def send_event(event, hint = nil)
  # ... sending logic ...
rescue => e
  log_error("Event sending failed", e, debug: configuration.debug)
  transport.record_lost_event(:network_error, data_category)
  raise  # Re-raised but only within background worker context
end
```

### NewRelic RPM

**Location:** `newrelic-ruby-agent/lib/new_relic/agent/agent_helpers/start_worker_thread.rb`

NewRelic uses a comprehensive exception catching pattern:

```ruby
# From start_worker_thread.rb
def catch_errors
  yield
rescue NewRelic::Agent::ForceRestartException => e
  handle_force_restart(e)
  retry
rescue NewRelic::Agent::ForceDisconnectException => e
  handle_force_disconnect(e)
rescue => e
  handle_other_error(e)
end

def handle_other_error(error)
  ::NewRelic::Agent.logger.error('Unhandled error in worker thread, disconnecting.')
  ::NewRelic::Agent.logger.log_exception(:error, error)
  disconnect  # Graceful shutdown, not crash
end
```

**Key Pattern:** The `catch_errors` wrapper guarantees no exception escapes the worker thread.
Known exception types are handled specifically, while unknown errors trigger graceful disconnection.

### Rollbar

**Location:** `rollbar/lib/rollbar/notifier.rb`

Rollbar wraps report operations with internal error reporting:

```ruby
# From notifier.rb
def report_with_rescue(level, message, exception, extra, context, is_uncaught)
  report(level, message, exception, extra, context, is_uncaught)
rescue StandardError, SystemStackError => e
  original_error = {
    :message => message,
    :exception => exception,
    :configuration => configuration
  }
  report_internal_error(e, original_error)
  'error'  # Returns string status instead of raising
end
```

**Key Pattern:** Rollbar has a "failsafe" mechanism - if reporting the error fails,
it attempts to report the *internal* error instead:

```ruby
def report_internal_error(exception, original_error = nil)
  return if skip_reporting_internal_error(exception)

  # Try to report the internal error
  item = build_item('error', nil, exception, { :internal => true }, nil, false)
  process_item(item)
rescue StandardError => e
  # If that also fails, send a minimal "failsafe" payload
  send_failsafe(failsafe_message, e, original_error)
end
```

---

## 2. Async/Background Sending

### Sentry-Ruby

**Location:** `sentry-ruby/lib/sentry/background_worker.rb`

Uses `concurrent-ruby`'s ThreadPoolExecutor:

```ruby
def initialize(configuration)
  @number_of_threads = configuration.background_worker_threads
  @max_queue = configuration.background_worker_max_queue

  @executor = if @number_of_threads == 0
    # Synchronous execution for debugging
    Concurrent::ImmediateExecutor.new
  else
    Concurrent::ThreadPoolExecutor.new(
      min_threads: 0,
      max_threads: @number_of_threads,
      max_queue: @max_queue,
      fallback_policy: :discard
    )
  end
end

def full?
  @executor.is_a?(Concurrent::ThreadPoolExecutor) &&
    @executor.remaining_capacity == 0
end
```

**Graceful Shutdown:**

```ruby
@shutdown_callback = proc do
  executor.shutdown
  executor.wait_for_termination(@shutdown_timeout)  # Default: 1 second
end
```

### NewRelic RPM

**Location:** `newrelic-ruby-agent/lib/new_relic/agent/event_loop.rb`

NewRelic implements a custom event loop with timer-based harvesting:

```ruby
class EventLoop
  def initialize
    @self_pipe_rd, @self_pipe_wr = IO.pipe  # Self-pipe trick for wakeup
    @event_queue = Queue.new
    @stopped = false
    @timers = {}
    @subscriptions = Hash.new { |h, k| h[k] = [] }
  end

  def run
    while !stopped?
      run_once
    end
  end

  def run_once(nonblock = false)
    wait_to_run(nonblock)
    prune_timers
    fire_timers

    until @event_queue.empty?
      evt, args = @event_queue.pop
      dispatch_event(evt, args)
      reschedule_timer_for_event(evt)
    end
  end

  def dispatch_event(event, args)
    errors = []
    @subscriptions[event].each do |s|
      begin
        s.call(*args)
      rescue NewRelic::Agent::ForceRestartException, ForceDisconnectException
        raise  # These are expected control flow
      rescue => e
        errors << e  # Collect errors but continue
      end
    end

    if !errors.empty?
      ::NewRelic::Agent.logger.error("#{errors.size} error(s) running task...")
    end
  end
end
```

**Timer Pattern:** Uses `fire_every` for periodic harvesting:

```ruby
@event_loop.fire_every(Agent.config[:data_report_period], data_harvest)
@event_loop.fire_every(Agent.config[:event_report_period], event_harvest)
```

### Rollbar

**Location:** `rollbar/lib/rollbar/delay/thread.rb`

Rollbar provides multiple async handlers (Thread, Sidekiq, Resque, ActiveJob, etc.):

```ruby
# Thread-based handler
class Thread
  EXIT_SIGNAL  = :exit
  EXIT_TIMEOUT = 6

  def self.call(payload)
    spawn_threads_reaper
    thread = new.call(payload)
    threads << thread
    thread
  end

  def call(payload)
    ::Thread.new do
      begin
        ::Thread.current.priority = priority
        Rollbar.process_from_async_handler(payload)
      rescue StandardError
        # Swallow exceptions - errors logged internally
      end
    end
  end
end
```

**Failover Handlers:**

```ruby
def process_async_item(item)
  configuration.async_handler.call(payload)
rescue StandardError
  if configuration.failover_handlers.empty?
    log_error '[Rollbar] Async handler failed, no failover handlers'
    return
  end
  async_failover(item)  # Try fallback handlers
end

def async_failover(item)
  failover_handlers.each do |handler|
    begin
      handler.call(item.payload)
      return  # Success, stop trying
    rescue StandardError
      next  # Try next handler
    end
  end
  log_error '[Rollbar] All failover handlers failed'
end
```

---

## 3. Rate Limiting

### Sentry-Ruby

**Location:** `sentry-ruby/lib/sentry/transport.rb`, `sentry-ruby/lib/sentry/backpressure_monitor.rb`

**Server-Side Rate Limiting:**

```ruby
# From http_transport.rb
RETRY_AFTER_HEADER = "retry-after"
RATE_LIMIT_HEADER = "x-sentry-rate-limits"

def handle_rate_limited_response(headers)
  rate_limits = if rate_limits = headers[RATE_LIMIT_HEADER]
    parse_rate_limit_header(rate_limits)
  elsif retry_after = headers[RETRY_AFTER_HEADER]
    { nil => Time.now + retry_after.to_i }
  else
    { nil => Time.now + DEFAULT_DELAY }  # 60 seconds
  end

  rate_limits.each do |category, limit|
    @rate_limits[category] = limit
  end
end

def is_rate_limited?(data_category)
  delay = @rate_limits[data_category] || @rate_limits[nil]
  !!delay && delay > Time.now
end
```

**Backpressure Monitoring:**

```ruby
# From backpressure_monitor.rb
class BackpressureMonitor < ThreadedPeriodicWorker
  MAX_DOWNSAMPLE_FACTOR = 10

  def check_health
    @healthy = !(@client.transport.any_rate_limited? ||
                 Sentry.background_worker&.full?)
  end

  def set_downsample_factor
    if @healthy
      @downsample_factor = 0
    else
      @downsample_factor += 1 if @downsample_factor < MAX_DOWNSAMPLE_FACTOR
    end
  end
end
```

**Client-Side Sampling:**

```ruby
# From configuration.rb
def sample_allowed?
  return true if sample_rate == 1.0
  Random.rand < sample_rate
end
```

### NewRelic RPM

**Location:** `newrelic-ruby-agent/lib/new_relic/agent/adaptive_sampler.rb`

NewRelic implements sophisticated adaptive sampling:

```ruby
class AdaptiveSampler
  def initialize(target_samples = 10, period_duration = 60)
    @target = target_samples
    @seen = 0
    @seen_last = 0
    @sampled_count = 0
    @period_duration = period_duration
  end

  def sampled?
    @lock.synchronize do
      reset_if_period_expired!

      sampled = if @first_period
        @sampled_count < 10  # Always sample first 10
      elsif @sampled_count < @target
        rand(@seen_last) < @target  # Random based on last period
      else
        # Exponential backoff once target reached
        rand(@seen) < exponential_backoff
      end

      @sampled_count += 1 if sampled
      @seen += 1
      sampled
    end
  end

  def exponential_backoff
    @target**(@target.to_f / @sampled_count) - @target**0.5
  end
end
```

### Rollbar

Rollbar doesn't have built-in rate limiting but provides configuration hooks:

```ruby
# From configuration.rb
# Filtering by exception level
@exception_level_filters = {
  'ActiveRecord::RecordNotFound' => 'warning',
  'AbstractController::ActionNotFound' => 'warning',
  'ActionController::RoutingError' => 'warning'
}

# Before-process hooks can return 'ignored' to skip
def call_before_process(options)
  handlers.each do |handler|
    status = handler.call(options)
    return 'ignored' if status == 'ignored'
  end
end
```

---

## 4. Error Context & Breadcrumbs

### Sentry-Ruby

**Location:** `sentry-ruby/lib/sentry/breadcrumb.rb`, `sentry-ruby/lib/sentry/scope.rb`

**Breadcrumb Buffer:**

```ruby
# From breadcrumb.rb
class Breadcrumb
  MAX_NESTING = 10

  def serialized_data
    begin
      ::JSON.parse(::JSON.generate(@data, max_nesting: MAX_NESTING))
    rescue Exception => e
      # If serialization fails, don't crash - return error message
      { error: DATA_SERIALIZATION_ERROR_MESSAGE }
    end
  end
end

# From breadcrumb_buffer.rb (not shown but referenced)
class BreadcrumbBuffer
  DEFAULT_SIZE = 100

  def record(crumb)
    @buffer << crumb
    @buffer.shift if @buffer.size > @max_breadcrumbs
  end
end
```

**Scope Management:**

```ruby
# From scope.rb
class Scope
  ATTRIBUTES = [:transaction_name, :contexts, :extra, :tags, :user,
                :level, :breadcrumbs, :fingerprint, :event_processors, ...]

  def apply_to_event(event, hint = nil)
    event.tags = tags.merge(event.tags)
    event.user = user.merge(event.user)
    event.extra = extra.merge(event.extra)
    event.contexts = contexts.merge(event.contexts)
    event.breadcrumbs = breadcrumbs

    # Run event processors (can modify or drop events)
    all_event_processors.each do |processor_block|
      event = processor_block.call(event, hint)
    end
    event
  end
end
```

### NewRelic RPM

**Location:** Various aggregator files

NewRelic uses event aggregators with priority-sampled buffers:

```ruby
# From event_aggregator.rb
class EventAggregator
  def initialize(events)
    @lock = Mutex.new
    @buffer = PrioritySampledBuffer.new(Agent.config[capacity_key])
    @notified_full = false
  end

  def harvest!
    metadata = nil
    samples = []
    @lock.synchronize do
      samples.concat(@buffer.to_a)
      metadata = @buffer.metadata
      reset_buffer!
    end
    [reservoir_metadata(metadata), samples]
  end

  def merge!(payload, adjust_count = true)
    @lock.synchronize do
      _, samples = payload
      if adjust_count
        @buffer.decrement_lifetime_counts_by(samples.count)
      end
      samples.each { |s| @buffer.append(event: s) }
    end
  end
end
```

### Rollbar

**Location:** `rollbar/lib/rollbar/item.rb`

Rollbar captures context through scope objects and custom data methods:

```ruby
# From item.rb
def build_extra
  merged_extra = Util.deep_merge(scrub(extra), scrub(error_context))

  if custom_data_method?
    Util.deep_merge(scrub(custom_data), merged_extra)
  else
    merged_extra.empty? ? nil : merged_extra
  end
end

def custom_data
  data = if configuration.custom_data_method.arity == 3
    configuration.custom_data_method.call(message, exception, context)
  else
    configuration.custom_data_method.call
  end
  Rollbar::Util.deep_copy(data)
rescue StandardError => e
  return {} if configuration.safely?
  report_custom_data_error(e)  # Report the error in custom_data_method
end
```

---

## 5. Configuration & Environment Detection

### Sentry-Ruby

**Location:** `sentry-ruby/lib/sentry/configuration.rb`

```ruby
# Environment detection
def environment_from_env
  ENV["SENTRY_CURRENT_ENV"] || ENV["SENTRY_ENVIRONMENT"] ||
  ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
end

# DSN from environment
def initialize
  self.dsn = ENV["SENTRY_DSN"]
  # ...
end

# Exception filtering
IGNORE_DEFAULT = [
  "Mongoid::Errors::DocumentNotFound",
  "Rack::QueryParser::InvalidParameterError",
  "Sinatra::NotFound"
].freeze

# Sensitive data handling
attr_accessor :send_default_pii  # Default: false
```

### NewRelic RPM

**Location:** `newrelic-ruby-agent/lib/new_relic/agent/configuration/`

NewRelic has a sophisticated layered configuration system:

```ruby
# Configuration sources (in priority order):
# 1. Manual (API calls)
# 2. Server (from collector)
# 3. Environment variables
# 4. YAML file
# 5. Defaults

# From environment_source.rb
BOOLEAN_MAP = {
  'true' => true,
  'yes' => true,
  'on' => true,
  'false' => false,
  'no' => false,
  'off' => false
}.freeze
```

### Rollbar

**Location:** `rollbar/lib/rollbar/configuration.rb`

```ruby
# Scrub fields for sensitive data
@scrub_fields = [:passwd, :password, :password_confirmation, :secret,
                 :confirm_password, :secret_token, :api_key, :access_token,
                 :accessToken, :session_id]

# Network retry configuration
@open_timeout = 3
@request_timeout = 3
@net_retries = 3

# Internal errors to ignore (network issues)
@ignore_internal_errors = [
  'Net::ReadTimeout',
  'Net::OpenTimeout',
  'SocketError'
]
```

---

## 6. Performance Patterns

### Payload Truncation

**Sentry:**
```ruby
# From envelope.rb (Item class)
def serialize
  result, oversized = item.serialize
  if oversized
    log_debug("Envelope item is still oversized after size reduction")
    next  # Skip oversized items
  end
end
```

**Rollbar:**
```ruby
# From truncation.rb
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

def self.truncate(payload, attempts = [])
  STRATEGIES.each do |strategy|
    result = strategy.call(payload)
    attempts << result.bytesize
    break unless truncate?(result)
  end
  result
end
```

### Lazy Initialization

**Sentry:**
```ruby
# From configuration.rb
def stacktrace_builder
  @stacktrace_builder ||= StacktraceBuilder.new(...)
end
```

**NewRelic:**
```ruby
# Singleton pattern with lazy initialization
def self.instance
  @instance ||= self.new
end
```

### Memory Management

**Sentry - Breadcrumb Buffer:**
```ruby
def record(crumb)
  @buffer << crumb
  @buffer.shift if @buffer.size > @max_breadcrumbs  # Fixed-size buffer
end
```

**NewRelic - Priority Sampling:**
```ruby
# When buffer is full, use priority to decide what to keep
# Higher priority events replace lower priority ones
```

---

## Summary: Key Resilience Patterns for Umi

Based on this analysis, the key patterns applicable to Umi:

1. **Exception Swallowing at Boundaries**
   - All three gems catch exceptions at the outermost boundary of any operation
   - Errors are logged but never propagated to the host application
   - Internal errors trigger fallback/failsafe mechanisms

2. **Thread Pool with Discard Policy**
   - Sentry's `fallback_policy: :discard` is particularly elegant
   - When overwhelmed, silently drop rather than block or crash

3. **Graceful Degradation**
   - Rate limiting with exponential backoff
   - Adaptive sampling under load
   - Multiple truncation strategies for payloads

4. **Self-Healing**
   - Automatic reconnection after failures
   - Period-based reset of sampling counters
   - Failover handlers when primary fails

5. **Defense in Depth**
   - Multiple layers of exception handling
   - Failsafe mechanisms for when normal paths fail
   - Timeout on all network operations

6. **Minimal Dependencies**
   - Core functionality has few external dependencies
   - Optional features load dependencies lazily

These patterns align well with Umi's philosophy of "let it crash, but contain it" -
the monitoring gems implement this by ensuring failures are contained and logged,
never propagated to the host application.
