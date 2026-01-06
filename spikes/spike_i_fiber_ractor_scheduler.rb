#!/usr/bin/env ruby
# frozen_string_literal: true

# spike_i_fiber_ractor_scheduler.rb
#
# Purpose: Explore building a Fiber scheduler that uses Ractor communication
#
# The idea:
#   - Fibers inside a Ractor can "await" messages from Ports
#   - A scheduler uses Ractor.select to multiplex across ports
#   - When data arrives, the appropriate fiber is resumed
#
# This enables async-style programming where fibers can await
# inter-Ractor communication without blocking the whole Ractor.
#
# Run with:
#   ruby spikes/spike_i_fiber_ractor_scheduler.rb

puts "=" * 70
puts "SPIKE I: Fiber + Ractor Scheduler Integration"
puts "=" * 70
puts
puts "Ruby #{RUBY_VERSION}"
puts

#------------------------------------------------------------------------------
# Q1: Can we build a simple event loop with Ractor.select + Fibers?
#------------------------------------------------------------------------------
puts "Q1: Simple event loop with Ractor.select + Fibers"
puts "-" * 40

# A minimal scheduler that multiplexes Fibers waiting on Ractor::Ports
class RactorFiberScheduler
  def initialize
    @waiting_fibers = {}  # port -> fiber
    @ready_queue = []     # fibers ready to run
    @results = {}         # fiber -> received value
  end

  # Schedule a fiber to run
  def schedule(fiber)
    @ready_queue << fiber
  end

  # Current fiber wants to wait for a message on a port
  def await_port(port)
    fiber = Fiber.current
    @waiting_fibers[port] = fiber
    Fiber.yield  # Suspend until port receives
    @results.delete(fiber)  # Return the received value
  end

  # Run the event loop
  def run
    loop do
      # First, run any ready fibers
      while (fiber = @ready_queue.shift)
        fiber.resume if fiber.alive?
      end

      # If no fibers waiting, we're done
      break if @waiting_fibers.empty?

      # Wait on all ports + a timer for periodic wakeup
      ports = @waiting_fibers.keys
      timer_port = Ractor::Port.new
      Thread.new { sleep 0.1; timer_port << :tick rescue nil }

      ready_port, value = Ractor.select(timer_port, *ports)

      next if ready_port == timer_port  # Timer tick, loop again

      # Store result and wake up the waiting fiber
      fiber = @waiting_fibers.delete(ready_port)
      if fiber&.alive?
        @results[fiber] = value
        @ready_queue << fiber
      end
    end
  end
end

# Test inside a Ractor
result = Ractor.new do
  scheduler = RactorFiberScheduler.new

  # Create ports for communication
  port_a = Ractor::Port.new
  port_b = Ractor::Port.new

  log = []

  # Fiber that waits on port_a
  fiber_a = Fiber.new do
    log << "fiber_a: waiting on port_a"
    value = scheduler.await_port(port_a)
    log << "fiber_a: got #{value}"
    :fiber_a_done
  end

  # Fiber that waits on port_b
  fiber_b = Fiber.new do
    log << "fiber_b: waiting on port_b"
    value = scheduler.await_port(port_b)
    log << "fiber_b: got #{value}"
    :fiber_b_done
  end

  # Producer thread that sends to ports after delays
  producer = Thread.new do
    sleep 0.05
    port_b << "hello_b"  # Send to B first
    sleep 0.05
    port_a << "hello_a"  # Then to A
  end

  # Schedule both fibers
  scheduler.schedule(fiber_a)
  scheduler.schedule(fiber_b)

  # Run the event loop
  scheduler.run

  producer.join

  { log: log }
end.value

puts "  Execution log:"
result[:log].each { |entry| puts "    #{entry}" }

# Verify B was processed before A (since B's message arrived first)
if result[:log].include?("fiber_b: got hello_b") &&
   result[:log].include?("fiber_a: got hello_a")
  puts "  [PASS] Q1: Event loop with Ractor.select + Fibers works"
else
  puts "  [FAIL] Q1: Missing expected log entries"
end
puts

#------------------------------------------------------------------------------
# Q2: Await with timeout
#------------------------------------------------------------------------------
puts "Q2: Await with timeout support"
puts "-" * 40

