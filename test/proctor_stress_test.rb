#!/usr/bin/env ruby
# frozen_string_literal: true

# Stress tests for Umi::Proctor
# These probe edge cases and race conditions that could break the implementation.
#
# Reproducibility:
#   SEED=12345 ruby test/proctor_stress_test.rb  # Reproduce a specific run
#
# The seed is printed at startup so failures can be reproduced.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'umi'

# Reproducible randomness
SEED = (ENV['SEED'] || Random.new_seed).to_i
srand(SEED)

FIXTURES = File.expand_path('fixtures/processes', __dir__)

# Global watchdog - dump stack traces if test suite hangs
WATCHDOG_TIMEOUT = (ENV['WATCHDOG_TIMEOUT'] || 300).to_i  # 5 minutes default
$watchdog = Thread.new do
  sleep WATCHDOG_TIMEOUT
  $stderr.puts "\n\n" + "=" * 60
  $stderr.puts "WATCHDOG TIMEOUT (#{WATCHDOG_TIMEOUT}s) - Test suite hung!"
  $stderr.puts "SEED=#{SEED}"
  $stderr.puts "=" * 60
  Thread.list.each_with_index do |t, i|
    next if t == Thread.current
    $stderr.puts "\n--- Thread #{i} [#{t.status || 'dead'}] ---"
    $stderr.puts(t.backtrace&.first(20)&.join("\n") || "(no backtrace)")
  end
  $stderr.puts "=" * 60
  exit! 1
end

# Also handle Ctrl-C gracefully
Signal.trap("INT") do
  $stderr.puts "\n\nInterrupted! SEED=#{SEED}"
  $stderr.puts "Thread dump:"
  Thread.list.each_with_index do |t, i|
    $stderr.puts "\n--- Thread #{i} [#{t.status || 'dead'}] ---"
    $stderr.puts(t.backtrace&.first(15)&.join("\n") || "(no backtrace)")
  end
  exit! 1
end

def test(name)
  print "#{name}... "
  $stdout.flush
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
puts "Umi::Proctor Stress Tests"
puts "Ruby #{RUBY_VERSION}"
puts "SEED=#{SEED}  (use SEED=#{SEED} to reproduce)"
puts "=" * 60
puts

results = []

# =============================================================================
# Spawn failures
# =============================================================================
puts "--- Spawn Failures ---"

results << test("command not found") do
  raised = false
  begin
    shellac = Umi::Proctor.new("nonexistent_command_xyz_123")
    # The watcher should still start, but process spawn fails
    # We should get an error when we try to interact
    shellac.join(timeout: 2.0)
  rescue => e
    raised = true
  end
  # Note: behavior depends on how popen3 handles missing commands
  # This test documents current behavior, whatever it is
  true  # Don't fail - we're exploring behavior
end

results << test("permission denied (non-executable)") do
  # Create a file that's not executable
  tmp = "/tmp/shellac_test_noexec_#{$$}"
  File.write(tmp, "#!/bin/bash\necho hi")
  File.chmod(0644, tmp)  # readable but not executable

  begin
    shellac = Umi::Proctor.new(tmp)
    result = shellac.join(timeout: 2.0)
    # Should fail with non-zero exit or error
  rescue => e
    # Expected
  ensure
    File.unlink(tmp) rescue nil
  end
  true
end

# =============================================================================
# Rapid lifecycle
# =============================================================================
puts "\n--- Rapid Lifecycle ---"

results << test("50 rapid create/destroy cycles") do
  50.times do |i|
    shellac = Umi::Proctor.new("true")
    result = shellac.join(timeout: 2.0)
    raise "iteration #{i} failed" unless result.success?
  end
end

results << test("10 concurrent Proctors") do
  shellacs = 10.times.map do |i|
    s = Umi::Proctor.new("cat")
    s << "msg#{i}\n"
    s
  end

  # Collect responses
  responses = shellacs.map { |s| s.pop_stdout!(2.0).chomp }

  # Close all
  shellacs.each(&:close_stdin)
  join_results = shellacs.map { |s| s.join(timeout: 2.0) }

  assert_equal 10, responses.size
  assert join_results.all?(&:success?)
end

results << test("create new Proctor while previous still cleaning up") do
  # Don't wait for join - just close and move on
  20.times do |i|
    shellac = Umi::Proctor.new("echo", "hi")
    shellac.pop_stdout!(1.0)
    # Don't join - let GC handle it
  end
  # Give time for cleanup
  sleep 0.5

  # Now create one more and verify it works
  final = Umi::Proctor.new("echo", "final")
  line = final.pop_stdout!(1.0)
  assert_equal "final\n", line
  final.join(timeout: 1.0)
end

# =============================================================================
# I/O edge cases
# =============================================================================
puts "\n--- I/O Edge Cases ---"

results << test("large output (1MB)") do
  # Generate 1MB of output
  shellac = Umi::Proctor.new("ruby", "-e", "puts 'x' * 1024 * 1024")

  total = 0
  shellac.each_line(timeout: 10.0) do |line|
    total += line.bytesize
  end

  # Should be ~1MB plus newline
  assert total > 1_000_000, "expected >1MB, got #{total}"
end

results << test("binary data with null bytes") do
  # Send binary data through
  shellac = Umi::Proctor.new("cat")
  binary = (0..255).to_a.pack("C*")  # All byte values
  shellac << binary
  shellac.close_stdin

  # Collect all output
  output = +""  # Mutable string
  shellac.each_line(timeout: 2.0) do |chunk|
    output << chunk
  end

  # May not match exactly due to line buffering, but should have data
  assert output.bytesize > 0, "expected some output"
end

results << test("no newline in output") do
  shellac = Umi::Proctor.new("ruby", "-e", "print 'no newline'")

  output = +""  # Mutable string
  shellac.each_line(timeout: 2.0) do |chunk|
    output << chunk
  end

  assert output.include?("no newline"), "expected 'no newline' in output"
end

results << test("empty output then exit") do
  shellac = Umi::Proctor.new("true")  # Produces no output
  result = shellac.join(timeout: 2.0)
  assert result.success?
end

