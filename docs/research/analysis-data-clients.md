# Analysis of Ruby Data/Infrastructure Client Gems

## Overview

This document analyzes three battle-tested Ruby gems that handle critical infrastructure
communication: **redis-rb**, **elasticsearch-ruby**, and **sidekiq**. These gems have
evolved over years of production use and contain proven patterns for reliability,
connection management, and error handling.

This analysis is conducted to inform the design of Umi's resilience patterns.

---

## 1. Redis-rb (redis/redis-rb)

### Architecture Overview

Redis-rb is a thin wrapper around `redis-client` (the low-level Redis protocol gem).
It provides:
- High-level Ruby DSL for Redis commands
- Error translation layer
- Pipelining and transactions
- Pub/sub support
- Distributed (client-side sharding) and Cluster support

### 1.1 Connection Management

**Key Files:** `lib/redis.rb`, `lib/redis/client.rb`, `lib/redis/distributed.rb`

#### Basic Connection Pattern

```ruby
# lib/redis.rb - Thread-safe via Monitor
def initialize(options = {})
  @monitor = Monitor.new
  @options = options.dup
  @options[:reconnect_attempts] = 1 unless @options.key?(:reconnect_attempts)
  # ...
  @client = initialize_client(@options)
end

def synchronize
  @monitor.synchronize { yield(@client) }
end
```

**Insights:**
- Uses `Monitor` (reentrant mutex) for thread safety
- Default reconnect attempts is 1 (conservative)
- Supports `inherit_socket` for forked processes
- Lazy connection - connects on first command, not on initialization

#### Connection Pooling

Redis-rb itself doesn't pool; it's typically wrapped with `connection_pool`:

```ruby
# Example usage (not in redis-rb itself)
pool = ConnectionPool.new(size: 5) { Redis.new }
pool.with { |conn| conn.get("key") }
```

#### Reconnection Logic

Handled by `redis-client` under the hood, but redis-rb provides:

```ruby
def without_reconnect(&block)
  @client.disable_reconnection(&block)
end
```

### 1.2 Error Handling

**Key File:** `lib/redis/errors.rb`

#### Error Class Hierarchy

```ruby
class Redis
  # Base error for all redis-rb errors
  class BaseError < StandardError; end

  # Protocol errors (malformed responses)
  class ProtocolError < BaseError; end

  # Command execution errors
  class CommandError < BaseError; end
  class PermissionError < CommandError; end
  class WrongTypeError < CommandError; end
  class OutOfMemoryError < CommandError; end
  class NoScriptError < CommandError; end   # conditional

  # Connection-related errors (transient)
  class BaseConnectionError < BaseError; end
  class CannotConnectError < BaseConnectionError; end
  class ConnectionError < BaseConnectionError; end
  class TimeoutError < BaseConnectionError; end
  class InheritedError < BaseConnectionError; end
  class ReadOnlyError < BaseConnectionError; end   # failover scenarios

  # Configuration errors
  class InvalidClientOptionError < BaseError; end
  class SubscriptionError < BaseError; end
end
```

**Design Insights:**
- Clear separation: Command errors vs Connection errors vs Config errors
- `ReadOnlyError` specifically for Redis failover scenarios (replica promotion)
- Connection errors are transient and retryable
- Command errors are generally permanent (except `NoScriptError`)

#### Error Translation Layer

```ruby
# lib/redis/client.rb
ERROR_MAPPING = {
  RedisClient::ConnectionError => Redis::ConnectionError,
  RedisClient::CommandError => Redis::CommandError,
  RedisClient::ReadTimeoutError => Redis::TimeoutError,
  RedisClient::CannotConnectError => Redis::CannotConnectError,
  RedisClient::AuthenticationError => Redis::CannotConnectError,
  RedisClient::FailoverError => Redis::CannotConnectError,
  # ...
}

def call_v(command, &block)
  super(command, &block)
rescue ::RedisClient::Error => error
  Client.translate_error!(error)
end
```

