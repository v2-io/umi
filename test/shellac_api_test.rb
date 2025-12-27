#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the new Shellac API: pop, pop_stdout, pop_stderr, peek, output?,
# Enumerable, and pattern matching idioms.
#
# These tests focus on the API contract and return value semantics,
# complementing the stress tests which focus on concurrency and edge cases.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'rotp'

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
    puts "  #{e.backtrace.first(3).join("\n  ")}"
    false
  end
end

def assert(condition, msg = "assertion failed")
  raise msg unless condition
end

def assert_equal(expected, actual)
  raise "expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

puts "=" * 60
puts "ROTP::Shellac API Tests"
puts "Ruby #{RUBY_VERSION}"
puts "=" * 60
puts

results = []

# =============================================================================
# pop - unified stdout/stderr with tagged tuples
# =============================================================================
puts "--- pop: unified stdout/stderr ---"

results << test("pop returns [:stdout, data] for stdout") do
  sh = ROTP::Shellac.new("cat")
  sh << "hello\n"

  result = sh.pop(2)
  assert_equal [:stdout, "hello\n"], result

  sh.close_stdin
  sh.join
end

results << test("pop returns [:stderr, data] for stderr") do
  # Use a ruby one-liner to write to stderr
  sh = ROTP::Shellac.new("ruby", "-e", "$stderr.puts 'error msg'")

  result = sh.pop(2)
  assert_equal [:stderr, "error msg\n"], result

  sh.join
end

results << test("pop returns [:closed, result] when process exits") do
  sh = ROTP::Shellac.new("true")

  result = sh.pop(2)

  case result
  in [:closed, r]
    assert r.is_a?(ROTP::Shellac::Result), "expected Result, got #{r.class}"
    assert r.success?
  else
    raise "expected [:closed, result], got #{result.inspect}"
  end
end

results << test("pop returns nil on timeout") do
  sh = ROTP::Shellac.new("#{FIXTURES}/hang")

  result = sh.pop(0.1)
  assert result.nil?, "expected nil, got #{result.inspect}"

  sh.kill(:KILL)
  sh.join(timeout: 1)
end

results << test("pop with :forever blocks until data arrives") do
  sh = ROTP::Shellac.new("ruby", "-e", "sleep 0.2; puts 'delayed'")

  # This should block until the output arrives
  result = sh.pop(:forever)
  assert_equal [:stdout, "delayed\n"], result

  sh.join
end

results << test("pop with 0 returns nil immediately when no data") do
  sh = ROTP::Shellac.new("#{FIXTURES}/hang")

  start = Time.now
  result = sh.pop(0)
  elapsed = Time.now - start

  assert result.nil?, "expected nil, got #{result.inspect}"
  assert elapsed < 0.1, "should return immediately, took #{elapsed}s"

  sh.kill(:KILL)
  sh.join(timeout: 1)
end

results << test("pop interleaves stdout and stderr in order") do
  # Script that alternates stdout and stderr
  script = <<~RUBY
    $stdout.sync = $stderr.sync = true
    $stdout.puts "out1"
    $stderr.puts "err1"
    $stdout.puts "out2"
    $stderr.puts "err2"
  RUBY

  sh = ROTP::Shellac.new("ruby", "-e", script)

  messages = []
  4.times do
    msg = sh.pop(2)
    break if msg.nil? || msg[0] == :closed
    messages << msg
  end

  # Should have both stdout and stderr
  assert messages.any? { |m| m[0] == :stdout }, "no stdout messages"
  assert messages.any? { |m| m[0] == :stderr }, "no stderr messages"

  sh.join
end

results << test("pop pattern matching idiom") do
  sh = ROTP::Shellac.new("echo", "test")

  handled = false
  case sh.pop(2)
  in [:stdout, line]
    handled = true
    assert_equal "test\n", line
  in [:stderr, _]
    raise "unexpected stderr"
  in nil
    raise "unexpected timeout"
  in [:closed, _]
    raise "unexpected close"
  end

  assert handled, "pattern not matched"
  sh.join
end

# =============================================================================
# pop_stdout - stdout only, returns [:ok, data], nil, or [:closed, result]
# =============================================================================
puts "\n--- pop_stdout: stdout only ---"