results << test("output only on stderr") do
  shellac = Umi::Proctor.new("ruby", "-e", "$stderr.puts 'error only'")

  # pop_stdout! should timeout or raise since no stdout
  raised = false
  begin
    shellac.pop_stdout!(0.5)
  rescue Umi::Proctor::Timeout, Umi::Proctor::ProcessExited
    raised = true
  end

  shellac.join(timeout: 1.0) rescue nil
  assert raised, "expected timeout or process exited"
end

# =============================================================================
# Interleaved I/O
# =============================================================================
puts "\n--- Interleaved I/O ---"

results << test("rapid stdout/stderr alternation") do
  # Ruby script that alternates rapidly
  script = <<~RUBY
    $stdout.sync = true
    $stderr.sync = true
    10.times do |i|
      puts "out\#{i}"
      $stderr.puts "err\#{i}"
    end
  RUBY

  shellac = Umi::Proctor.new("ruby", "-e", script)

  stdout_count = 0
  stderr_count = 0

  shellac.each_output do |stream, line|
    case stream
    when :stdout then stdout_count += 1
    when :stderr then stderr_count += 1
    end
  end

  assert_equal 10, stdout_count
  assert_equal 10, stderr_count
end

results << test("many stderr before stdout (buffer stress)") do
  script = <<~RUBY
    $stdout.sync = true
    $stderr.sync = true
    50.times { |i| $stderr.puts "err\#{i}" }
    puts "finally stdout"
  RUBY

  shellac = Umi::Proctor.new("ruby", "-e", script)

  # This should not hang - the fix should handle buffering correctly
  line = shellac.pop_stdout!(5.0)
  assert_equal "finally stdout\n", line

  shellac.join(timeout: 2.0)
end

# =============================================================================
# Process death scenarios
# =============================================================================
puts "\n--- Process Death Scenarios ---"

results << test("process dies immediately") do
  shellac = Umi::Proctor.new("false")  # Exits immediately with code 1
  result = shellac.join(timeout: 2.0)
  assert_equal 1, result.exit_code
end

results << test("process killed by signal during operation") do
  shellac = Umi::Proctor.new("sleep", "100")

  # Kill it externally after a brief delay
  Thread.new { sleep 0.1; Process.kill("KILL", shellac.pid) }

  result = shellac.join(timeout: 2.0)
  assert result.signaled?
end

results << test("stdin write after process dies") do
  shellac = Umi::Proctor.new("true")  # Exits immediately
  sleep 0.1  # Let it die

  # Writing should raise or be silently ignored
  raised = false
  begin
    shellac << "data\n"
  rescue Umi::Proctor::ProcessExited
    raised = true
  end

  shellac.join(timeout: 1.0) rescue nil
  # Either raised or silently handled - both ok for now
  true
end

results << test("pop_stdout! after process dies with buffered data") do
  script = <<~RUBY
    puts "line1"
    puts "line2"
    puts "line3"
  RUBY

  shellac = Umi::Proctor.new("ruby", "-e", script)
  sleep 0.2  # Let it complete

  # Should still be able to read buffered output
  lines = []
  3.times do
    begin
      lines << shellac.pop_stdout!(1.0)
    rescue Umi::Proctor::ProcessExited
      break
    end
  end

  assert lines.size >= 1, "should have received at least 1 line"
end

results << test("segfault handling") do
  # Ruby doesn't easily segfault, use a C program or simulate with KILL
  shellac = Umi::Proctor.new("ruby", "-e", "Process.kill('SEGV', $$)")

  result = shellac.join(timeout: 2.0)
  assert result.signaled?
  assert_equal :SEGV, result.signal
end

# =============================================================================
# Timeout edge cases
# =============================================================================
puts "\n--- Timeout Edge Cases ---"

results << test("very short timeout (1ms)") do
  shellac = Umi::Proctor.new("sleep", "10")

  raised = false
  begin
    shellac.pop_stdout!(0.001)
  rescue Umi::Proctor::Timeout
    raised = true
  end

  shellac.kill(:KILL)
  shellac.join(timeout: 1.0)

  assert raised, "expected timeout"
end

results << test("timeout with data arriving just after") do
  script = <<~RUBY
    sleep 0.15
    puts "delayed"
  RUBY

  shellac = Umi::Proctor.new("ruby", "-e", script)

  # First pop_stdout! should timeout
  raised = false
  begin
    shellac.pop_stdout!(0.05)
  rescue Umi::Proctor::Timeout
    raised = true
  end
  assert raised, "expected first timeout"

  # Second pop_stdout! should succeed
  line = shellac.pop_stdout!(1.0)
  assert_equal "delayed\n", line

  shellac.join(timeout: 1.0)
end

results << test("multiple pop_stdout! calls with different timeouts") do
  shellac = Umi::Proctor.new("cat")

  # First: short timeout, should fail
  raised1 = false
  begin
    shellac.pop_stdout!(0.01)
  rescue Umi::Proctor::Timeout
    raised1 = true
  end

  # Send data
  shellac << "hello\n"

  # Second: longer timeout, should succeed
  line = shellac.pop_stdout!(2.0)
  assert_equal "hello\n", line

  # Third: short timeout again
  raised2 = false
  begin
    shellac.pop_stdout!(0.01)
  rescue Umi::Proctor::Timeout
    raised2 = true
  end

  shellac.close_stdin
  shellac.join(timeout: 1.0)

  assert raised1 && raised2, "expected timeouts"
end

# =============================================================================
# Cleanup and resource leaks
# =============================================================================
puts "\n--- Cleanup / Leaks ---"

results << test("100 Proctors with proper cleanup") do
  100.times do |i|
    shellac = Umi::Proctor.new("echo", "test#{i}")
    shellac.pop_stdout!(1.0)
    shellac.join(timeout: 1.0)
  end

  # If we get here without hanging or crashing, cleanup is working
  true
end

results << test("abandoned Proctors (no join)") do
  # Create Proctors without joining - they should clean up eventually
  10.times do
    shellac = Umi::Proctor.new("sleep", "0.1")
    # Abandon it
  end

  # Force GC
  GC.start
  sleep 0.5

  # Create a new one to verify system isn't broken
  shellac = Umi::Proctor.new("echo", "still works")
  line = shellac.pop_stdout!(1.0)
  assert_equal "still works\n", line
  shellac.join(timeout: 1.0)