**Pattern:** Wrap lower-level errors to maintain stable public API.

### 1.3 Distributed Redis (Client-Side Sharding)

**Key File:** `lib/redis/distributed.rb`

```ruby
class Distributed
  # Commands that cannot be distributed
  class CannotDistribute < RuntimeError; end

  def node_for(key)
    key = key_tag(key.to_s) || key.to_s
    @ring.get_node(key)  # Consistent hashing
  end

  # Multi-key operations are grouped by node
  def del(*args)
    keys_per_node = args.group_by { |key| node_for(key) }
    keys_per_node.inject(0) do |sum, (node, keys)|
      sum + node.del(*keys)
    end
  end

  # Some operations require all keys on same node
  def ensure_same_node(command, keys)
    # ... validates all keys hash to same node
    yield(node_for(keys.first))
  end
end
```

**Design Insights:**
- Uses HashRing for consistent hashing
- Key tags (e.g., `{user}:profile`) force related keys to same shard
- Explicit errors for non-distributable commands (transparency)
- Operations that span nodes aggregate results

### 1.4 Pipelining and Transactions

**Key File:** `lib/redis/pipeline.rb`

```ruby
class Future < BasicObject
  def initialize(command, coerce, exception)
    @command = command
    @object = FutureNotReady  # sentinel value
    @coerce = coerce
    @exception = exception
  end

  def _set(object)
    @object = @coerce ? @coerce.call(object) : object
    value
  end

  def value
    ::Kernel.raise(@object) if @exception && @object.is_a?(::StandardError)
    @object
  end
end
```

**Insights:**
- Futures defer result access until pipeline executes
- Optional exception propagation (`exception: false` for silent failures)
- Response coercion callbacks for type transformation

### 1.5 Cluster Support

**Key Files:** `cluster/lib/redis/cluster.rb`, `cluster/lib/redis/cluster/client.rb`

```ruby
class Cluster < ::Redis
  # Additional error types for cluster operations
  class InitialSetupError < BaseError; end
  class OrchestrationCommandNotSupported < BaseError; end
  class CommandErrorCollection < BaseError
    attr_reader :errors  # Hash{String => Redis::CommandError}
  end
  class AmbiguousNodeError < BaseError; end
  class TransactionConsistencyError < BaseError; end
  class NodeMightBeDown < BaseError; end

  # WATCH requires block form in cluster mode
  def watch(*keys, &block)
    unless block_given?
      raise TransactionConsistencyError, 'A block is required'
    end
    # ...
  end
end
```

**Design Insights:**
- Cluster has its own error hierarchy
- `CommandErrorCollection` aggregates errors from multiple nodes
- API constraints enforced at runtime (e.g., block required for WATCH)
- Delegates to `redis-cluster-client` for slot management

---

## 2. Elasticsearch-ruby (elastic/elasticsearch-ruby)

### Architecture Overview

Elasticsearch-ruby is split into multiple gems:
- `elasticsearch` - High-level client with API validation
- `elasticsearch-api` - API method definitions (auto-generated)
- `elastic-transport` - HTTP transport layer

### 2.1 Connection Management

**Key Files:** `elastic-transport/lib/elastic/transport/client.rb`, `.../transport/base.rb`

#### Transport Layer Configuration

```ruby
# elastic-transport/lib/elastic/transport/client.rb
class Client
  DEFAULT_TRANSPORT_CLASS = Transport::HTTP::Faraday

  def initialize(arguments = {}, &block)
    @arguments[:reload_connections] ||= false
    @arguments[:retry_on_failure]   ||= false
    @arguments[:delay_on_retry]     ||= 0
    @arguments[:reload_on_failure]  ||= false
    @arguments[:randomize_hosts]    ||= false
    # ...
    @hosts ||= extract_hosts
    @transport = @transport_class.new(hosts: @hosts, options: @arguments)
  end
end
```