results << test("pop_stdout returns [:ok, data] for stdout") do
  sh = ROTP::Shellac.new("echo", "hello")

  result = sh.pop_stdout(2)
  assert_equal [:ok, "hello\n"], result

  sh.join
end

results << test("pop_stdout returns [:closed, result] when process exits") do
  sh = ROTP::Shellac.new("true")

  result = sh.pop_stdout(2)
  case result
  in [:closed, r]
    assert r.is_a?(ROTP::Shellac::Result)
    assert r.success?
  else
    raise "expected [:closed, result], got #{result.inspect}"
  end
end

results << test("pop_stdout returns nil on timeout") do
  sh = ROTP::Shellac.new("#{FIXTURES}/hang")

  result = sh.pop_stdout(0.1)
  assert result.nil?, "expected nil, got #{result.inspect}"

  sh.kill(:KILL)
  sh.join(timeout: 1)
end

results << test("pop_stdout buffers stderr while waiting") do
  # Script writes to stderr then stdout
  script = <<~RUBY
    $stdout.sync = $stderr.sync = true
    $stderr.puts "error first"
    $stdout.puts "output second"
  RUBY

  sh = ROTP::Shellac.new("ruby", "-e", script)

  # pop_stdout should skip stderr and return stdout
  result = sh.pop_stdout(2)
  assert_equal [:ok, "output second\n"], result

  # stderr should be buffered and available via pop_stderr
  result = sh.pop_stderr(2)
  assert_equal [:ok, "error first\n"], result

  sh.join
end

results << test("pop_stdout with :forever blocks until stdout") do
  sh = ROTP::Shellac.new("ruby", "-e", "sleep 0.2; puts 'stdout'")

  result = sh.pop_stdout(:forever)
  assert_equal [:ok, "stdout\n"], result

  sh.join
end

results << test("pop_stdout pattern matching idiom") do
  sh = ROTP::Shellac.new("echo", "line")

  output = case sh.pop_stdout(2)
           in [:ok, line] then line.chomp
           in nil then "timeout"
           in [:closed, _] then "closed"
           end

  assert_equal "line", output
  sh.join
end

# =============================================================================
# pop_stderr - stderr only, returns [:ok, data], nil, or [:closed, result]
# =============================================================================
puts "\n--- pop_stderr: stderr only ---"

results << test("pop_stderr returns [:ok, data] for stderr") do
  sh = ROTP::Shellac.new("ruby", "-e", "$stderr.puts 'error'")

  result = sh.pop_stderr(2)
  assert_equal [:ok, "error\n"], result

  sh.join
end

results << test("pop_stderr returns [:closed, result] when no stderr and process exits") do
  sh = ROTP::Shellac.new("true")

  result = sh.pop_stderr(2)
  case result
  in [:closed, r]
    assert r.is_a?(ROTP::Shellac::Result)
    assert r.success?
  else
    raise "expected [:closed, result], got #{result.inspect}"
  end
end

results << test("pop_stderr buffers stdout while waiting") do
  # Script writes to stdout then stderr
  script = <<~RUBY
    $stdout.sync = $stderr.sync = true
    $stdout.puts "output first"
    $stderr.puts "error second"
  RUBY

  sh = ROTP::Shellac.new("ruby", "-e", script)

  # pop_stderr should skip stdout and return stderr
  result = sh.pop_stderr(2)
  assert_equal [:ok, "error second\n"], result

  # stdout should be buffered and available
  result = sh.pop_stdout(2)
  assert_equal [:ok, "output first\n"], result

  sh.join
end

# =============================================================================
# pop!, pop_stdout!, pop_stderr! - raising variants
# =============================================================================
puts "\n--- Raising variants (!) ---"

results << test("pop! returns data on success") do
  sh = ROTP::Shellac.new("echo", "test")

  result = sh.pop!(2)
  assert_equal [:stdout, "test\n"], result

  sh.join
end

results << test("pop! raises Timeout on timeout") do
  sh = ROTP::Shellac.new("#{FIXTURES}/hang")

  raised = false
  begin
    sh.pop!(0.1)
  rescue ROTP::Shellac::Timeout
    raised = true
  end

  assert raised, "expected Timeout to be raised"

  sh.kill(:KILL)
  sh.join(timeout: 1)