end

# =============================================================================
# Block form edge cases
# =============================================================================
puts "\n--- Block Form ---"

results << test("exception in block") do
  raised = false
  begin
    Umi::Proctor.open("cat") do |s|
      s << "test\n"
      raise "intentional error"
    end
  rescue RuntimeError => e
    raised = e.message == "intentional error"
  end

  assert raised, "exception should propagate"

  # Verify cleanup happened - new Proctor should work
  result = Umi::Proctor.open("echo", "cleanup ok") do |s|
    s.pop_stdout!(1.0)
  end
  assert result.success?
end

results << test("early return from block") do
  value = Umi::Proctor.open("cat") do |s|
    s << "test\n"
    line = s.pop_stdout!(1.0)
    s.close_stdin
    "early return: #{line.chomp}"
  end

  # Block returns early, but we get the Result from open()
  assert value.is_a?(Umi::Proctor::Result)
end

# =============================================================================
# Chaos Engineering - random process killing
# =============================================================================
puts "\n--- Chaos Engineering ---"

results << test("chaos: random SIGKILL during operation") do
  # Spawn 20 long-running processes, randomly kill some
  shellacs = []
  errors = []

  20.times do |i|
    begin
      s = Umi::Proctor.new("cat")
      s << "init#{i}\n"
      shellacs << s
    rescue => e
      errors << "spawn #{i}: #{e.message}"
    end
  end

  # Chaos thread - randomly kill processes
  chaos = Thread.new do
    sleep 0.05
    shellacs.each_with_index do |s, i|
      next unless s && s.alive? && rand < 0.5  # Kill ~50%
      begin
        Process.kill("KILL", s.pid)
      rescue Errno::ESRCH
        # Already dead
      end
      sleep rand * 0.02
    end
  end

  # Meanwhile, try to interact with them
  shellacs.each_with_index do |s, i|
    next unless s
    begin
      # Try to receive - may fail if killed
      s.pop_stdout!(0.5)
      s << "more#{i}\n"
      s.pop_stdout!(0.5)
    rescue Umi::Proctor::ProcessExited, Umi::Proctor::Timeout
      # Expected for killed processes
    rescue => e
      errors << "interact #{i}: #{e.class}: #{e.message}"
    end
  end

  chaos.join

  # Clean up survivors
  shellacs.each do |s|
    next unless s
    begin
      s.close_stdin if s.alive?
      s.join(timeout: 1.0)
    rescue Umi::Proctor::Timeout
      s.kill(:KILL) rescue nil
      s.join(timeout: 0.5) rescue nil
    rescue => e
      # Ignore cleanup errors
    end
  end

  # Should have no unexpected errors
  raise errors.join("; ") unless errors.empty?
  true
end

results << test("chaos: rapid stdin writes during death") do
  errors = []

  10.times do |round|
    s = Umi::Proctor.new("cat")

    # Writer thread - spam stdin
    writer = Thread.new do
      100.times do |i|
        begin
          s << "data#{i}\n"
        rescue Umi::Proctor::ProcessExited
          break
        rescue => e
          errors << "write #{round}.#{i}: #{e.class}"
          break
        end
        sleep 0.001
      end
    end

    # Kill after random delay
    sleep rand * 0.05
    s.kill(:KILL) rescue nil

    writer.join(1.0)  # Don't wait forever

    begin
      s.join(timeout: 1.0)
    rescue Umi::Proctor::Timeout
      # Force it
      s.kill(:KILL) rescue nil
      s.join(timeout: 0.5) rescue nil
    rescue => e
      errors << "join #{round}: #{e.class}"
    end
  end

  raise errors.join("; ") unless errors.empty?
  true
end

results << test("chaos: overlapping Proctors with random operations") do
  errors = []
  active = []

  50.times do |i|
    # Random operation
    case rand(4)
    when 0
      # Create new
      if active.size < 10
        begin
          s = Umi::Proctor.new("cat")
          s << "hello\n"
          active << s
        rescue => e
          errors << "create #{i}: #{e.class}"
        end
      end
    when 1
      # Write to random
      if s = active.sample
        begin
          s << "msg#{i}\n"
        rescue Umi::Proctor::ProcessExited
          active.delete(s)
        rescue => e
          errors << "write #{i}: #{e.class}"
        end
      end
    when 2
      # Read from random
      if s = active.sample
        begin
          s.pop_stdout!(0.1)
        rescue Umi::Proctor::ProcessExited
          active.delete(s)
        rescue Umi::Proctor::Timeout
          # Fine
        rescue => e
          errors << "read #{i}: #{e.class}"
        end
      end
    when 3
      # Kill random
      if s = active.sample
        begin
          s.kill(:KILL)
          s.join(timeout: 0.5)
        rescue
          # Ignore
        end
        active.delete(s)
      end
    end
  end

  # Cleanup remaining
  active.each do |s|
    begin
      s.close_stdin
      s.join(timeout: 0.5)
    rescue
      s.kill(:KILL) rescue nil
      s.join(timeout: 0.5) rescue nil
    end
  end

  raise errors.join("; ") unless errors.empty?
  true
end

# =============================================================================
# Buffer stress (regression tests for infinite loop bug)
# =============================================================================
puts "\n--- Buffer Stress (Regression) ---"

results << test("alternating pop_stdout!/pop_stderr!") do
  script = <<~RUBY
    $stdout.sync = true
    $stderr.sync = true
    5.times do |i|
      puts "out\#{i}"
      $stderr.puts "err\#{i}"
    end
  RUBY

  shellac = Umi::Proctor.new("ruby", "-e", script)

  # Alternate between pop_stdout! and pop_stderr!
  5.times do |i|
    out = shellac.pop_stdout!(2.0)
    assert out.include?("out"), "expected stdout, got #{out.inspect}"

    err = shellac.pop_stderr!(2.0)
    assert err.include?("err"), "expected stderr, got #{err.inspect}"
  end

  shellac.join(timeout: 1.0)
end