**Configuration Options:**
- `resurrect_after: 60` - Seconds before retrying dead connection
- `reload_connections: 10_000` - Reload topology every N requests
- `retry_on_failure: 3` - Retry count on connection failure
- `delay_on_retry: 0` - Milliseconds between retries
- `randomize_hosts: false` - Shuffle hosts on init/reload

#### Connection Pool with Health Tracking

```ruby
# elastic-transport/lib/elastic/transport/transport/connections/collection.rb
class Collection
  DEFAULT_SELECTOR = Selector::RoundRobin

  def connections
    @connections.reject { |c| c.dead? }  # Only alive connections
  end

  def dead
    @connections.select { |c| c.dead? }
  end

  def get_connection(options = {})
    # Fallback to least-failed connection if all are dead
    selector.select(options) || @connections.min_by(&:failures)
  end
end
```

#### Connection Health States

```ruby
# elastic-transport/lib/elastic/transport/transport/connections/connection.rb
class Connection
  DEFAULT_RESURRECT_TIMEOUT = 60

  def dead!
    @state_mutex.synchronize do
      @dead = true
      @failures += 1
      @dead_since = Time.now
    end
  end

  def healthy!
    @state_mutex.synchronize do
      @dead = false
      @failures = 0  # Reset on success
    end
  end

  def resurrectable?
    @state_mutex.synchronize {
      # Exponential backoff: timeout * 2^(failures-1)
      Time.now > @dead_since + (@options[:resurrect_timeout] * 2 ** (@failures - 1))
    }
  end
end
```

**Key Patterns:**
- Three states: alive, dead, resurrectable
- Exponential backoff for resurrection (2^failures multiplier)
- Thread-safe state transitions via mutex
- Failure count tracks connection quality

#### Connection Selection Strategies

```ruby
# Selector implementations
class Random
  def select(options = {})
    connections.to_a.sample
  end
end

class RoundRobin
  def select(options = {})
    @mutex.synchronize do
      conns = connections
      @current = (@current && @current < conns.size - 1) ? @current + 1 : 0
      conns[@current]
    end
  end
end
```

### 2.2 Error Handling

**Key File:** `elastic-transport/lib/elastic/transport/transport/errors.rb`

```ruby
module Transport
  # Generic client error
  class Error < StandardError; end

  # Timeout during connection sniffing
  class SnifferTimeoutError < Timeout::Error; end

  # Server-side errors (5xx)
  class ServerError < Error; end

  # Dynamically generated per HTTP status code
  HTTP_STATUSES = {
    400 => 'BadRequest',
    401 => 'Unauthorized',
    403 => 'Forbidden',
    404 => 'NotFound',
    408 => 'RequestTimeout',
    409 => 'Conflict',
    429 => 'TooManyRequests',
    500 => 'InternalServerError',
    502 => 'BadGateway',
    503 => 'ServiceUnavailable',
    504 => 'GatewayTimeout',
    # ... many more
  }

  # Generate error classes dynamically
  ERRORS = HTTP_STATUSES.each_with_object({}) do |error, sum|
    status, name = error
    sum[status] = Errors.const_set(name, Class.new(ServerError))
  end
end
```

**Design Insights:**
- Every HTTP status code gets its own exception class
- All 4xx/5xx errors inherit from `ServerError`
- Enables fine-grained rescue: `rescue Errors::TooManyRequests`
- Dynamic class generation keeps code DRY

### 2.3 Resilience Features

**Key File:** `elastic-transport/lib/elastic/transport/transport/base.rb`

#### Retry with Failover