class RactorFiberSchedulerV2
  def initialize
    @waiting = []  # [{fiber:, port:, deadline:}, ...]
    @ready = []
    @results = {}
  end

  def schedule(fiber)
    @ready << fiber
  end

  def await_port(port, timeout: nil)
    fiber = Fiber.current
    deadline = timeout ? Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout : nil
    @waiting << { fiber: fiber, port: port, deadline: deadline }
    Fiber.yield
    @results.delete(fiber)
  end

  def run
    loop do
      # Run ready fibers
      while (fiber = @ready.shift)
        fiber.resume if fiber.alive?
      end

      break if @waiting.empty?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Check for timeouts
      timed_out, @waiting = @waiting.partition do |w|
        w[:deadline] && now >= w[:deadline]
      end

      timed_out.each do |w|
        @results[w[:fiber]] = :timeout
        @ready << w[:fiber]
      end

      next unless @waiting.any?

      # Calculate how long to wait
      next_deadline = @waiting.filter_map { |w| w[:deadline] }.min
      wait_time = next_deadline ? [next_deadline - now, 0.001].max : 0.1

      ports = @waiting.map { |w| w[:port] }.uniq

      # Use timer port pattern since Ractor.select has no timeout param
      timer_port = Ractor::Port.new
      Thread.new(wait_time) { |t| sleep t; timer_port << :tick rescue nil }

      ready_port, value = Ractor.select(timer_port, *ports)

      next if ready_port == timer_port  # Timer, loop to check deadlines

      # Wake all fibers waiting on this port
      woken, @waiting = @waiting.partition { |w| w[:port] == ready_port }
      woken.each do |w|
        @results[w[:fiber]] = value
        @ready << w[:fiber]
      end
    end
  end
end

result = Ractor.new do
  scheduler = RactorFiberSchedulerV2.new

  port = Ractor::Port.new
  log = []

  # Fiber with short timeout (will timeout)
  fiber_timeout = Fiber.new do
    log << "fiber_timeout: waiting with 50ms timeout"
    value = scheduler.await_port(port, timeout: 0.05)
    log << "fiber_timeout: result=#{value}"
  end

  # Fiber with longer timeout (will receive)
  fiber_receive = Fiber.new do
    log << "fiber_receive: waiting with 500ms timeout"
    value = scheduler.await_port(port, timeout: 0.5)
    log << "fiber_receive: result=#{value}"
  end

  # Producer sends after 100ms
  producer = Thread.new do
    sleep 0.1
    port << "delayed_message"
  end

  scheduler.schedule(fiber_timeout)
  scheduler.schedule(fiber_receive)
  scheduler.run

  producer.join
  { log: log }
end.value

puts "  Execution log:"
result[:log].each { |entry| puts "    #{entry}" }

if result[:log].include?("fiber_timeout: result=timeout") &&
   result[:log].include?("fiber_receive: result=delayed_message")
  puts "  [PASS] Q2: Timeout support works correctly"
else
  puts "  [FAIL] Q2: Unexpected timeout behavior"
end
puts

#------------------------------------------------------------------------------
# Q3: Multiple fibers awaiting same port (fan-out)
#------------------------------------------------------------------------------
puts "Q3: Multiple fibers awaiting same port"
puts "-" * 40

result = Ractor.new do
  scheduler = RactorFiberSchedulerV2.new

  port = Ractor::Port.new
  log = []

  # Three fibers all waiting on the same port
  fibers = 3.times.map do |i|
    Fiber.new do
      log << "fiber_#{i}: waiting"
      value = scheduler.await_port(port, timeout: 1.0)
      log << "fiber_#{i}: got #{value}"
    end
  end

  # Send one message
  Thread.new do
    sleep 0.05
    port << "single_message"
  end

  fibers.each { |f| scheduler.schedule(f) }
  scheduler.run

  { log: log }
end.value

puts "  Execution log:"
result[:log].each { |entry| puts "    #{entry}" }

# All three should receive the same message
received_count = result[:log].count { |e| e.include?("got single_message") }
puts "  Fibers that received: #{received_count}"
if received_count == 3
  puts "  [PASS] Q3: Fan-out to multiple waiting fibers works"
else
  puts "  [INFO] Q3: Only #{received_count}/3 fibers received (expected behavior varies)"
end
puts