results << test("100 stderr before stdout (deep buffer)") do
  script = <<~RUBY
    $stdout.sync = true
    $stderr.sync = true
    100.times { |i| $stderr.puts "err\#{i}" }
    puts "stdout finally"
  RUBY

  shellac = Umi::Proctor.new("ruby", "-e", script)

  # Should find stdout despite 100 stderr messages buffered
  line = shellac.pop_stdout!(5.0)
  assert_equal "stdout finally\n", line

  shellac.join(timeout: 2.0)
end

results << test("output? with buffered messages") do
  script = <<~RUBY
    $stdout.sync = true
    $stderr.sync = true
    $stderr.puts "stderr first"
    puts "stdout second"
  RUBY

  shellac = Umi::Proctor.new("ruby", "-e", script)
  sleep 0.2  # Let both messages arrive

  # output? should return true even if first message is stderr
  assert shellac.output?, "should have output"

  line = shellac.pop_stdout!(1.0)
  assert_equal "stdout second\n", line

  shellac.join(timeout: 1.0)
end

results << test("peek does not consume message") do
  shellac = Umi::Proctor.new("echo", "peeked")
  sleep 0.1  # Let message arrive

  # Peek should show the message
  msg1 = shellac.peek
  assert msg1, "peek should return message"

  # Peek again should return same message
  msg2 = shellac.peek
  assert_equal msg1, msg2

  # Now consume it
  line = shellac.pop_stdout!(1.0)
  assert_equal "peeked\n", line

  shellac.join(timeout: 1.0)
end

results << test("stochastic interleaving (20 iterations)") do
  # The upcase fixture writes stderr randomly - stress test the fix
  20.times do |i|
    shellac = Umi::Proctor.new("#{FIXTURES}/upcase")
    shellac << "test#{i}\n"
    line = shellac.pop_stdout!(2.0)
    raise "expected TEST#{i}, got #{line.inspect}" unless line.chomp == "TEST#{i}"
    shellac.close_stdin
    shellac.join(timeout: 2.0)
  end
end

# =============================================================================
# Extreme timing scenarios
# =============================================================================
puts "\n--- Extreme Timing ---"

results << test("output-then-immediate-exit race") do
  # This exercises the race between stdout and process_died
  20.times do |i|
    script = "puts 'fast#{i}'"
    shellac = Umi::Proctor.new("ruby", "-e", script)

    # The process may have already exited
    begin
      line = shellac.pop_stdout!(1.0)
      raise "wrong output" unless line.chomp == "fast#{i}"
    rescue Umi::Proctor::ProcessExited
      # Also acceptable if we missed the output
    end

    shellac.join(timeout: 1.0) rescue nil
  end
end

results << test("slow drip with aggressive timeouts") do
  script = <<~RUBY
    $stdout.sync = true
    3.times { |i| sleep 0.1; puts i }
  RUBY

  shellac = Umi::Proctor.new("ruby", "-e", script)

  received = []
  6.times do
    begin
      # Very short timeout - will often miss
      line = shellac.pop_stdout!(0.05)
      received << line.chomp.to_i
    rescue Umi::Proctor::Timeout
      # Expected
    rescue Umi::Proctor::ProcessExited
      break
    end
  end

  shellac.join(timeout: 2.0) rescue nil
  # May have received 0, 1, 2, or 3 - all are valid
  true
end

results << test("mid-output hang recovery") do
  script = <<~RUBY
    $stdout.sync = true
    puts "before"
    sleep 10  # Hang
    puts "after"
  RUBY

  shellac = Umi::Proctor.new("ruby", "-e", script)

  # Get first line
  line = shellac.pop_stdout!(1.0)
  raise "wrong" unless line.chomp == "before"

  # Second line will timeout
  raised = false
  begin
    shellac.pop_stdout!(0.2)
  rescue Umi::Proctor::Timeout
    raised = true
  end

  # Kill it
  shellac.kill(:KILL)
  shellac.join(timeout: 1.0)

  assert raised, "should have timed out"
end

# =============================================================================
# Multi-threaded access
# =============================================================================
puts "\n--- Multi-threaded Access ---"

results << test("concurrent readers (same Proctor)") do
  errors = []

  shellac = Umi::Proctor.new("ruby", "-e", "10.times { |i| puts i; sleep 0.01 }")

  readers = 3.times.map do |r|
    Thread.new do
      5.times do
        begin
          shellac.pop_stdout!(0.5)
        rescue Umi::Proctor::ProcessExited, Umi::Proctor::Timeout
          # OK
        rescue => e
          errors << "reader #{r}: #{e.class}: #{e.message}"
        end
      end
    end
  end

  readers.each(&:join)
  shellac.join(timeout: 1.0) rescue nil

  raise errors.join("; ") unless errors.empty?
  true
end

results << test("concurrent writers (same Proctor)") do
  errors = []

  shellac = Umi::Proctor.new("cat")

  writers = 3.times.map do |w|
    Thread.new do
      5.times do |i|
        begin
          shellac << "writer#{w}-#{i}\n"
        rescue Umi::Proctor::ProcessExited
          # OK if killed
        rescue => e
          errors << "writer #{w}: #{e.class}: #{e.message}"
        end
        sleep 0.01
      end
    end
  end

  # Drain some output
  Thread.new do
    10.times do
      shellac.pop_stdout!(0.5) rescue nil
    end
  end

  writers.each(&:join)
  shellac.close_stdin
  shellac.join(timeout: 2.0)

  raise errors.join("; ") unless errors.empty?
  true
end

# =============================================================================
# Unusual I/O patterns
# =============================================================================
puts "\n--- Unusual I/O Patterns ---"

results << test("tiny chunks (1 byte at a time)") do
  script = <<~RUBY
    $stdout.sync = true
    "hello world\\n".each_char { |c| print c; $stdout.flush; sleep 0.001 }
  RUBY

  shellac = Umi::Proctor.new("ruby", "-e", script)

  # Should still receive as a complete line (gets behavior)
  line = shellac.pop_stdout!(2.0)
  raise "expected 'hello world', got #{line.inspect}" unless line.chomp == "hello world"

  shellac.join(timeout: 1.0)
end