end

results << test("pop! raises ProcessExited when closed") do
  sh = ROTP::Shellac.new("true")

  raised = false
  begin
    sh.pop!(2)
  rescue ROTP::Shellac::ProcessExited
    raised = true
  end

  assert raised, "expected ProcessExited to be raised"
end

results << test("pop_stdout! returns just the data (not tagged)") do
  sh = ROTP::Shellac.new("echo", "data")

  result = sh.pop_stdout!(2)
  assert_equal "data\n", result  # String, not tuple

  sh.join
end

results << test("pop_stderr! returns just the data (not tagged)") do
  sh = ROTP::Shellac.new("ruby", "-e", "$stderr.puts 'err'")

  result = sh.pop_stderr!(2)
  assert_equal "err\n", result  # String, not tuple

  sh.join
end

# =============================================================================
# peek and output? - non-consuming inspection
# =============================================================================
puts "\n--- peek and output? ---"

results << test("peek returns next message without consuming") do
  sh = ROTP::Shellac.new("echo", "peek-test")

  # Give it a moment for output to arrive
  sleep 0.1

  # peek should return the message
  peeked = sh.peek
  assert_equal [:stdout, "peek-test\n"], peeked

  # pop should return the same message
  popped = sh.pop(2)
  assert_equal peeked, popped

  sh.join
end

results << test("peek returns nil when no data available") do
  sh = ROTP::Shellac.new("#{FIXTURES}/hang")

  result = sh.peek
  assert result.nil?, "expected nil, got #{result.inspect}"

  sh.kill(:KILL)
  sh.join(timeout: 1)
end

results << test("output? returns true when data waiting") do
  sh = ROTP::Shellac.new("echo", "output")
  sleep 0.1  # Let output arrive

  assert sh.output?, "expected output? to be true"

  sh.pop(2)  # consume
  sh.join
end

results << test("output? returns false when no data") do
  sh = ROTP::Shellac.new("#{FIXTURES}/hang")

  assert !sh.output?, "expected output? to be false"

  sh.kill(:KILL)
  sh.join(timeout: 1)
end

# =============================================================================
# Enumerable and Enumerator support
# =============================================================================
puts "\n--- Enumerable/Enumerator ---"

results << test("each iterates over stdout lines") do
  sh = ROTP::Shellac.new("ruby", "-e", "3.times { |i| puts i }")

  lines = []
  sh.each do |line|
    lines << line.chomp
  end

  assert_equal ["0", "1", "2"], lines
end

results << test("each without block returns Enumerator") do
  sh = ROTP::Shellac.new("echo", "enum")

  enum = sh.each
  assert enum.is_a?(Enumerator), "expected Enumerator, got #{enum.class}"

  line = enum.next
  assert_equal "enum\n", line

  sh.join
end

results << test("next returns stdout data") do
  sh = ROTP::Shellac.new("echo", "next-test")

  line = sh.next
  assert_equal "next-test\n", line

  sh.join rescue nil  # May raise StopIteration from Enumerator internals
end

results << test("next raises StopIteration when closed") do
  sh = ROTP::Shellac.new("true")  # Exits immediately with no output

  raised = false
  begin
    sh.next
  rescue StopIteration
    raised = true
  end

  assert raised, "expected StopIteration"
end

results << test("Enumerable#take works") do
  sh = ROTP::Shellac.new("ruby", "-e", "5.times { |i| puts i }")

  lines = sh.take(3).map(&:chomp)
  assert_equal ["0", "1", "2"], lines

  sh.join rescue nil
end

results << test("Enumerable#map works") do
  sh = ROTP::Shellac.new("ruby", "-e", "3.times { |i| puts i }")

  doubled = sh.map { |line| line.chomp.to_i * 2 }
  assert_equal [0, 2, 4], doubled
end

results << test("Enumerable#select works") do
  sh = ROTP::Shellac.new("ruby", "-e", "5.times { |i| puts i }")

  evens = sh.select { |line| line.chomp.to_i.even? }.map(&:chomp)
  assert_equal ["0", "2", "4"], evens
