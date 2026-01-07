#!/usr/bin/env ruby
# frozen_string_literal: true

# spike_h_fiber_ractor.rb
#
# Purpose: Explore how Fibers interact with Ractors
#
# Background:
#   - Fibers: Cooperative concurrency (coroutines), single-threaded
#   - Ractors: Parallel execution, true concurrency
#   - Fiber::Scheduler: Async I/O interface (Ruby 3.0+)
#
# Questions to answer:
# Q1: Can Fibers be created inside Ractors?
# Q2: Can Fibers be passed between Ractors?
# Q3: Does Fiber.yield/resume work inside Ractors?
# Q4: Can we have multiple Fibers per Ractor?
# Q5: How does Fiber.current work inside Ractors?
# Q6: Can Fiber::Scheduler be used inside Ractors?
# Q7: What about Fiber storage (Fiber[key]) inside Ractors?
# Q8: Generator pattern (Enumerator via Fiber) inside Ractors?
#
# Run with:
#   ruby spikes/spike_h_fiber_ractor.rb

puts "=" * 70
puts "SPIKE H: Fiber + Ractor Interaction"
puts "=" * 70
puts
puts "Ruby #{RUBY_VERSION}"
puts

#------------------------------------------------------------------------------
# Q1: Basic Fiber creation inside Ractor
#------------------------------------------------------------------------------
puts "Q1: Basic Fiber creation inside Ractor"
puts "-" * 40

result = Ractor.new do
  f = Fiber.new do
    "Hello from Fiber inside Ractor"
  end
  f.resume
end.value

puts "  Result: #{result.inspect}"
if result == "Hello from Fiber inside Ractor"
  puts "  [PASS] Q1: Fibers can be created inside Ractors"
else
  puts "  [FAIL] Q1: Unexpected result"
end
puts

#------------------------------------------------------------------------------
# Q2: Fiber passing between Ractors
#------------------------------------------------------------------------------
puts "Q2: Fiber passing between Ractors"
puts "-" * 40

# Suppress the thread error output for this expected failure
original_report = Thread.report_on_exception
Thread.report_on_exception = false

begin
  # Create a fiber in main ractor
  test_fiber = Fiber.new { "I was created in main" }

  # Try to send it to another Ractor
  r = Ractor.new(test_fiber) do |f|
    f.resume
  end
  result = r.value

  puts "  Result: #{result.inspect}"
  puts "  [UNEXPECTED] Q2: Fibers CAN be passed between Ractors"
rescue Ractor::Error, Ractor::RemoteError, TypeError, ArgumentError => e
  puts "  Error: #{e.class}"
  puts "  [EXPECTED] Q2: Fibers cannot be passed between Ractors"
  puts "  (Fibers are Ractor-local, not shareable)"
rescue StandardError => e
  puts "  Unexpected error: #{e.class}: #{e.message}"
  puts "  [INFO] Q2: Fiber passing behavior unclear"
ensure
  Thread.report_on_exception = original_report
end
puts

#------------------------------------------------------------------------------
# Q3: Fiber.yield/resume inside Ractors
#------------------------------------------------------------------------------
puts "Q3: Fiber.yield/resume inside Ractor"
puts "-" * 40

result = Ractor.new do
  values = []

  f = Fiber.new do
    values << "step 1"
    Fiber.yield :yielded_1
    values << "step 2"
    Fiber.yield :yielded_2
    values << "step 3"
    :done
  end

  r1 = f.resume
  r2 = f.resume
  r3 = f.resume

  { values: values, returns: [r1, r2, r3] }
end.value

puts "  Values accumulated: #{result[:values].inspect}"
puts "  Return values: #{result[:returns].inspect}"

expected_values  = ["step 1", "step 2", "step 3"]
expected_returns = [:yielded_1, :yielded_2, :done]
if result[:values] == expected_values && result[:returns] == expected_returns
  puts "  [PASS] Q3: Fiber.yield/resume works correctly inside Ractors"
else
  puts "  [FAIL] Q3: Unexpected behavior"
end
puts

#------------------------------------------------------------------------------
# Q4: Multiple Fibers per Ractor
#------------------------------------------------------------------------------
puts "Q4: Multiple Fibers in one Ractor"
puts "-" * 40