results << test("partial line at exit (no final newline)") do
  shellac = Umi::Proctor.new("ruby", "-e", "print 'partial'")

  # May or may not receive the partial line
  begin
    line = shellac.pop_stdout!(1.0)
    # If we got it, great
  rescue Umi::Proctor::ProcessExited, Umi::Proctor::Timeout
    # Also OK
  end

  shellac.join(timeout: 1.0) rescue nil
  true
end

results << test("stdout buffer overflow simulation") do
  # Generate more data than typical buffer size
  shellac = Umi::Proctor.new("ruby", "-e", "puts 'x' * 100_000")

  line = shellac.pop_stdout!(5.0)
  raise "expected 100000 chars" unless line.bytesize > 99_000

  shellac.join(timeout: 1.0)
end

# =============================================================================
# Lifecycle edge cases
# =============================================================================
puts "\n--- Lifecycle Edge Cases ---"

results << test("double close_stdin") do
  shellac = Umi::Proctor.new("cat")
  shellac << "test\n"
  shellac.pop_stdout!(1.0)

  shellac.close_stdin
  shellac.close_stdin  # Should not raise

  shellac.join(timeout: 1.0)
end

results << test("write after close_stdin") do
  shellac = Umi::Proctor.new("cat")
  shellac.close_stdin

  raised = false
  begin
    shellac << "test\n"
  rescue Umi::Proctor::ProcessExited
    raised = true
  end

  shellac.join(timeout: 1.0) rescue nil
  # Should either raise or silently fail
  true
end

results << test("operations after join") do
  shellac = Umi::Proctor.new("true")
  shellac.join(timeout: 1.0)

  # All these should raise ProcessExited or be no-ops
  errors = []

  begin
    shellac << "test\n"
  rescue Umi::Proctor::ProcessExited
    # Expected
  rescue => e
    errors << "write: #{e.class}"
  end

  begin
    shellac.pop_stdout!(0.1)
  rescue Umi::Proctor::ProcessExited
    # Expected
  rescue => e
    errors << "pop_stdout!: #{e.class}"
  end

  begin
    shellac.kill(:TERM)
  rescue Umi::Proctor::ProcessExited
    # Expected
  rescue => e
    errors << "kill: #{e.class}"
  end

  raise errors.join("; ") unless errors.empty?
  true
end

results << test("join during active I/O") do
  shellac = Umi::Proctor.new("cat")

  # Start writing in background
  writer = Thread.new do
    100.times do |i|
      shellac << "line#{i}\n" rescue nil
      sleep 0.005
    end
  end

  # Let some writes happen
  sleep 0.05

  # Force join while writer is still going
  shellac.kill(:KILL)
  result = shellac.join(timeout: 2.0)

  writer.join(1.0)

  assert result.signaled?
end

# =============================================================================
# Signal edge cases
# =============================================================================
puts "\n--- Signal Edge Cases ---"

results << test("rapid signal spam") do
  shellac = Umi::Proctor.new("sleep", "10")

  # Spam signals
  5.times do
    shellac.kill(:USR1) rescue nil
    shellac.kill(:USR2) rescue nil
    sleep 0.01
  end

  shellac.kill(:KILL)
  result = shellac.join(timeout: 1.0)
  assert result.signaled?
end

results << test("SIGTERM ignored, fallback to KILL") do
  # Process that ignores TERM
  shellac = Umi::Proctor.new("#{FIXTURES}/term-ignorer")
  shellac.pop_stdout!(2.0)  # Wait for startup

  # stop() should TERM, timeout, then KILL
  result = shellac.stop(timeout: 0.5)

  # Should have been killed eventually
  assert result.signaled?
  assert_equal :KILL, result.signal
end

# =============================================================================
# Heisenbug hunting - timing-sensitive scenarios
# =============================================================================
puts "\n--- Heisenbug Hunting ---"

results << test("rapid stdin close/reopen simulation") do
  # Simulates connection drops - close stdin, start new Proctor
  20.times do |i|
    s = Umi::Proctor.new("cat")
    s << "test#{i}\n"

    # Random: either read or just kill
    if rand < 0.5
      s.pop_stdout!(0.5) rescue nil
    end

    # Random: either close gracefully or kill
    if rand < 0.5
      s.close_stdin
      s.join(timeout: 0.5) rescue nil
    else
      s.kill(:KILL)
      s.join(timeout: 0.5) rescue nil
    end
  end
end

results << test("message storm while shutting down") do
  10.times do
    script = <<~RUBY
      $stdout.sync = true
      loop { puts "spam" }
    RUBY

    s = Umi::Proctor.new("ruby", "-e", script)

    # Let it generate some output
    3.times { s.pop_stdout!(0.5) rescue nil }

    # Kill while messages are still flying
    s.kill(:KILL)

    # Join should not hang
    s.join(timeout: 2.0) rescue nil
  end
end

results << test("constructor/destructor race") do
  # Rapidly create and abandon Proctors
  shellacs = []

  30.times do
    s = Umi::Proctor.new("sleep", "0.01")
    shellacs << s if rand < 0.3  # Only keep some references
  end

  # Some will be GC'd, others we join
  shellacs.each do |s|
    s.join(timeout: 1.0) rescue nil
  end

  GC.start
  sleep 0.2

  # System should still work
  s = Umi::Proctor.new("echo", "still alive")
  line = s.pop_stdout!(1.0)
  assert_equal "still alive\n", line
  s.join(timeout: 1.0)
end

# =============================================================================
# Defective processes - processes that misbehave in various ways
# =============================================================================
puts "\n--- Defective Processes ---"

results << test("infinite stdout spam") do
  s = Umi::Proctor.new("#{FIXTURES}/infinite-stdout")

  # Read a few lines to verify it works
  5.times { s.pop_stdout!(1.0) }

  # Kill it - should not hang
  s.kill(:KILL)
  result = s.join(timeout: 2.0)
  assert result.signaled?
end

results << test("stdin blackhole (never outputs)") do
  s = Umi::Proctor.new("#{FIXTURES}/stdin-blackhole")

  # Write lots of data
  10.times { s << "data\n" }

  # pop_stdout! should timeout
  raised = false
  begin
    s.pop_stdout!(0.2)
  rescue Umi::Proctor::Timeout
    raised = true
  end

  s.kill(:KILL)
  s.join(timeout: 1.0)
  assert raised