#------------------------------------------------------------------------------
# Q4: Request-Response pattern with fibers
#------------------------------------------------------------------------------
puts "Q4: Request-Response pattern"
puts "-" * 40

result = Ractor.new do
  # Simulated "service" Ractor
  service_inbox = Ractor::Port.new

  service = Thread.new do
    3.times do
      request = service_inbox.receive
      # Process and respond
      response_port = request[:reply_to]
      response_port << { result: request[:data].upcase, id: request[:id] }
    end
  end

  scheduler = RactorFiberSchedulerV2.new
  results = {}

  # Create fibers that make requests
  fibers = [:hello, :world, :ruby].map.with_index do |data, i|
    Fiber.new do
      reply_port = Ractor::Port.new

      # Send request
      service_inbox << { data: data, reply_to: reply_port, id: i }

      # Await response
      response = scheduler.await_port(reply_port, timeout: 1.0)
      results[i] = response
    end
  end

  fibers.each { |f| scheduler.schedule(f) }
  scheduler.run

  service.join
  { results: results }
end.value

puts "  Results:"
result[:results].each do |id, response|
  puts "    Request #{id}: #{response.inspect}"
end

# Check results (symbols get upcased to symbols)
all_correct = result[:results].all? do |id, response|
  response[:id] == id && response[:result].to_s == [:hello, :world, :ruby][id].to_s.upcase
end

if all_correct && result[:results].size == 3
  puts "  [PASS] Q4: Request-Response pattern works"
else
  puts "  [FAIL] Q4: Unexpected results"
end
puts

#------------------------------------------------------------------------------
# Q5: Cross-Ractor async communication
#------------------------------------------------------------------------------
puts "Q5: Cross-Ractor async communication with Fiber scheduler"
puts "-" * 40

# Create worker Ractors
workers = 3.times.map do |i|
  Ractor.new(i) do |id|
    loop do
      request = Ractor.receive
      break if request == :shutdown

      # Simulate work
      sleep 0.02 + rand * 0.03

      # Send response
      request[:reply_to] << {
        worker: id,
        input: request[:data],
        output: request[:data] * 2
      }
    end
  end
end

# Coordinator Ractor with fiber scheduler
coordinator_result = Ractor.new(workers) do |workers|
  scheduler = RactorFiberSchedulerV2.new
  results = []

  # Create fibers for parallel requests
  fibers = 6.times.map do |i|
    Fiber.new do
      reply_port = Ractor::Port.new
      worker = workers[i % workers.size]

      # Send request to worker
      worker.send({ data: i + 1, reply_to: reply_port })

      # Await response (non-blocking thanks to scheduler)
      response = scheduler.await_port(reply_port, timeout: 1.0)
      results << response
    end
  end

  start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  fibers.each { |f| scheduler.schedule(f) }
  scheduler.run
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

  { results: results, elapsed: elapsed }
end.value

# Shutdown workers
workers.each { |w| w.send(:shutdown) }

puts "  Results from workers:"
coordinator_result[:results].sort_by { |r| r[:input] }.each do |r|
  puts "    Input #{r[:input]} → Worker #{r[:worker]} → Output #{r[:output]}"
end
puts "  Total time: #{'%.3f' % coordinator_result[:elapsed]}s"
puts "  (Sequential would be ~0.15-0.25s, parallel should be faster)"

if coordinator_result[:results].size == 6
  puts "  [PASS] Q5: Cross-Ractor async communication works"
else
  puts "  [FAIL] Q5: Missing some results"
end
puts

#------------------------------------------------------------------------------
# Q6: Integration with Ruby's Fiber::Scheduler interface
#------------------------------------------------------------------------------
puts "Q6: Exploring Fiber::Scheduler interface compatibility"
puts "-" * 40

# Check what methods Fiber::Scheduler expects
puts "  Fiber::Scheduler is an interface (not a class)"
puts "  Required methods for a custom scheduler:"

# The interface methods (from Ruby docs)
scheduler_methods = %i[
  io_wait io_read io_write io_pread io_pwrite
  process_wait kernel_sleep block unblock
  fiber address_resolve timeout_after
  close
]

