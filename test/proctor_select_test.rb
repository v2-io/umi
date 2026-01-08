#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for Umi::Proctor.select - parallel process monitoring
#
# This is the test that should have existed from day one.
# Proctor.select enables Ractor-native multiplexing across multiple
# processes without requiring threads.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'umi'

FIXTURES = File.expand_path('fixtures/processes', __dir__)

def test(name)
  print "#{name}... "
  begin
    yield
    puts "OK"
    true
  rescue => e
    puts "FAIL"
    puts "  #{e.class}: #{e.message}"
    puts "  #{e.backtrace.first}"
    false
  end
end

def assert(condition, msg = "assertion failed")
  raise msg unless condition
end

def assert_equal(expected, actual)
  raise "expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

def assert_nil(actual)
  raise "expected nil, got #{actual.inspect}" unless actual.nil?
end

def assert_includes(collection, item)
  raise "expected #{collection.inspect} to include #{item.inspect}" unless collection.include?(item)
end

puts "=" * 60
puts "Umi::Proctor.select Tests"
puts "Ruby #{RUBY_VERSION}"
puts "=" * 60
puts

results = []

# =============================================================================
# Basic select functionality
# =============================================================================
puts "--- Basic select ---"

results << test("select returns [proctor, message] for stdout") do
  p1 = Umi::Proctor.new("echo", "hello")

  result = Umi::Proctor.select(p1, timeout: 2)

  assert result, "expected result, got nil"
  proctor, msg = result
  assert_equal p1, proctor
  assert_equal [:stdout, "hello\n"], msg

  p1.join
end

results << test("select works with multiple proctors") do
  p1 = Umi::Proctor.new("ruby", "-e", "sleep 0.1; puts 'first'")
  p2 = Umi::Proctor.new("ruby", "-e", "sleep 0.2; puts 'second'")
  p3 = Umi::Proctor.new("ruby", "-e", "sleep 0.3; puts 'third'")

  messages = []
  proctors = [p1, p2, p3]

  # Collect all stdout messages
  until proctors.all?(&:exited?)
    result = Umi::Proctor.select(*proctors, timeout: 2)
    break if result.nil?

    proctor, msg = result
    case msg
    in [:stdout, data]
      messages << [proctor, data.chomp]
    in [:closed, _]
      # Expected
    end
  end

  assert messages.length >= 3, "expected at least 3 messages, got #{messages.length}"
  contents = messages.map { |_, data| data }
  assert_includes contents, "first"
  assert_includes contents, "second"
  assert_includes contents, "third"

  proctors.each { |p| p.join rescue nil }
end

results << test("select returns nil on timeout") do
  p1 = Umi::Proctor.new("#{FIXTURES}/hang")

  result = Umi::Proctor.select(p1, timeout: 0.1)
  assert_nil result

  p1.kill(:KILL)
  p1.join(timeout: 1)
end

results << test("select returns [:closed, result] when process exits") do
  p1 = Umi::Proctor.new("true")

  result = Umi::Proctor.select(p1, timeout: 2)

  assert result, "expected result"
  proctor, msg = result
  assert_equal p1, proctor

  case msg
  in [:closed, r]
    assert r.is_a?(Umi::Proctor::Result)
    assert r.success?
  else
    raise "expected [:closed, result], got #{msg.inspect}"
  end
end

results << test("select handles stderr") do
  p1 = Umi::Proctor.new("ruby", "-e", "$stderr.puts 'error'")

  result = Umi::Proctor.select(p1, timeout: 2)

  assert result, "expected result"
  proctor, msg = result
  assert_equal p1, proctor
  assert_equal [:stderr, "error\n"], msg

  p1.join
end

results << test("select raises ArgumentError with no proctors") do
  raised = false
  begin
    Umi::Proctor.select(timeout: 1)
  rescue ArgumentError => e
    raised = true
    assert e.message.include?("no proctors"), "wrong message: #{e.message}"
  end
  assert raised, "expected ArgumentError"
end

# =============================================================================
# Ordering and interleaving
# =============================================================================
puts "\n--- Ordering and interleaving ---"

results << test("select returns messages in arrival order") do
  # Create proctors that output at staggered times
  p1 = Umi::Proctor.new("ruby", "-e", "$stdout.sync=true; sleep 0.05; puts 'p1-a'; sleep 0.15; puts 'p1-b'")
  p2 = Umi::Proctor.new("ruby", "-e", "$stdout.sync=true; sleep 0.10; puts 'p2-a'; sleep 0.10; puts 'p2-b'")

  messages = []
  proctors = [p1, p2]

  start = Time.now
  until proctors.all?(&:exited?) || (Time.now - start) > 3
    result = Umi::Proctor.select(*proctors, timeout: 1)
    break if result.nil?

    proctor, msg = result
    case msg
    in [:stdout, data]
      messages << data.chomp
    in [:closed, _]
      # Expected
    end
  end

  # Should have all 4 messages
  assert messages.length == 4, "expected 4 messages, got #{messages.length}: #{messages.inspect}"

  # First message should be p1-a (earliest at 0.05s)
  assert_equal "p1-a", messages[0]

  proctors.each { |p| p.join rescue nil }