end

results << test("delayed/unflushed stdout") do
  s = Umi::Proctor.new("#{FIXTURES}/delayed-stdout")

  # This process doesn't flush, so we might not get output
  raised = false
  begin
    s.pop_stdout!(0.5)
  rescue Umi::Proctor::Timeout
    raised = true
  end

  s.kill(:KILL)
  s.join(timeout: 1.0)
  # Either we got buffered output or we timed out - both are valid behaviors
  true
end

results << test("process with child processes") do
  s = Umi::Proctor.new("#{FIXTURES}/fork-bomb-lite")

  # Collect all output until process exits
  lines = []
  loop do
    begin
      lines << s.pop_stdout!(3.0)
    rescue Umi::Proctor::ProcessExited
      break
    rescue Umi::Proctor::Timeout
      # Still waiting - dump what we have for debugging
      raise "Timed out waiting for output. Got: #{lines.inspect}"
    end
  end

  s.join(timeout: 2.0)

  # We should see: parent, child0, child1, child2, done (in some order)
  assert lines.any? { |l| l.include?("parent") }, "missing 'parent' in #{lines.inspect}"
  assert lines.any? { |l| l.include?("done") }, "missing 'done' in #{lines.inspect}"
end

results << test("memory hog (allocates rapidly)") do
  s = Umi::Proctor.new("#{FIXTURES}/memory-hog")

  # Should get "starting"
  line = s.pop_stdout!(5.0)
  assert line.include?("starting"), "expected 'starting'"

  # Read some allocation messages
  5.times do
    begin
      s.pop_stdout!(2.0)
    rescue Umi::Proctor::ProcessExited
      break
    end
  end

  # Kill it (might still be allocating)
  s.kill(:KILL) rescue nil
  s.join(timeout: 2.0) rescue nil
  true
end

results << test("randomly crashing process (10 attempts)") do
  10.times do |i|
    s = Umi::Proctor.new("#{FIXTURES}/random-crash")

    # Read some ticks until it crashes or we've had enough
    ticks = 0
    loop do
      begin
        s.pop_stdout!(1.0)
        ticks += 1
        break if ticks >= 10  # Don't wait forever
      rescue Umi::Proctor::ProcessExited
        break
      rescue Umi::Proctor::Timeout
        break
      end
    end

    # Clean up
    begin
      s.join(timeout: 0.5)
    rescue Umi::Proctor::Timeout
      s.kill(:KILL)
      s.join(timeout: 0.5) rescue nil
    end
  end
end

results << test("process that exits during our write") do
  # Start a process that will exit quickly
  s = Umi::Proctor.new("ruby", "-e", "sleep 0.05; exit 0")

  # Try to write while it's dying
  sleep 0.03
  errors = []
  10.times do |i|
    begin
      s << "data#{i}\n"
    rescue Umi::Proctor::ProcessExited
      # Expected
    rescue => e
      errors << "#{e.class}: #{e.message}"
    end
    sleep 0.01
  end

  s.join(timeout: 1.0) rescue nil
  raise errors.join("; ") unless errors.empty?
  true
end

results << test("process closes its stdout early") do
  script = <<~RUBY
    $stdout.sync = true
    puts "hello"
    $stdout.close
    sleep 1  # Stay alive but stdout is closed
  RUBY

  s = Umi::Proctor.new("ruby", "-e", script)

  # Get the output before stdout closes
  line = s.pop_stdout!(1.0)
  assert_equal "hello\n", line

  # Next pop_stdout! should fail (stdout closed, process still alive)
  raised = false
  begin
    s.pop_stdout!(0.5)
  rescue Umi::Proctor::ProcessExited, Umi::Proctor::Timeout
    raised = true
  end

  s.kill(:KILL)
  s.join(timeout: 1.0)
  assert raised
end

# =============================================================================
# Concurrent Multi-Scenario (the big one)
# =============================================================================
puts "\n--- Concurrent Multi-Scenario ---"

results << test("simultaneous diverse shellacs (30 concurrent)") do
  errors = []
  threads = []

  # Define scenarios as procs
  scenarios = [
    -> {
      # Simple echo
      s = Umi::Proctor.new("cat")
      s << "hello\n"
      s.pop_stdout!(1.0)
      s.close_stdin
      s.join(timeout: 1.0)
    },
    -> {
      # Stochastic fixture
      s = Umi::Proctor.new("#{FIXTURES}/upcase")
      s << "test\n"
      s.pop_stdout!(2.0)
      s.close_stdin
      s.join(timeout: 1.0)
    },
    -> {
      # Fast exit
      s = Umi::Proctor.new("true")
      s.join(timeout: 1.0)
    },
    -> {
      # Killed process
      s = Umi::Proctor.new("sleep", "10")
      s.kill(:KILL)
      s.join(timeout: 1.0)
    },
    -> {
      # Timeout scenario
      s = Umi::Proctor.new("#{FIXTURES}/hang")
      begin
        s.pop_stdout!(0.1)
      rescue Umi::Proctor::Timeout
        # Expected
      end
      s.kill(:KILL)
      s.join(timeout: 1.0)
    },
    -> {
      # Counter (multi-shot)
      s = Umi::Proctor.new("#{FIXTURES}/counter")
      s << "x\n"
      s.pop_stdout!(1.0) rescue nil
      s.close_stdin
      s.join(timeout: 2.0)
    },
    -> {
      # Infinite stdout (killed)
      s = Umi::Proctor.new("#{FIXTURES}/infinite-stdout")
      s.pop_stdout!(0.5) rescue nil
      s.kill(:KILL)
      s.join(timeout: 1.0)
    },
    -> {
      # Random crasher
      s = Umi::Proctor.new("#{FIXTURES}/random-crash")
      3.times { s.pop_stdout!(0.5) rescue nil }
      s.kill(:KILL) rescue nil
      s.join(timeout: 1.0) rescue nil
    },
  ]

  # Spawn 30 threads, each running a random scenario
  30.times do |i|
    threads << Thread.new(i) do |thread_id|
      scenario = scenarios.sample
      begin
        scenario.call
      rescue => e
        errors << "thread#{thread_id}: #{e.class}: #{e.message}"
      end
    end
  end

  # Wait for all threads
  threads.each { |t| t.join(30) }  # 30 second per-thread timeout

  # Check for hung threads
  hung = threads.count(&:alive?)
  errors << "#{hung} threads still running" if hung > 0

  raise errors.join("; ") unless errors.empty?
  true