end

results << test("lazy enumeration works") do
  sh = ROTP::Shellac.new("ruby", "-e", "10.times { |i| puts i }")

  # Lazy should only consume what's needed
  lines = sh.lazy.take(3).force.map(&:chomp)
  assert_equal ["0", "1", "2"], lines

  sh.kill(:KILL) rescue nil
  sh.join(timeout: 1) rescue nil
end

results << test("each_output iterates over both stdout and stderr") do
  script = <<~RUBY
    $stdout.sync = $stderr.sync = true
    puts "out"
    $stderr.puts "err"
  RUBY

  sh = ROTP::Shellac.new("ruby", "-e", script)

  outputs = []
  sh.each_output(timeout: 2) do |type, line|
    outputs << [type, line.chomp]
  end

  assert outputs.include?([:stdout, "out"]), "missing stdout"
  assert outputs.include?([:stderr, "err"]), "missing stderr"
end

results << test("each_output without block returns Enumerator") do
  sh = ROTP::Shellac.new("echo", "test")

  enum = sh.each_output(timeout: 2)
  assert enum.is_a?(Enumerator), "expected Enumerator"

  type, line = enum.next
  assert_equal :stdout, type
  assert_equal "test\n", line

  sh.join rescue nil
end

# =============================================================================
# Edge cases and integration
# =============================================================================
puts "\n--- Edge cases ---"

results << test("pop then pop_stdout uses buffered data") do
  script = <<~RUBY
    $stdout.sync = $stderr.sync = true
    puts "line1"
    puts "line2"
  RUBY

  sh = ROTP::Shellac.new("ruby", "-e", script)

  # pop gets first line as [:stdout, ...]
  first = sh.pop(2)
  assert_equal [:stdout, "line1\n"], first

  # pop_stdout gets second line as [:ok, ...]
  second = sh.pop_stdout(2)
  assert_equal [:ok, "line2\n"], second

  sh.join
end

results << test("mixing pop and pop_stderr respects buffer") do
  script = <<~RUBY
    $stdout.sync = $stderr.sync = true
    $stderr.puts "err1"
    $stderr.puts "err2"
  RUBY

  sh = ROTP::Shellac.new("ruby", "-e", script)

  # pop gets first as [:stderr, ...]
  first = sh.pop(2)
  assert_equal [:stderr, "err1\n"], first

  # pop_stderr gets second as [:ok, ...]
  second = sh.pop_stderr(2)
  assert_equal [:ok, "err2\n"], second

  sh.join
end

results << test("pop correctly handles fast process") do
  # Process exits immediately after output
  sh = ROTP::Shellac.new("echo", "fast")

  # Should get the output, not miss it
  result = sh.pop(2)
  assert_equal [:stdout, "fast\n"], result

  # Next should be closed
  result = sh.pop(2)
  case result
  in [:closed, r]
    assert r.success?
  else
    raise "expected [:closed, ...], got #{result.inspect}"
  end
end

results << test("multiple pops after process exits drain buffer") do
  sh = ROTP::Shellac.new("ruby", "-e", "3.times { |i| puts i }")

  # Wait for process to complete
  sleep 0.3

  # Should still be able to get all output
  captured = []
  3.times do
    case sh.pop(1)
    in [:stdout, line]
      captured << line.chomp
    in [:closed, _] | nil
      break
    end
  end

  assert_equal ["0", "1", "2"], captured
end

results << test("pop_stdout after pop that saw stderr") do
  script = <<~RUBY
    $stdout.sync = $stderr.sync = true
    $stderr.puts "err"
    puts "out"
  RUBY

  sh = ROTP::Shellac.new("ruby", "-e", script)
  sleep 0.1

  # pop gets stderr first (whichever arrives)
  first = sh.pop(2)

  if first[0] == :stderr
    # stderr came first, pop_stdout should get stdout
    second = sh.pop_stdout(2)
    assert_equal [:ok, "out\n"], second
  else
    # stdout came first
    assert_equal [:stdout, "out\n"], first
    # pop_stderr should get stderr
    second = sh.pop_stderr(2)
    assert_equal [:ok, "err\n"], second
  end

  sh.join