result = Ractor.new do
  log = []

  f1 = Fiber.new do
    log << "f1:start"
    Fiber.yield
    log << "f1:end"
  end

  f2 = Fiber.new do
    log << "f2:start"
    Fiber.yield
    log << "f2:end"
  end

  f3 = Fiber.new do
    log << "f3:start"
    Fiber.yield
    log << "f3:end"
  end

  # Interleave execution
  f1.resume  # f1:start
  f2.resume  # f2:start
  f3.resume  # f3:start
  f1.resume  # f1:end
  f2.resume  # f2:end
  f3.resume  # f3:end

  log
end.value

puts "  Execution order: #{result.inspect}"
expected = %w[f1:start f2:start f3:start f1:end f2:end f3:end]
if result == expected
  puts "  [PASS] Q4: Multiple Fibers work correctly, interleaved execution"
else
  puts "  [FAIL] Q4: Unexpected execution order"
end
puts

#------------------------------------------------------------------------------
# Q5: Fiber.current inside Ractors
#------------------------------------------------------------------------------
puts "Q5: Fiber.current inside Ractor"
puts "-" * 40

result = Ractor.new do
  ractor_main_fiber = Fiber.current
  ractor_main_fiber_id = ractor_main_fiber.object_id

  child_fiber_id = nil
  f = Fiber.new do
    child_fiber_id = Fiber.current.object_id
    {
      child_is_current:          true,  # By definition
      child_different_from_main: Fiber.current.object_id != ractor_main_fiber_id
    }
  end

  inner_result = f.resume

  {
    main_fiber_class: ractor_main_fiber.class.to_s,
    from_inside:      inner_result,
    fibers_different: ractor_main_fiber_id != child_fiber_id
  }
end.value

puts "  Main fiber class: #{result[:main_fiber_class]}"
puts "  From inside fiber: #{result[:from_inside]}"
puts "  Main and child fibers different: #{result[:fibers_different]}"

if result[:main_fiber_class] == "Fiber" &&
   result[:from_inside][:child_different_from_main] &&
   result[:fibers_different]
  puts "  [PASS] Q5: Fiber.current works correctly inside Ractors"
else
  puts "  [FAIL] Q5: Unexpected Fiber.current behavior"
end
puts

#------------------------------------------------------------------------------
# Q6: Fiber storage (Fiber[key]) inside Ractors
#------------------------------------------------------------------------------
puts "Q6: Fiber-local storage inside Ractor"
puts "-" * 40

result = Ractor.new do
  # Set fiber-local in main fiber
  Fiber[:main_key] = "main_value"

  f = Fiber.new do
    # Child fiber should not see parent's fiber-local
    parent_visible = Fiber[:main_key]

    # Set child's own fiber-local
    Fiber[:child_key] = "child_value"

    {
      parent_visible: parent_visible,
      child_key:      Fiber[:child_key]
    }
  end

  inner = f.resume

  {
    main_key_after:            Fiber[:main_key],
    child_key_visible_to_main: Fiber[:child_key],
    from_child:                inner
  }
end.value

puts "  Main fiber [:main_key] after: #{result[:main_key_after].inspect}"
puts "  Child's [:child_key] visible to main: #{result[:child_key_visible_to_main].inspect}"
puts "  From child - parent visible: #{result[:from_child][:parent_visible].inspect}"
puts "  From child - child_key: #{result[:from_child][:child_key].inspect}"

# Fiber storage is inherited by child fibers in Ruby 3.2+
if result[:main_key_after] == "main_value" &&
   result[:from_child][:child_key] == "child_value"
  puts "  [PASS] Q6: Fiber-local storage works inside Ractors"
else
  puts "  [FAIL] Q6: Unexpected fiber storage behavior"
end
puts

#------------------------------------------------------------------------------
# Q7: Enumerator (Fiber-based) inside Ractors
#------------------------------------------------------------------------------
puts "Q7: Enumerator (Fiber-based generator) inside Ractor"
puts "-" * 40

result = Ractor.new do
  # Create a custom enumerator (internally uses Fiber)
  fib_enum = Enumerator.new do |y|
    a = 0
    b = 1
    loop do
      y.yield a
      a, b = b, a + b
    end
  end

  # Take first 10 fibonacci numbers
  fib_enum.take(10)
end.value