end

results << test("rapid scenario switching (100 iterations)") do
  errors = []

  100.times do |i|
    scenario = rand(5)
    begin
      case scenario
      when 0
        s = Umi::Proctor.new("echo", "test#{i}")
        s.pop_stdout!(1.0)
        s.join(timeout: 1.0)
      when 1
        s = Umi::Proctor.new("cat")
        s << "x\n"
        s.pop_stdout!(1.0)
        s.close_stdin
        s.join(timeout: 1.0)
      when 2
        s = Umi::Proctor.new("#{FIXTURES}/upcase")
        s << "hi\n"
        s.pop_stdout!(2.0)
        s.close_stdin
        s.join(timeout: 1.0)
      when 3
        s = Umi::Proctor.new("sleep", "10")
        s.kill(:KILL)
        s.join(timeout: 1.0)
      when 4
        s = Umi::Proctor.new("true")
        s.join(timeout: 1.0)
      end
    rescue Umi::Proctor::ProcessExited, Umi::Proctor::Timeout
      # OK
    rescue => e
      errors << "iter#{i}: #{e.class}: #{e.message}"
    end
  end

  raise errors.join("; ") unless errors.empty?
  true
end

results << test("concurrent reads and writes across shellacs") do
  errors = []
  shellacs = []

  # Create 5 cat processes
  5.times { shellacs << Umi::Proctor.new("cat") }

  # Spawn readers and writers
  threads = []

  # Writers
  5.times do |i|
    threads << Thread.new(shellacs[i], i) do |s, id|
      10.times do |j|
        begin
          s << "msg#{id}-#{j}\n"
        rescue Umi::Proctor::ProcessExited
          break
        rescue => e
          errors << "writer#{id}: #{e.class}"
          break
        end
        sleep 0.01
      end
    end
  end

  # Readers
  5.times do |i|
    threads << Thread.new(shellacs[i], i) do |s, id|
      10.times do
        begin
          s.pop_stdout!(0.5)
        rescue Umi::Proctor::ProcessExited, Umi::Proctor::Timeout
          break
        rescue => e
          errors << "reader#{id}: #{e.class}"
          break
        end
      end
    end
  end

  threads.each { |t| t.join(10) }

  # Cleanup
  shellacs.each do |s|
    s.close_stdin rescue nil
    s.join(timeout: 1.0) rescue nil
  end

  raise errors.join("; ") unless errors.empty?
  true
end

# =============================================================================
# Unexplored Edge Cases - Trying to break things
# =============================================================================
puts "\n--- Unexplored Edge Cases ---"

results << test("very long line (100KB single line)") do
  # Line longer than typical pipe buffer (64KB)
  long_line = "x" * 100_000
  script = "puts '#{long_line}'"

  s = Umi::Proctor.new("ruby", "-e", script)
  line = s.pop_stdout!(5.0)

  assert line.length > 99_000, "expected 100KB+ line, got #{line.length}"
  s.join(timeout: 1.0)
end

results << test("mixed line endings (CR, LF, CRLF)") do
  script = <<~RUBY
    $stdout.sync = true
    print "line1\\r\\n"  # CRLF
    print "line2\\n"     # LF
    print "line3\\r"     # CR only (not a line ending for gets)
    print "line4\\n"     # LF - should get "line3\\rline4"
  RUBY

  s = Umi::Proctor.new("ruby", "-e", script)

  lines = []
  3.times do
    case s.pop_stdout(1)
    in [:ok, line]
      lines << line.inspect  # Inspect to see control chars
    in [:closed, _] | nil
      break
    end
  end

  assert lines.length >= 2, "expected at least 2 lines"
  s.join(timeout: 1.0)
end

results << test("process exec()s into another process") do
  # Process replaces itself with exec
  script = <<~RUBY
    $stdout.sync = true
    puts "before_exec"
    $stdout.flush
    exec("echo", "after_exec")
  RUBY

  s = Umi::Proctor.new("ruby", "-e", script)

  lines = []
  2.times do
    case s.pop_stdout(2)
    in [:ok, line]
      lines << line.chomp
    in [:closed, _] | nil
      break
    end
  end

  assert lines.include?("before_exec"), "missing before_exec"
  assert lines.include?("after_exec"), "missing after_exec"
  s.join(timeout: 1.0)
end

results << test("concurrent pop and write from different threads") do
  s = Umi::Proctor.new("cat")
  errors = []

  writer = Thread.new do
    20.times do |i|
      begin
        s << "msg#{i}\n"
        sleep 0.01
      rescue Umi::Proctor::ProcessExited
        break
      rescue => e
        errors << "writer: #{e.class}: #{e.message}"
      end
    end
  end

  reader = Thread.new do
    received = 0
    20.times do
      begin
        s.pop_stdout!(1.0)
        received += 1
      rescue Umi::Proctor::Timeout, Umi::Proctor::ProcessExited
        break
      rescue => e
        errors << "reader: #{e.class}: #{e.message}"
      end
    end
    received
  end

  writer.join(5)
  s.close_stdin
  received = reader.value

  s.join(timeout: 2.0)

  raise errors.join("; ") unless errors.empty?
  assert received > 0, "should have received some messages"
end

results << test("concurrent pop and kill") do
  10.times do
    s = Umi::Proctor.new("cat")

    # Start a reader that will block
    reader = Thread.new do
      begin
        s.pop_stdout!(5.0)
      rescue Umi::Proctor::Timeout, Umi::Proctor::ProcessExited
        :expected
      end
    end

    # Kill while reader is blocking
    sleep 0.05
    s.kill(:KILL)

    # Reader should unblock without hanging
    result = reader.join(2)
    raise "reader hung after kill" unless result

    s.join(timeout: 1.0) rescue nil
  end
end