```ruby
def perform_request(method, path, params = {}, body = nil, headers = nil, opts = {}, &block)
  start = Time.now
  tries = 0
  max_retries = max_retries(opts) || max_retries(options)

  begin
    sleep(delay_on_retry / 1000.0) if tries > 0
    tries += 1
    connection = get_connection or raise Error.new('Cannot get new connection from pool.')

    response = block.call(connection, url)
    connection.healthy! if connection.failures.positive?

    # Retry on specific status codes
    __raise_transport_error(response) if response.status.to_i >= 300 &&
                                         @retry_on_status.include?(response.status.to_i)

  rescue *host_unreachable_exceptions => e
    connection.dead!

    if reload_on_failure && tries < connections.all.size
      reload_connections! and retry
    end

    raise unless max_retries

    if tries <= max_retries
      retry
    else
      raise
    end
  end
end
```

**Resilience Patterns:**
1. **Retry on Status:** Configurable retry for specific HTTP codes (e.g., 503)
2. **Connection Marking:** Failed connections marked dead
3. **Reload on Failure:** Refresh cluster topology on connection failure
4. **Delay Between Retries:** Configurable backoff
5. **Health Recovery:** Reset failures on successful request

#### Cluster Topology Discovery (Sniffing)

```ruby
def reload_connections!
  hosts = sniffer.hosts  # Query cluster for nodes
  __rebuild_connections(hosts: hosts, options: options)
rescue SnifferTimeoutError
  log_error('[SnifferTimeoutError] Timeout when reloading connections.')
end
```

#### Resurrection of Dead Connections

```ruby
def get_connection(options = {})
  resurrect_dead_connections! if Time.now > @last_request_at + @resurrect_after
  # ...
  connections.get_connection(options)
end

def resurrect_dead_connections!
  connections.dead.each(&:resurrect!)
end
```

### 2.4 Protocol Handling

**HTTP Abstraction:**
- Supports multiple HTTP adapters via Faraday (patron, typhoeus, httpclient, etc.)
- Auto-detects best available adapter
- Handles request/response compression (gzip)
- OpenTelemetry integration for tracing

**Request Processing:**

```ruby
def perform_request(method, path, params = {}, body = nil, headers = nil, opts = {})
  method = @send_get_body_as if method == 'GET' && body
  validate_ca_fingerprints if @ca_fingerprint

  # OpenTelemetry span wrapping
  if @otel
    @otel.tracer.in_span(span_name) do |span|
      span['http.request.method'] = method
      span['db.system'] = 'elasticsearch'
      transport.perform_request(method, path, params || {}, body, headers)
    end
  else
    transport.perform_request(method, path, params || {}, body, headers)
  end
end
```

### 2.5 API Design

**Namespace Pattern:**

```ruby
# elasticsearch-api/lib/elasticsearch/api.rb
API_NAMESPACES = [
  :async_search, :cat, :cluster, :indices, :nodes, :snapshot, ...
]

API_NAMESPACES.each do |namespace|
  klass = Class.new(Object) do
    include CommonClient, Object.const_get("Elasticsearch::API::#{module_name}::Actions")
  end
  define_method(name) { @#{name} ||= klass.new(self) }
end

# Usage: client.indices.create(index: 'test')
```