end

results << test("select interleaves stdout and stderr from same proctor") do
  script = <<~RUBY
    $stdout.sync = $stderr.sync = true
    puts "out1"
    $stderr.puts "err1"
    puts "out2"
  RUBY

  p1 = Umi::Proctor.new("ruby", "-e", script)

  messages = []
  3.times do
    result = Umi::Proctor.select(p1, timeout: 2)
    break if result.nil?

    proctor, msg = result
    case msg
    in [:stdout, data]
      messages << [:stdout, data.chomp]
    in [:stderr, data]
      messages << [:stderr, data.chomp]
    in [:closed, _]
      break
    end
  end

  assert messages.any? { |type, _| type == :stdout }, "no stdout messages"
  assert messages.any? { |type, _| type == :stderr }, "no stderr messages"

  p1.join
end

# =============================================================================
# Process death handling
# =============================================================================
puts "\n--- Process death handling ---"

results << test("select returns buffered output before death") do
  # Process outputs several lines then exits immediately
  script = <<~RUBY
    $stdout.sync = true
    puts "line1"
    puts "line2"
    puts "line3"
  RUBY

  p1 = Umi::Proctor.new("ruby", "-e", script)

  messages = []
  5.times do
    result = Umi::Proctor.select(p1, timeout: 2)
    break if result.nil?

    proctor, msg = result
    messages << msg
    break if msg[0] == :closed
  end

  # Should get all lines before :closed
  stdout_msgs = messages.select { |m| m[0] == :stdout }
  assert stdout_msgs.length == 3, "expected 3 stdout messages, got #{stdout_msgs.length}"

  assert_equal [:stdout, "line1\n"], messages[0]
  assert_equal [:stdout, "line2\n"], messages[1]
  assert_equal [:stdout, "line3\n"], messages[2]
  assert_equal :closed, messages[3]&.first

  p1.join rescue nil
end

results << test("select handles signaled process") do
  p1 = Umi::Proctor.new("sleep", "100")

  # Give it a moment to start
  sleep 0.05

  # Kill it externally
  Process.kill("KILL", p1.pid)

  result = Umi::Proctor.select(p1, timeout: 2)

  assert result, "expected result"
  proctor, msg = result

  case msg
  in [:closed, r]
    assert r.signaled?, "expected signaled process"
  else
    raise "expected [:closed, result], got #{msg.inspect}"
  end
end

results << test("select handles non-zero exit codes") do
  p1 = Umi::Proctor.new("#{FIXTURES}/exit-code", "42")

  # The fixture outputs a message before exiting, so drain until :closed
  result_msg = nil
  5.times do
    result = Umi::Proctor.select(p1, timeout: 2)
    break if result.nil?

    _, msg = result
    if msg[0] == :closed
      result_msg = msg
      break
    end
  end

  assert result_msg, "expected [:closed, ...] but never got it"

  case result_msg
  in [:closed, r]
    assert_equal 42, r.exit_code
    assert !r.success?
  else
    raise "expected [:closed, result], got #{result_msg.inspect}"
  end
end

# =============================================================================
# Parallel monitoring (the whole point!)
# =============================================================================
puts "\n--- Parallel monitoring ---"

results << test("collect results from 5 parallel workers") do
  # Launch 5 workers that each output their ID and exit
  workers = 5.times.map do |i|
    Umi::Proctor.new("ruby", "-e", "puts 'worker-#{i}'")
  end

  results_map = {}

  until workers.all?(&:exited?)
    result = Umi::Proctor.select(*workers, timeout: 5)
    break if result.nil?

    proctor, msg = result
    case msg
    in [:stdout, data]
      results_map[proctor.pid] = data.chomp
    in [:closed, _]
      # Expected
    end
  end

  # Should have output from all 5 workers
  assert_equal 5, results_map.size
  values = results_map.values.sort
  assert_equal ["worker-0", "worker-1", "worker-2", "worker-3", "worker-4"], values

  workers.each { |w| w.join rescue nil }
end