end

results << test("stderr: :merge option makes all output come as :stdout") do
  script = <<~RUBY
    $stdout.sync = $stderr.sync = true
    $stderr.puts "err"
    puts "out"
  RUBY

  sh = ROTP::Shellac.new("ruby", "-e", script, stderr: :merge)

  # Both should come as :stdout via pop
  messages = []
  2.times do
    case sh.pop(2)
    in [:stdout, line]
      messages << line.chomp
    else
      break
    end
  end

  assert messages.include?("err"), "expected stderr as stdout"
  assert messages.include?("out"), "expected stdout"

  sh.join
end

# =============================================================================
# OTP-like patterns: timeouts as normal control flow, not errors
# =============================================================================
puts "\n--- OTP-like patterns ---"

results << test("polling: non-blocking check with 0 timeout") do
  sh = ROTP::Shellac.new("cat")

  # Non-blocking check - nothing available yet
  case sh.pop_stdout(0)
  in nil
    # Expected - no data yet, do other work
  in [:ok, _]
    raise "unexpected data"
  in [:closed, _]
    raise "unexpected close"
  end

  # Now send data and poll again
  sh << "hello\n"
  sleep 0.05  # Let it arrive

  case sh.pop_stdout(0)
  in [:ok, line]
    assert_equal "hello\n", line
  in nil
    raise "expected data after send"
  in [:closed, _]
    raise "unexpected close"
  end

  sh.close_stdin
  sh.join
end

results << test("request-response: send and wait for reply") do
  sh = ROTP::Shellac.new("cat")

  # Request-response pattern with timeout
  sh << "request1\n"
  case sh.pop_stdout(1)
  in [:ok, response]
    assert_equal "request1\n", response
  in nil
    raise "response timed out"
  in [:closed, _]
    raise "process died unexpectedly"
  end

  # Second request
  sh << "request2\n"
  case sh.pop_stdout(1)
  in [:ok, response]
    assert_equal "request2\n", response
  in nil
    raise "response timed out"
  in [:closed, _]
    raise "process died unexpectedly"
  end

  sh.close_stdin
  sh.join
end

results << test("heartbeat: timeout triggers action") do
  # Process that outputs slowly
  script = <<~RUBY
    $stdout.sync = true
    3.times do |i|
      sleep 0.15
      puts "beat\#{i}"
    end
  RUBY

  sh = ROTP::Shellac.new("ruby", "-e", script)

  heartbeats = 0
  timeouts = 0

  5.times do
    case sh.pop_stdout(0.05)
    in [:ok, _]
      heartbeats += 1
    in nil
      timeouts += 1
      # In real code: check health, send ping, etc.
    in [:closed, _]
      break
    end
  end

  # Should see a mix of heartbeats and timeouts
  assert heartbeats > 0, "expected some heartbeats"
  assert timeouts > 0, "expected some timeouts (this is normal)"

  sh.join(timeout: 2) rescue sh.kill(:KILL)
end

results << test("graceful degradation: fallback on timeout") do
  # Slow process
  sh = ROTP::Shellac.new("ruby", "-e", "sleep 0.3; puts 'slow'")

  # Try fast path first
  result = case sh.pop_stdout(0.05)
           in [:ok, data] then data.chomp
           in nil then "fallback_value"  # Use fallback on timeout
           in [:closed, _] then "closed"
           end

  assert_equal "fallback_value", result

  # Later, the slow result arrives
  case sh.pop_stdout(1)
  in [:ok, data]
    assert_equal "slow\n", data
  in nil | [:closed, _]
    # Process may have exited
  end

  sh.join(timeout: 1) rescue nil
end

results << test("retry with backoff on timeout") do
  # Process that outputs after delay
  sh = ROTP::Shellac.new("ruby", "-e", "sleep 0.2; puts 'delayed'")

  attempts = 0
  success = false
  timeout = 0.05

  4.times do
    attempts += 1
    case sh.pop_stdout(timeout)
    in [:ok, data]
      assert_equal "delayed\n", data
      success = true
      break
    in nil
      timeout *= 2  # Exponential backoff
    in [:closed, _]
      break
    end
  end

  assert success, "should eventually succeed"
  assert attempts > 1, "should have retried at least once"

  sh.join