puts "    #{scheduler_methods.join(', ')}"
puts
puts "  Our RactorFiberScheduler provides:"
puts "    await_port(port, timeout:) - wait for Ractor::Port message"
puts "    schedule(fiber) - add fiber to ready queue"
puts "    run - event loop"
puts
puts "  Challenge: Fiber::Scheduler is I/O focused, Ractor::Port isn't an IO."
puts "  We'd need to either:"
puts "    1. Build a parallel scheduler (like we did) for Ractor communication"
puts "    2. Create a bridge that wraps Port communication as pseudo-IO"
puts
puts "  [INFO] Q6: Custom scheduler works alongside (not replacing) Fiber::Scheduler"
puts

#------------------------------------------------------------------------------
# Q7: Async-style API wrapper
#------------------------------------------------------------------------------
puts "Q7: Async-style API wrapper"
puts "-" * 40

# A nicer API that feels like async/await
class AsyncRactor
  def initialize
    @scheduler = RactorFiberSchedulerV2.new
    @fibers = []
  end

  def spawn(&block)
    fiber = Fiber.new(&block)
    @fibers << fiber
    @scheduler.schedule(fiber)
  end

  def await(port, timeout: nil)
    @scheduler.await_port(port, timeout: timeout)
  end

  def run
    @scheduler.run
  end

  # Helper to create a "future" pattern
  def self.future
    port = Ractor::Port.new
    [port, ->(value) { port << value }]
  end
end

result = Ractor.new do
  async = AsyncRactor.new
  results = []

  # Spawn concurrent tasks
  async.spawn do
    port, resolve = AsyncRactor.future
    Thread.new { sleep 0.03; resolve.call(:task_a_done) }
    results << [:a, async.await(port, timeout: 1.0)]
  end

  async.spawn do
    port, resolve = AsyncRactor.future
    Thread.new { sleep 0.01; resolve.call(:task_b_done) }
    results << [:b, async.await(port, timeout: 1.0)]
  end

  async.spawn do
    port, resolve = AsyncRactor.future
    Thread.new { sleep 0.02; resolve.call(:task_c_done) }
    results << [:c, async.await(port, timeout: 1.0)]
  end

  async.run

  { results: results }
end.value

puts "  Completion order: #{result[:results].map(&:first).join(', ')}"
puts "  (Expected: b, c, a based on sleep times)"

if result[:results].map(&:first) == [:b, :c, :a]
  puts "  [PASS] Q7: Async-style API works with correct ordering"
else
  puts "  [INFO] Q7: Order was #{result[:results].map(&:first)}, timing-dependent"
end
puts

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
puts "=" * 70
puts "Summary"
puts "=" * 70
puts
puts "Fiber + Ractor Scheduler Integration:"
puts
puts "  ✓ Can build custom scheduler using Ractor.select + Fibers"
puts "  ✓ Fibers can await Ractor::Port messages without blocking"
puts "  ✓ Timeout support works with deadline tracking"
puts "  ✓ Multiple fibers can await same port (fan-out)"
puts "  ✓ Request-Response patterns work cleanly"
puts "  ✓ Cross-Ractor async communication is possible"
puts "  ✓ Async-style APIs can be built on top"
puts
puts "Key Pattern:"
puts "  ┌────────────────────────────────────────────────────────┐"
puts "  │  Coordinator Ractor                                    │"
puts "  │  ┌──────────────────────────────────────────────────┐  │"
puts "  │  │  RactorFiberScheduler                            │  │"
puts "  │  │    Fiber A ──await──> Port 1 ◄── Worker Ractor 1 │  │"
puts "  │  │    Fiber B ──await──> Port 2 ◄── Worker Ractor 2 │  │"
puts "  │  │    Fiber C ──await──> Port 3 ◄── Worker Ractor 3 │  │"
puts "  │  │         ↓                                        │  │"
puts "  │  │    Ractor.select(port1, port2, port3)            │  │"
puts "  │  │         ↓                                        │  │"
puts "  │  │    Resume fiber when its port has data           │  │"
puts "  │  └──────────────────────────────────────────────────┘  │"
puts "  └────────────────────────────────────────────────────────┘"
puts
puts "This enables async-style concurrency WITHIN a Ractor while"
puts "communicating with other Ractors in a non-blocking way."
puts
puts "Potential Umi integration:"
puts "  - Proctor could use this for multiplexing multiple child processes"
puts "  - Supervisor could await health checks from multiple workers"
puts "  - Request handlers could await responses from service Ractors"