**Key Patterns:**
- Namespaced API (mirrors Elasticsearch's API structure)
- Method chaining: `client.cluster.health`
- Lazy initialization of namespace clients

---

## 3. Sidekiq (sidekiq/sidekiq)

### Architecture Overview

Sidekiq is a background job processor using Redis as a queue. Key components:
- **Client:** Pushes jobs to Redis
- **Server:** Fetches and processes jobs
- **Middleware:** Pipeline for job processing
- **Retry System:** Automatic retry with exponential backoff
- **Dead Job Queue:** Final destination for failed jobs

### 3.1 Connection Management

**Key Files:** `lib/sidekiq/redis_connection.rb`, `lib/sidekiq/capsule.rb`

#### Connection Pool Creation

```ruby
# lib/sidekiq/redis_connection.rb
module RedisConnection
  def self.create(options = {})
    # Deep symbolize keys
    symbolized_options = deep_symbolize_keys(options)
    symbolized_options[:url] ||= determine_redis_provider

    # Security: Wrap passwords in Procs to avoid logging
    symbolized_options[:password] = wrap(symbolized_options[:password]) if symbolized_options.key?(:password)

    # Default timeout is more generous than redis-client default
    symbolized_options[:timeout] ||= 3

    redis_config = Sidekiq::RedisClientAdapter.new(symbolized_options)

    # Use connection_pool gem
    ConnectionPool.new(timeout: pool_timeout, size: size) do
      redis_config.new_client
    end
  end

  private

  def wrap(pwd)
    pwd.is_a?(String) ? ->(username) { pwd } : pwd
  end
end
```

**Key Insights:**
- Uses `connection_pool` gem for pooling
- Passwords wrapped in Procs to prevent accidental logging
- Default timeout of 3s (higher than redis-client's 1s default)
- Pool size configurable, default 5

#### Capsule-Based Pool Isolation

```ruby
# lib/sidekiq/capsule.rb - Each capsule gets its own pool
class Capsule
  def redis_pool
    Thread.current[:sidekiq_redis_pool] || local_redis_pool
  end

  def local_redis_pool
    @redis ||= config.new_redis_pool(@concurrency, name)
  end

  # Retry pattern for failover scenarios
  def redis
    redis_pool.with do |conn|
      retryable = true
      begin
        yield conn
      rescue RedisClientAdapter::BaseError => ex
        # Handle Redis failover: READONLY, NOREPLICAS, UNBLOCKED
        if retryable && ex.message =~ /READONLY|NOREPLICAS|UNBLOCKED/
          conn.close
          retryable = false
          retry
        end
        raise
      end
    end
  end
end
```

**Failover Handling:**
- `READONLY` - Replica was promoted, reconnect to find primary
- `NOREPLICAS` - Not enough replicas for write (reconnect may help)
- `UNBLOCKED` - Blocking command interrupted (retry)

### 3.2 Error Handling

#### Exception Hierarchy

```ruby
# lib/sidekiq.rb
module Sidekiq
  # Raised during hard shutdown timeout
  # DO NOT RESCUE THIS - needed for transaction rollback
  class Shutdown < Interrupt; end
end

# lib/sidekiq/job_retry.rb
class JobRetry
  # Job failed but has been handled (retry scheduled)
  class Handled < ::RuntimeError; end

  # Job failed, skip logging and error handlers
  class Skip < Handled; end
end
```

**Design Insights:**
- `Shutdown` inherits from `Interrupt` for proper signal handling
- `Handled` vs `Skip` controls whether error is logged/reported
- Exception wrapping allows retry system to communicate with processor

### 3.3 Retry System (Dead Letter Pattern)

**Key File:** `lib/sidekiq/job_retry.rb`

#### Retry Philosophy

```ruby
# Sidekiq's retry support assumes a typical development lifecycle:
#   0. Push some code changes with a bug in it.
#   1. Bug causes job processing to fail, Sidekiq captures
#      the job and pushes it onto a retry queue.
#   2. Sidekiq retries jobs with exponential delay, job continues to fail.
#   3. After a few days, developer deploys a fix. Job succeeds.
#   4. After retries exhausted, job goes to Dead Job Queue (morgue).
#   5. After 6 months on DJQ, Sidekiq discards the job.
```

#### Retry Implementation

```ruby
class JobRetry
  DEFAULT_MAX_RETRY_ATTEMPTS = 25  # ~3 weeks

  def process_retry(jobinst, msg, queue, exception)
    max_retry_attempts = retry_attempts_from(msg["retry"], @max_retries)

    # Track retry metadata
    count = if msg["retry_count"]
      msg["retried_at"] = now_ms
      msg["retry_count"] += 1
    else
      msg["failed_at"] = now_ms
      msg["retry_count"] = 0
    end

    msg["error_message"] = exception.message[0, 10_000]  # Truncate
    msg["error_class"] = exception.class.name

    # Check for exhaustion
    if count >= max_retry_attempts
      return retries_exhausted(jobinst, msg, exception)
    end

    # Calculate delay with jitter
    strategy, delay = delay_for(jobinst, count, exception, msg)
    jitter = rand(10 * (count + 1))
    retry_at = Time.now.to_f + delay + jitter

    # Schedule retry
    redis { |conn| conn.zadd("retry", retry_at.to_s, payload) }
  end

  # Exponential backoff: count^4 + 15 seconds
  def delay_for(jobinst, count, exception, msg)
    # Jobs can customize via sidekiq_retry_in block
    rv = jobinst&.sidekiq_retry_in_block&.call(count, exception, msg)

    delay = (count ** 4) + 15  # Default formula

    case rv
    when Integer then delay = rv if rv > 0
    when :discard then return [:discard, nil]
    when :kill then return [:kill, nil]
    end

    [:default, delay]
  end
end
```

**Retry Configuration:**
- `retry: true` - Use default 25 retries
- `retry: 10` - Custom retry count
- `retry: false` - No retries
- `retry_for: 3600` - Time-based retry window
- `retry_queue: 'low'` - Different queue for retries

#### Dead Job Queue (Morgue)

```ruby
def send_to_morgue(msg)
  payload = Sidekiq.dump_json(msg)
  now = Time.now.to_f

  redis do |conn|
    conn.multi do |xa|
      xa.zadd("dead", now.to_s, payload)
      # Trim by age (6 months default)
      xa.zremrangebyscore("dead", "-inf", now - @capsule.config[:dead_timeout_in_seconds])
      # Trim by count (10,000 default)
      xa.zremrangebyrank("dead", 0, -@capsule.config[:dead_max_jobs])
    end
  end
end
```

#### Death Handlers

```ruby
# lib/sidekiq/config.rb
def death_handlers
  @options[:death_handlers]
end

# Usage:
Sidekiq.configure_server do |config|
  config.death_handlers << ->(job, ex) do
    # Notify external service
    Bugsnag.notify(ex, job: job)
  end
end
```

### 3.4 Middleware Architecture

**Key File:** `lib/sidekiq/middleware/chain.rb`

```ruby
module Middleware
  class Chain
    include Enumerable

    def add(klass, *args)
      remove(klass)  # Ensure no duplicates
      entries << Entry.new(@config, klass, *args)
    end

    def insert_before(oldklass, newklass, *args)
      i = entries.index { |entry| entry.klass == newklass }
      new_entry = i.nil? ? Entry.new(@config, newklass, *args) : entries.delete_at(i)
      i = entries.index { |entry| entry.klass == oldklass } || 0
      entries.insert(i, new_entry)
    end

    # Execute middleware chain
    def invoke(*args, &block)
      return yield if empty?

      chain = retrieve  # Create fresh instances
      traverse(chain, 0, args, &block)
    end

    private

    def traverse(chain, index, args, &block)
      if index >= chain.size
        yield
      else
        chain[index].call(*args) do
          traverse(chain, index + 1, args, &block)
        end
      end
    end
  end

  class Entry
    def make_new
      x = @klass.new(*@args)
      x.config = @config if @config && x.respond_to?(:config=)
      x
    end
  end
end
```

**Middleware Pattern:**
- Fresh instance per job (no shared state)
- Insert before/after specific middleware
- Both client-side (push) and server-side (process) chains
- `yield` passes control to next middleware

#### Example Middleware

```ruby
# Server middleware
class MyServerHook
  include Sidekiq::ServerMiddleware

  def call(job_instance, msg, queue)
    logger.info "Before job"
    yield  # Run the job
    logger.info "After job"
  end
end

# Client middleware (must return result)
class MyClientHook
  include Sidekiq::ClientMiddleware

  def call(job_class, msg, queue, redis_pool)
    result = yield
    result  # Must return for job to be pushed
  end
end
```

### 3.5 Processor Lifecycle

**Key Files:** `lib/sidekiq/processor.rb`, `lib/sidekiq/manager.rb`

#### Processor Thread

```ruby
class Processor
  def run
    Thread.current[:sidekiq_capsule] = @capsule
    process_one until @done
    @callback.call(self)
  rescue Sidekiq::Shutdown
    @callback.call(self)
  rescue Exception => ex
    @callback.call(self, ex)  # Notify manager
  end

  def process(uow)
    jobstr = uow.job
    queue = uow.queue_name

    ack = false
    Thread.handle_interrupt(IGNORE_SHUTDOWN_INTERRUPTS) do
      Thread.handle_interrupt(ALLOW_SHUTDOWN_INTERRUPTS) do
        dispatch(job_hash, queue, jobstr) do |instance|
          config.server_middleware.invoke(instance, job_hash, queue) do
            execute_job(instance, job_hash["args"])
          end
        end
        ack = true
      rescue Sidekiq::Shutdown
        # Don't ack - job will be requeued
      rescue Sidekiq::JobRetry::Handled
        ack = true  # Retry was scheduled
        raise
      end
    ensure
      uow.acknowledge if ack
    end
  end
end
```

**Key Patterns:**
- `Thread.handle_interrupt` for controlled shutdown
- Acknowledgement only after successful processing
- Manager replaces dead processors

#### Manager Supervision

```ruby
class Manager
  def processor_result(processor, reason = nil)
    @plock.synchronize do
      @workers.delete(processor)
      unless @done
        # Replace the dead processor
        p = Processor.new(@config, &method(:processor_result))
        @workers << p
        p.start
      end
    end
  end

  def hard_shutdown
    cleanup = @workers.dup

    if cleanup.size > 0
      jobs = cleanup.map { |p| p.job }.compact
      # Re-enqueue unfinished jobs
      capsule.fetcher.bulk_requeue(jobs)
    end

    cleanup.each { |processor| processor.kill }
  end
end
```

**Supervision Pattern:**
- Manager monitors processor threads
- Automatic replacement on crash
- Graceful shutdown requeues in-progress jobs
- Hard shutdown force-kills after timeout

### 3.6 Job Fetching

**Key File:** `lib/sidekiq/fetch.rb`

```ruby
class BasicFetch
  TIMEOUT = 2  # Check for shutdown every 2 seconds

  def retrieve_work
    qs = queues_cmd
    queue, job = redis { |conn|
      conn.blocking_call(TIMEOUT, "brpop", *qs, TIMEOUT)
    }
    UnitOfWork.new(queue, job, config) if queue
  end

  def bulk_requeue(inprogress)
    jobs_to_requeue = inprogress.group_by(&:queue)
    redis do |conn|
      conn.pipelined do |pipeline|
        jobs_to_requeue.each do |queue, jobs|
          pipeline.rpush(queue, jobs.map(&:job))
        end
      end
    end
  end
end
```

**Fetching Patterns:**
- `BRPOP` with timeout for responsive shutdown
- Queue priority via weighted shuffle
- Bulk requeue on shutdown

### 3.7 Health Monitoring

**Key File:** `lib/sidekiq/launcher.rb`

```ruby
class Launcher
  RTT_READINGS = RingBuffer.new(5)
  RTT_WARNING_LEVEL = 50_000  # 50ms

  def check_rtt
    a = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
    redis { |x| x.ping }
    b = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
    rtt = b - a

    RTT_READINGS << rtt

    if RTT_READINGS.all? { |x| x > RTT_WARNING_LEVEL }
      logger.warn "Redis network connection performing poorly. RTT: #{RTT_READINGS.buffer.inspect}"
      RTT_READINGS.reset
    end
    rtt
  end

  def heartbeat
    redis do |conn|
      conn.multi { |tx|
        tx.sadd("processes", [key])
        tx.hset(key, "info", to_json, "busy", curstate.size, "beat", Time.now.to_f)
        tx.expire(key, 60)
      }
    end
  rescue => e
    logger.error("heartbeat: #{e}")
  end
end
```

**Health Patterns:**
- RTT monitoring with ring buffer
- Heartbeat every 10 seconds
- Process registration in Redis
- Graceful degradation on Redis errors

---

## Common Patterns Across All Gems

### 1. Error Classification

| Pattern | Redis-rb | Elasticsearch | Sidekiq |
|---------|----------|---------------|---------|
| Base Error | `BaseError` | `Error` | `StandardError` |
| Transient | `BaseConnectionError` | `ServerError` | `Shutdown` |
| Permanent | `CommandError` | `Errors::NotFound` | `JobRetry::Handled` |
| HTTP Status Mapping | N/A | Per-status classes | N/A |

### 2. Connection Health States

All three implement some form of:
- **Alive:** Normal operation
- **Dead/Unhealthy:** Marked after failure
- **Resurrecting:** Attempting recovery

### 3. Retry Strategies

| Gem | Formula | Jitter | Max Retries |
|-----|---------|--------|-------------|
| Redis-rb | Configurable attempts | No | 1 (default) |
| Elasticsearch | Immediate/configurable delay | No | 3 (default) |
| Sidekiq | `count^4 + 15` seconds | Yes (random 10*(count+1)) | 25 (~3 weeks) |

### 4. Thread Safety

- **Redis-rb:** `Monitor` (reentrant mutex)
- **Elasticsearch:** `Mutex` per connection
- **Sidekiq:** `Mutex` for shared state, `Thread.handle_interrupt` for shutdown

### 5. Pool Patterns

- **Redis-rb:** Delegates to `connection_pool`
- **Elasticsearch:** Built-in collection with selectors
- **Sidekiq:** `connection_pool` with per-capsule isolation

---

## Patterns Relevant to Umi

### 1. Tagged Tuples for Results

Sidekiq's retry system implicitly uses something similar:
- Success: Job completes
- Handled Error: `raise JobRetry::Handled`
- Skip: `raise JobRetry::Skip`

Umi could make this explicit:
```ruby
case result
in [:ok, data]
in [:retry, delay]
in [:dead, error]
end
```

### 2. Supervisor-like Patterns

Sidekiq's Manager is essentially a supervisor:
```ruby
def processor_result(processor, reason = nil)
  @workers.delete(processor)
  unless @done
    p = Processor.new(@config, &method(:processor_result))
    @workers << p
    p.start
  end
end
```

This is the "let it crash, restart" philosophy.

### 3. Health State Machine

Elasticsearch's connection health tracking:
```
alive --[failure]--> dead --[timeout]--> resurrectable --[success]--> alive
                                                       --[failure]--> dead (failures++)
```

### 4. Graceful Shutdown

Sidekiq's two-phase shutdown:
1. **Quiet:** Stop accepting new work, finish current
2. **Terminate:** Force-kill after deadline, requeue incomplete

### 5. Middleware as Composition

Sidekiq's middleware chain allows extending behavior without inheritance:
- Logging
- Error handling
- Metrics
- Transactions

### 6. Circuit Breaker (Implicit)

Elasticsearch's dead connection handling is a simple circuit breaker:
- Open: Connection marked dead
- Half-Open: After resurrect timeout
- Closed: Successful request

---

## Recommendations for Umi

1. **Error Hierarchy:** Follow Redis-rb's pattern of separating connection errors (transient) from command errors (permanent).

2. **Health Tracking:** Adopt Elasticsearch's exponential backoff resurrection pattern for external process liveness.

3. **Retry with Jitter:** Use Sidekiq's jitter pattern to prevent thundering herd.

4. **Supervisor Pattern:** The Manager/Processor relationship maps well to Umi's Watcher/Worker model.

5. **Middleware Composition:** Consider a middleware chain for Proctor lifecycle events.

6. **Heartbeat/Health Checks:** Sidekiq's RTT monitoring pattern could apply to Proctor health checking.

7. **Graceful Degradation:** All three gems handle errors without crashing - log, retry, and continue.