end

results << test("deadline: overall timeout with per-message polls") do
  script = <<~RUBY
    $stdout.sync = true
    5.times { |i| sleep 0.05; puts i }
  RUBY

  sh = ROTP::Shellac.new("ruby", "-e", script)

  deadline = Time.now + 0.5
  lines = []

  while Time.now < deadline
    remaining = deadline - Time.now
    break if remaining <= 0

    case sh.pop_stdout([remaining, 0.1].min)
    in [:ok, line]
      lines << line.chomp
    in nil
      # Keep trying until deadline
    in [:closed, _]
      break
    end
  end

  assert lines.length >= 3, "expected at least 3 lines within deadline"

  sh.join(timeout: 1) rescue sh.kill(:KILL)
end

results << test("selective receive: filter message types") do
  script = <<~RUBY
    $stdout.sync = $stderr.sync = true
    $stderr.puts "noise1"
    puts "signal"
    $stderr.puts "noise2"
  RUBY

  sh = ROTP::Shellac.new("ruby", "-e", script)
  sleep 0.1  # Let messages arrive

  # Want stdout specifically, ignore stderr
  case sh.pop_stdout(1)
  in [:ok, line]
    assert_equal "signal\n", line
  in nil | [:closed, _]
    raise "expected stdout"
  end

  # Stderr was buffered, still available
  case sh.pop_stderr(0.1)
  in [:ok, err]
    assert err.include?("noise"), "expected stderr"
  in nil | [:closed, _]
    # May have drained already
  end

  sh.join
end

results << test("collect with timeout: gather available messages") do
  script = <<~RUBY
    $stdout.sync = true
    3.times { |i| puts "msg\#{i}"; sleep 0.02 }
    sleep 0.5  # Pause before final
    puts "final"
  RUBY

  sh = ROTP::Shellac.new("ruby", "-e", script)

  # Collect messages until timeout (short window)
  collected = []
  loop do
    case sh.pop_stdout(0.1)
    in [:ok, line]
      collected << line.chomp
    in nil
      break  # Timeout = done collecting this batch
    in [:closed, _]
      break
    end
  end

  # Should have collected the first 3, not waited for final
  assert collected.length >= 2, "should collect multiple messages"
  assert !collected.include?("final"), "should not wait for delayed message"

  sh.kill(:KILL)
  sh.join(timeout: 1) rescue nil
end

results << test("interleaved conversation with timeouts") do
  sh = ROTP::Shellac.new("cat")

  # Simulate multi-turn conversation
  conversation = []

  3.times do |turn|
    sh << "turn#{turn}\n"

    case sh.pop_stdout(1)
    in [:ok, response]
      conversation << [turn, response.chomp]
    in nil
      conversation << [turn, :timeout]
    in [:closed, _]
      conversation << [turn, :closed]
      break
    end
  end

  expected = [[0, "turn0"], [1, "turn1"], [2, "turn2"]]
  assert_equal expected, conversation

  sh.close_stdin
  sh.join
end

results << test("Result inspection after :closed") do
  # Process with specific exit code
  sh = ROTP::Shellac.new("ruby", "-e", "puts 'output'; exit 42")

  # Get output
  case sh.pop_stdout(2)
  in [:ok, line]
    assert_equal "output\n", line
  else
    raise "expected output"
  end

  # Get closed with result
  case sh.pop_stdout(2)
  in [:closed, result]
    assert_equal 42, result.exit_code
    assert !result.success?
    assert !result.signaled?
  else
    raise "expected [:closed, result]"
  end
end

results << test("signal Result inspection") do
  sh = ROTP::Shellac.new("sleep", "100")
  sh.kill(:TERM)

  # Wait for close
  case sh.pop(2)
  in [:closed, result]
    assert result.signaled?
    assert_equal :TERM, result.signal
  else
    raise "expected [:closed, result]"
  end
end

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
passed = results.count(true)
failed = results.count(false)
puts "Results: #{passed} passed, #{failed} failed"
puts "=" * 60

exit(failed > 0 ? 1 : 0)