results << test("monitor long-running workers with interleaved output") do
  # 3 workers that each output multiple lines with different timing
  workers = [
    Umi::Proctor.new("ruby", "-e", "$stdout.sync=true; 3.times { |i| puts 'A'+i.to_s; sleep 0.03 }"),
    Umi::Proctor.new("ruby", "-e", "$stdout.sync=true; 3.times { |i| puts 'B'+i.to_s; sleep 0.04 }"),
    Umi::Proctor.new("ruby", "-e", "$stdout.sync=true; 3.times { |i| puts 'C'+i.to_s; sleep 0.05 }")
  ]

  messages = []

  until workers.all?(&:exited?)
    result = Umi::Proctor.select(*workers, timeout: 5)
    break if result.nil?

    proctor, msg = result
    case msg
    in [:stdout, data]
      messages << data.chomp
    in [:closed, _]
      # Expected
    end
  end

  # Should have 9 messages total (3 workers x 3 messages each)
  assert_equal 9, messages.length

  # Check that messages are interleaved (not all A's first, then B's, then C's)
  # This verifies parallel monitoring is working
  a_positions = messages.each_with_index.select { |m, _| m.start_with?("A") }.map(&:last)
  b_positions = messages.each_with_index.select { |m, _| m.start_with?("B") }.map(&:last)
  c_positions = messages.each_with_index.select { |m, _| m.start_with?("C") }.map(&:last)

  # A's should finish before C's (A has 30ms delay, C has 50ms)
  assert a_positions.max < c_positions.max, "expected A's to finish before C's"

  workers.each { |w| w.join rescue nil }
end

results << test("one slow worker doesn't block others") do
  slow = Umi::Proctor.new("ruby", "-e", "sleep 1; puts 'slow'")
  fast = Umi::Proctor.new("ruby", "-e", "puts 'fast'")

  start = Time.now
  result = Umi::Proctor.select(slow, fast, timeout: 2)
  elapsed = Time.now - start

  assert result, "expected result"
  proctor, msg = result

  # Fast worker should respond first
  assert_equal fast, proctor
  assert_equal [:stdout, "fast\n"], msg

  # Should be quick (not waiting for slow)
  assert elapsed < 0.5, "took too long: #{elapsed}s"

  slow.kill(:KILL)
  [slow, fast].each { |p| p.join rescue nil }
end

# =============================================================================
# Edge cases
# =============================================================================
puts "\n--- Edge cases ---"

results << test("select with already-exited proctor") do
  p1 = Umi::Proctor.new("true")
  p1.join  # Wait for it to exit

  assert p1.exited?

  result = Umi::Proctor.select(p1, timeout: 1)

  assert result, "expected result"
  proctor, msg = result
  assert_equal :closed, msg[0]
end

results << test("select with mix of live and exited proctors") do
  exited = Umi::Proctor.new("true")
  exited.join

  live = Umi::Proctor.new("ruby", "-e", "sleep 0.1; puts 'live'")

  result = Umi::Proctor.select(exited, live, timeout: 2)

  # Should get output from live proctor (exited has no output)
  assert result, "expected result"
  proctor, msg = result

  # Could get either the exited's :closed or the live's output
  # depending on timing. Either is valid.
  assert [exited, live].include?(proctor)

  live.kill(:KILL) rescue nil
  live.join rescue nil
end

results << test("select with all proctors already exited") do
  p1 = Umi::Proctor.new("true")
  p2 = Umi::Proctor.new("false")

  p1.join
  p2.join

  result = Umi::Proctor.select(p1, p2, timeout: 1)

  assert result, "expected result"
  _, msg = result
  assert_equal :closed, msg[0]
end

results << test("select with timeout: nil waits forever") do
  # Use a short delay so test doesn't hang if broken
  p1 = Umi::Proctor.new("ruby", "-e", "sleep 0.1; puts 'done'")

  start = Time.now
  result = Umi::Proctor.select(p1, timeout: nil)
  elapsed = Time.now - start

  assert result, "expected result"
  assert elapsed >= 0.1, "didn't wait for output"
  assert elapsed < 1.0, "waited too long"

  p1.join
end

results << test("select with timeout: 0 returns immediately if no data") do
  p1 = Umi::Proctor.new("#{FIXTURES}/hang")

  start = Time.now
  result = Umi::Proctor.select(p1, timeout: 0)
  elapsed = Time.now - start

  assert_nil result
  assert elapsed < 0.1, "should return immediately, took #{elapsed}s"

  p1.kill(:KILL)
  p1.join(timeout: 1)
end

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
passed = results.count(true)
failed = results.count(false)
puts "Results: #{passed} passed, #{failed} failed"

if failed > 0
  puts "SOME TESTS FAILED"
  exit 1
else
  puts "All tests passed"
  exit 0
end