results << test("rapid pop/peek/output? interleaving") do
  s = Umi::Proctor.new("ruby", "-e", "10.times { |i| puts i; sleep 0.02 }")

  ops = []
  20.times do
    # Randomly choose operation
    case rand(3)
    when 0
      ops << [:peek, s.peek&.first]
    when 1
      ops << [:output?, s.output?]
    when 2
      case s.pop_stdout(0.05)
      in [:ok, line]
        ops << [:pop, line.chomp]
      in nil
        ops << [:pop, :timeout]
      in [:closed, _]
        ops << [:pop, :closed]
        break
      end
    end
  end

  # Should have gotten a mix of ops
  assert ops.length > 5, "expected multiple operations"

  s.kill(:KILL) rescue nil
  s.join(timeout: 1.0) rescue nil
end

results << test("stdin backpressure (write faster than process reads)") do
  # Process that reads slowly
  script = <<~RUBY
    while line = gets
      sleep 0.1  # Read very slowly
    end
  RUBY

  s = Umi::Proctor.new("ruby", "-e", script)

  # Try to flood stdin - pipe should buffer or block
  written = 0
  start = Time.now

  begin
    50.times do |i|
      s << ("x" * 1000 + "\n")  # 1KB per line
      written += 1
      break if Time.now - start > 1.0  # Don't spend too long
    end
  rescue Umi::Proctor::ProcessExited
    # OK
  end

  s.kill(:KILL)
  s.join(timeout: 1.0) rescue nil

  assert written > 0, "should have written some data"
end

results << test("SIGSTOP then SIGCONT") do
  s = Umi::Proctor.new("ruby", "-e", "$stdout.sync=true; 10.times { |i| puts i; sleep 0.1 }")

  # Get first line
  case s.pop_stdout(1)
  in [:ok, _]
    # good
  else
    raise "expected first line"
  end

  # Stop the process
  Process.kill("STOP", s.pid)
  sleep 0.1

  # Try to read - should timeout since process is stopped
  case s.pop_stdout(0.2)
  in nil
    # expected - process is stopped
  in [:ok, _]
    # also ok if data was already buffered
  in [:closed, _]
    raise "unexpected close"
  end

  # Resume the process
  Process.kill("CONT", s.pid)

  # Should be able to read again
  case s.pop_stdout(1)
  in [:ok, _]
    # good
  in [:closed, _]
    # also ok
  in nil
    raise "timeout after CONT"
  end

  s.kill(:KILL)
  s.join(timeout: 1.0) rescue nil
end

results << test("double join is safe") do
  s = Umi::Proctor.new("true")

  r1 = s.join(timeout: 1.0)
  r2 = s.join(timeout: 1.0)

  assert r1 == r2, "double join should return same result"
  assert r1.success?
end

results << test("operations after join raise ProcessExited") do
  s = Umi::Proctor.new("echo", "test")
  s.join(timeout: 2.0)

  # Write should raise
  raised = false
  begin
    s << "test\n"
  rescue Umi::Proctor::ProcessExited
    raised = true
  end
  assert raised, "write after join should raise"

  # pop should return :closed or raise
  case s.pop_stdout(0.1)
  in [:closed, _]
    # expected
  in nil
    # also ok
  else
    raise "unexpected result after join"
  end
end

results << test("GC during active Proctor") do
  shellacs = []

  # Create many shellacs
  10.times do
    s = Umi::Proctor.new("cat")
    s << "test\n"
    shellacs << s
  end

  # Force GC while they're active
  GC.start
  GC.start

  # They should still work
  shellacs.each do |s|
    line = s.pop_stdout!(1.0)
    assert_equal "test\n", line
    s.close_stdin
    s.join(timeout: 1.0)
  end
end

results << test("extremely short-lived process (pop before it starts)") do
  10.times do
    # Process exits almost instantly
    s = Umi::Proctor.new("true")

    # Immediately try operations
    case s.pop_stdout(0.5)
    in [:closed, result]
      assert result.success?
    in nil
      # Timeout is also acceptable
    in [:ok, _]
      raise "true should not produce output"
    end

    s.join(timeout: 1.0) rescue nil
  end
end

results << test("process that ignores SIGTERM (must SIGKILL)") do
  script = <<~RUBY
    trap("TERM") { }  # Ignore TERM
    $stdout.sync = true
    puts "started"
    sleep 100
  RUBY

  s = Umi::Proctor.new("ruby", "-e", script)
  s.pop_stdout!(1.0)  # Wait for startup

  # TERM should be ignored
  s.kill(:TERM)
  sleep 0.2

  assert s.alive?, "process should still be alive after ignored TERM"

  # KILL should work
  s.kill(:KILL)
  result = s.join(timeout: 2.0)

  assert result.signaled?
  assert_equal :KILL, result.signal
end

results << test("orphaned child process keeps writing") do
  # Parent forks, parent exits, child keeps writing
  script = <<~RUBY
    $stdout.sync = true
    if fork
      # Parent - exit immediately
      puts "parent"
      exit 0
    else
      # Child - keep writing
      3.times do |i|
        sleep 0.1
        puts "child\#{i}"
      end
    end
  RUBY

  s = Umi::Proctor.new("ruby", "-e", script)

  lines = []
  5.times do
    case s.pop_stdout(1)
    in [:ok, line]
      lines << line.chomp
    in [:closed, _] | nil
      break
    end
  end

  # Should see parent's output
  assert lines.include?("parent"), "missing parent output: #{lines.inspect}"

  # Child output may or may not be captured (depends on pipe inheritance)
  # This is actually testing edge behavior

  s.join(timeout: 2.0) rescue s.kill(:KILL)
end

results << test("Ractor watcher crash recovery") do
  s = Umi::Proctor.new("cat")
  s << "test\n"
  line = s.pop_stdout!(1.0)
  assert_equal "test\n", line

  # We can't easily crash the watcher Ractor from outside,
  # but we can verify the system handles normal shutdown
  s.close_stdin
  result = s.join(timeout: 2.0)
  assert result.success?
end

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
passed = results.count(true)
failed = results.count(false)
puts "Results: #{passed} passed, #{failed} failed"
puts "SEED=#{SEED}" if failed > 0  # Print seed on failure for reproduction
puts "=" * 60

$watchdog.kill  # Cancel watchdog
exit(failed > 0 ? 1 : 0)