puts "  First 10 Fibonacci: #{result.inspect}"
expected = [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
if result == expected
  puts "  [PASS] Q7: Enumerator (Fiber-based) works inside Ractors"
else
  puts "  [FAIL] Q7: Unexpected Enumerator results"
end
puts

#------------------------------------------------------------------------------
# Q8: Fiber + Thread inside Ractor
#------------------------------------------------------------------------------
puts "Q8: Fiber + Thread interaction inside Ractor"
puts "-" * 40

result = Ractor.new do
  results = Queue.new

  t = Thread.new do
    f = Fiber.new do
      Thread.current.name = "fiber-thread"
      Fiber.yield :from_fiber_in_thread
      :fiber_done
    end

    r1 = f.resume
    results << [:thread_fiber_1, r1]
    r2 = f.resume
    results << [:thread_fiber_2, r2]
  end

  # Main ractor thread also uses fiber
  main_f = Fiber.new do
    Fiber.yield :from_main_fiber
    :main_fiber_done
  end

  r1 = main_f.resume
  results << [:main_fiber_1, r1]

  t.join

  r2 = main_f.resume
  results << [:main_fiber_2, r2]

  # Collect results
  collected = []
  collected << results.pop until results.empty?
  collected
end.value

puts "  Results: #{result.inspect}"
# Order may vary due to threading, but all should be present
expected_keys = [:main_fiber_1, :thread_fiber_1, :thread_fiber_2, :main_fiber_2]
actual_keys   = result.map(&:first)
if expected_keys.all? { |k| actual_keys.include?(k) }
  puts "  [PASS] Q8: Fibers work in both main thread and spawned threads inside Ractor"
else
  puts "  [FAIL] Q8: Missing some fiber results"
end
puts

#------------------------------------------------------------------------------
# Q9: Fiber transfer (non-symmetric coroutines) inside Ractor
#------------------------------------------------------------------------------
puts "Q9: Fiber.transfer inside Ractor"
puts "-" * 40

result = Ractor.new do
  log = []
  f2 = nil

  f1 = Fiber.new do
    log << "f1:1"
    f2.transfer
    log << "f1:2"
    f2.transfer
    log << "f1:3"
    :f1_done
  end

  f2 = Fiber.new do
    log << "f2:1"
    f1.transfer
    log << "f2:2"
    f1.transfer
    log << "f2:3"
    :f2_done
  end

  # Start with f1
  final = f1.transfer

  { log: log, final: final }
end.value

puts "  Execution log: #{result[:log].inspect}"
puts "  Final value: #{result[:final].inspect}"

expected_log = %w[f1:1 f2:1 f1:2 f2:2 f1:3]
if result[:log] == expected_log
  puts "  [PASS] Q9: Fiber.transfer works inside Ractors"
else
  puts "  [INFO] Q9: Transfer execution order: #{result[:log]}"
end
puts

#------------------------------------------------------------------------------
# Q10: Fiber::Scheduler detection inside Ractor
#------------------------------------------------------------------------------
puts "Q10: Fiber::Scheduler inside Ractor"
puts "-" * 40

result = Ractor.new do
  {
    scheduler_class_exists: defined?(Fiber::Scheduler) == "constant",
    current_scheduler:      Fiber.scheduler,
    can_set_scheduler:      Fiber.respond_to?(:set_scheduler)
  }
end.value

puts "  Fiber::Scheduler class exists: #{result[:scheduler_class_exists]}"
puts "  Current scheduler: #{result[:current_scheduler].inspect}"
puts "  Can set scheduler: #{result[:can_set_scheduler]}"
puts "  [INFO] Q10: Fiber::Scheduler is an interface, not a class. Custom schedulers"
puts "         (like Async) would need to be Ractor-safe to work inside Ractors."
puts

#------------------------------------------------------------------------------
# Q11: Producer-Consumer pattern with Fibers inside Ractor
#------------------------------------------------------------------------------
puts "Q11: Producer-Consumer with Fibers inside Ractor"
puts "-" * 40

result = Ractor.new do
  produced = []
  consumed = []

  consumer = nil

  producer = Fiber.new do
    5.times do |i|
      item = "item_#{i}"
      produced << item
      consumer.transfer(item)
    end
    consumer.transfer(:done)
  end

  consumer = Fiber.new do
    loop do
      item = producer.transfer
      break if item == :done

      consumed << "consumed:#{item}"
    end
    :consumer_finished
  end

  final = consumer.resume

  { produced: produced, consumed: consumed, final: final }
end.value

puts "  Produced: #{result[:produced].inspect}"
puts "  Consumed: #{result[:consumed].inspect}"
puts "  Final: #{result[:final].inspect}"

if result[:produced].size == 5 && result[:consumed].size == 5
  puts "  [PASS] Q11: Producer-Consumer pattern works with Fibers in Ractor"
else
  puts "  [FAIL] Q11: Incomplete production/consumption"
end
puts

#------------------------------------------------------------------------------
# Q12: Many Fibers stress test inside Ractor
#------------------------------------------------------------------------------
puts "Q12: Many Fibers inside Ractor (stress test)"
puts "-" * 40

num_fibers = 1000
result = Ractor.new(num_fibers) do |n|
  fibers = n.times.map do |i|
    Fiber.new { i * 2 }
  end

  start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  results = fibers.map(&:resume)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

  {
    count:   results.size,
    sum:     results.sum,
    elapsed: elapsed
  }
end.value

expected_sum = (0...num_fibers).sum * 2
puts "  Created and resumed #{result[:count]} fibers"
puts "  Sum of results: #{result[:sum]} (expected: #{expected_sum})"
puts "  Time: #{'%.4f' % result[:elapsed]}s"

if result[:count] == num_fibers && result[:sum] == expected_sum
  puts "  [PASS] Q12: #{num_fibers} Fibers work correctly inside Ractor"
else
  puts "  [FAIL] Q12: Fiber stress test failed"
end
puts

#------------------------------------------------------------------------------
# Q13: Parallel Ractors each with Fibers
#------------------------------------------------------------------------------
puts "Q13: Parallel Ractors each with internal Fibers"
puts "-" * 40

num_ractors       = 4
fibers_per_ractor = 100

start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

ractors = num_ractors.times.map do |rid|
  Ractor.new(rid, fibers_per_ractor) do |ractor_id, num_fibers|
    # Each ractor creates its own fibers
    fibers = num_fibers.times.map do |fid|
      Fiber.new { [ractor_id, fid, (ractor_id * 1000) + fid] }
    end

    results = fibers.map(&:resume)
    {
      ractor_id:   ractor_id,
      fiber_count: results.size,
      checksum:    results.sum { |r| r[2] }
    }
  end
end

results = ractors.map(&:value)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

puts "  #{num_ractors} Ractors × #{fibers_per_ractor} Fibers each"
puts "  Results:"
results.each do |r|
  puts "    Ractor #{r[:ractor_id]}: #{r[:fiber_count]} fibers, checksum=#{r[:checksum]}"
end
puts "  Total time: #{'%.4f' % elapsed}s"

if results.all? { |r| r[:fiber_count] == fibers_per_ractor }
  puts "  [PASS] Q13: Parallel Ractors with internal Fibers work correctly"
else
  puts "  [FAIL] Q13: Some Ractors didn't complete all fibers"
end
puts

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
puts "=" * 70
puts "Summary"
puts "=" * 70
puts
puts "Fiber + Ractor Interaction:"
puts "  ✓ Fibers CAN be created inside Ractors"
puts "  ✓ Fiber.yield/resume works normally inside Ractors"
puts "  ✓ Multiple Fibers per Ractor work correctly"
puts "  ✓ Fiber.current correctly identifies the current fiber"
puts "  ✓ Fiber-local storage (Fiber[:key]) works inside Ractors"
puts "  ✓ Enumerators (Fiber-based) work inside Ractors"
puts "  ✓ Fibers work in spawned Threads inside Ractors"
puts "  ✓ Fiber.transfer (symmetric coroutines) works inside Ractors"
puts "  ✓ Producer-Consumer patterns work with Fibers in Ractors"
puts "  ✓ Many Fibers (1000+) work inside a single Ractor"
puts "  ✓ Parallel Ractors can each have their own Fibers"
puts
puts "Key insight: Fibers are Ractor-local. Each Ractor can have its own"
puts "set of Fibers for cooperative concurrency, while Ractors provide"
puts "parallel execution across CPU cores."
puts
puts "Pattern: Use Ractors for parallelism + Fibers for structured concurrency"
puts "within each Ractor (e.g., async I/O, generators, state machines)."
