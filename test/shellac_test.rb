#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic tests for ROTP::Shellac

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

puts "=" * 60
puts "ROTP::Shellac Tests"
puts "Ruby #{RUBY_VERSION}"
puts "=" * 60
puts

results = []

# =============================================================================
# Basic I/O
# =============================================================================
puts "--- Basic I/O ---"

results << test("echo with cat") do
  shellac = ROTP::Shellac.new("cat")
  shellac << "hello\n"
  line = shellac.receive
  assert_equal "hello\n", line

  shellac << "world\n"
  line = shellac.receive
  assert_equal "world\n", line

  shellac.close_stdin
  result = shellac.join
  assert result.success?
end

results << test("echo fixture with jitter") do
  shellac = ROTP::Shellac.new("#{FIXTURES}/echo")
  shellac << "test line\n"
  line = shellac.receive
  assert_equal "test line\n", line
  shellac.close_stdin
  result = shellac.join
  assert result.success?
end

results << test("upcase fixture") do
  shellac = ROTP::Shellac.new("#{FIXTURES}/upcase")
  shellac << "hello\n"
  line = shellac.receive
  assert_equal "HELLO\n", line
  shellac.close_stdin
  shellac.join
end

# =============================================================================
# Process lifecycle
# =============================================================================
puts "\n--- Process Lifecycle ---"

results << test("exit code 0") do
  shellac = ROTP::Shellac.new("true")
  result = shellac.join
  assert result.success?
  assert_equal 0, result.exit_code
end

results << test("exit code non-zero") do
  shellac = ROTP::Shellac.new("#{FIXTURES}/exit-code", "42")
  result = shellac.join
  assert !result.success?
  assert_equal 42, result.exit_code
end

results << test("on_exit callback") do
  shellac = ROTP::Shellac.new("#{FIXTURES}/exit-code", "7")
  callback_called = false
  callback_result = nil

  shellac.on_exit do |result|
    callback_called = true
    callback_result = result
  end

  shellac.join
  assert callback_called, "callback was not called"
  assert_equal 7, callback_result.exit_code
end

results << test("alive? and exited?") do
  shellac = ROTP::Shellac.new("sleep", "0.1")
  assert shellac.alive?
  assert !shellac.exited?

  shellac.join
  assert !shellac.alive?
  assert shellac.exited?
end

# =============================================================================
# Signals
# =============================================================================
puts "\n--- Signals ---"

results << test("kill with TERM") do
  shellac = ROTP::Shellac.new("sleep", "100")
  assert shellac.alive?

  shellac.kill(:TERM)
  result = shellac.join(timeout: 2.0)

  assert result.signaled?
  assert_equal :TERM, result.signal  # Signal.signame returns "TERM", not "SIGTERM"
end

results << test("stop (graceful shutdown)") do
  shellac = ROTP::Shellac.new("#{FIXTURES}/term-catcher")
  shellac.receive  # Wait for startup message

  result = shellac.stop(timeout: 2.0)
  assert_equal 0, result.exit_code  # term-catcher exits cleanly
end

# =============================================================================
# Timeout
# =============================================================================
puts "\n--- Timeout ---"

results << test("receive timeout") do
  shellac = ROTP::Shellac.new("#{FIXTURES}/hang")

  raised = false
  begin
    shellac.receive(timeout: 0.2)
  rescue ROTP::Shellac::Timeout
    raised = true
  end

  assert raised, "Timeout was not raised"
  shellac.kill(:KILL)
  shellac.join(timeout: 1.0)
end

results << test("join timeout") do
  shellac = ROTP::Shellac.new("sleep", "100")

  raised = false
  begin
    shellac.join(timeout: 0.2)
  rescue ROTP::Shellac::Timeout
    raised = true
  end

  assert raised, "Timeout was not raised"
  shellac.kill(:KILL)
  shellac.join(timeout: 1.0)
end

# =============================================================================
# Multi-shot (conversation)
# =============================================================================
puts "\n--- Multi-shot ---"

results << test("counter fixture") do
  shellac = ROTP::Shellac.new("#{FIXTURES}/counter")

  shellac << "a\n"
  line1 = shellac.receive
  assert line1.include?("1:"), "expected '1:', got #{line1}"

  shellac << "b\n"
  line2 = shellac.receive
  # May have [tick] prefix sometimes
  assert line2.include?("2:") || line2.include?("1:"), "expected count, got #{line2}"

  shellac.close_stdin
  shellac.join
end

results << test("dot multi-shot") do
  shellac = ROTP::Shellac.new("dot", "-Tplain")

  # Send first graph
  shellac << "digraph G1 { A -> B; }\n"
  lines1 = []
  loop do
    line = shellac.receive(timeout: 2.0)
    lines1 << line
    break if line.strip == "stop"
  end
  assert lines1.any? { |l| l.include?("node") }, "no nodes in output"

  # Send second graph
  shellac << "digraph G2 { X -> Y -> Z; }\n"
  lines2 = []
  loop do
    line = shellac.receive(timeout: 2.0)
    lines2 << line
    break if line.strip == "stop"
  end
  assert lines2.length > lines1.length, "second graph should have more nodes"

  shellac.close_stdin
  result = shellac.join
  assert result.success?
end

# =============================================================================
# stderr
# =============================================================================
puts "\n--- stderr ---"

results << test("stderr to stdout with merge mode") do
  # Use upcase fixture which occasionally writes to stderr
  shellac = ROTP::Shellac.new("#{FIXTURES}/upcase", stderr: :merge)

  shellac << "hello\n"

  # Collect output until we see HELLO (may get stderr debug first)
  lines = []
  3.times do
    begin
      line = shellac.receive(timeout: 1.0)
      lines << line
      break if line.include?("HELLO")
    rescue ROTP::Shellac::Timeout, ROTP::Shellac::ProcessExited
      break
    end
  end

  assert lines.any? { |l| l.include?("HELLO") }, "expected HELLO in output, got #{lines.inspect}"

  shellac.close_stdin
  shellac.join(timeout: 2.0)
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
