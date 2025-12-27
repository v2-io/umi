#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic tests for Umi::Proctor

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

puts "=" * 60
puts "Umi::Proctor Tests"
puts "Ruby #{RUBY_VERSION}"
puts "=" * 60
puts

results = []

# =============================================================================
# Basic I/O
# =============================================================================
puts "--- Basic I/O ---"

results << test("echo with cat") do
  proctor = Umi::Proctor.new("cat")
  proctor << "hello\n"
  line = proctor.pop_stdout!
  assert_equal "hello\n", line

  proctor << "world\n"
  line = proctor.pop_stdout!
  assert_equal "world\n", line

  proctor.close_stdin
  result = proctor.join
  assert result.success?
end

results << test("echo fixture with jitter") do
  proctor = Umi::Proctor.new("#{FIXTURES}/echo")
  proctor << "test line\n"
  line = proctor.pop_stdout!
  assert_equal "test line\n", line
  proctor.close_stdin
  result = proctor.join
  assert result.success?
end

results << test("upcase fixture") do
  proctor = Umi::Proctor.new("#{FIXTURES}/upcase")
  proctor << "hello\n"
  line = proctor.pop_stdout!
  assert_equal "HELLO\n", line
  proctor.close_stdin
  proctor.join
end

# =============================================================================
# Process lifecycle
# =============================================================================
puts "\n--- Process Lifecycle ---"

results << test("exit code 0") do
  proctor = Umi::Proctor.new("true")
  result = proctor.join
  assert result.success?
  assert_equal 0, result.exit_code
end

results << test("exit code non-zero") do
  proctor = Umi::Proctor.new("#{FIXTURES}/exit-code", "42")
  result = proctor.join
  assert !result.success?
  assert_equal 42, result.exit_code
end

results << test("on_exit callback") do
  proctor = Umi::Proctor.new("#{FIXTURES}/exit-code", "7")
  callback_called = false
  callback_result = nil

  proctor.on_exit do |result|
    callback_called = true
    callback_result = result
  end

  proctor.join
  assert callback_called, "callback was not called"
  assert_equal 7, callback_result.exit_code
end

results << test("alive? and exited?") do
  proctor = Umi::Proctor.new("sleep", "0.1")
  assert proctor.alive?
  assert !proctor.exited?

  proctor.join
  assert !proctor.alive?
  assert proctor.exited?
end

# =============================================================================
# Signals
# =============================================================================
puts "\n--- Signals ---"

results << test("kill with TERM") do
  proctor = Umi::Proctor.new("sleep", "100")
  assert proctor.alive?

  proctor.kill(:TERM)
  result = proctor.join(timeout: 2.0)

  assert result.signaled?
  assert_equal :TERM, result.signal  # Signal.signame returns "TERM", not "SIGTERM"
end

results << test("stop (graceful shutdown)") do
  proctor = Umi::Proctor.new("#{FIXTURES}/term-catcher")
  proctor.pop_stdout!  # Wait for startup message

  result = proctor.stop(timeout: 2.0)
  assert_equal 0, result.exit_code  # term-catcher exits cleanly
end

# =============================================================================
# Timeout
# =============================================================================
puts "\n--- Timeout ---"

results << test("pop_stdout! timeout") do
  proctor = Umi::Proctor.new("#{FIXTURES}/hang")

  raised = false
  begin
    proctor.pop_stdout!(0.2)
  rescue Umi::Proctor::Timeout
    raised = true
  end

  assert raised, "Timeout was not raised"
  proctor.kill(:KILL)
  proctor.join(timeout: 1.0)
end

results << test("join timeout") do
  proctor = Umi::Proctor.new("sleep", "100")

  raised = false
  begin
    proctor.join(timeout: 0.2)
  rescue Umi::Proctor::Timeout
    raised = true
  end

  assert raised, "Timeout was not raised"
  proctor.kill(:KILL)
  proctor.join(timeout: 1.0)
end

# =============================================================================
# Multi-shot (conversation)
# =============================================================================
puts "\n--- Multi-shot ---"

results << test("counter fixture") do
  proctor = Umi::Proctor.new("#{FIXTURES}/counter")

  proctor << "a\n"

  # Counter may emit [tick] before the count, so collect until we see a count
  lines = []
  3.times do
    begin
      line = proctor.pop_stdout!(1.0)
      lines << line
      break if line.include?("1:")
    rescue Umi::Proctor::Timeout
      break
    end
  end

  assert lines.any? { |l| l.include?("1:") }, "expected '1:' in #{lines.inspect}"

  proctor.close_stdin
  proctor.join(timeout: 2.0)
end

results << test("dot multi-shot") do
  proctor = Umi::Proctor.new("dot", "-Tplain")

  # Send first graph
  proctor << "digraph G1 { A -> B; }\n"
  lines1 = []
  loop do
    line = proctor.pop_stdout!(2.0)
    lines1 << line
    break if line.strip == "stop"
  end
  assert lines1.any? { |l| l.include?("node") }, "no nodes in output"

  # Send second graph
  proctor << "digraph G2 { X -> Y -> Z; }\n"
  lines2 = []
  loop do
    line = proctor.pop_stdout!(2.0)
    lines2 << line
    break if line.strip == "stop"
  end
  assert lines2.length > lines1.length, "second graph should have more nodes"

  proctor.close_stdin
  result = proctor.join
  assert result.success?
end

# =============================================================================
# stderr
# =============================================================================
puts "\n--- stderr ---"

results << test("stderr to stdout with merge mode") do
  # Use upcase fixture which occasionally writes to stderr
  proctor = Umi::Proctor.new("#{FIXTURES}/upcase", stderr: :merge)

  proctor << "hello\n"

  # Collect output until we see HELLO (may get stderr debug first)
  lines = []
  3.times do
    begin
      line = proctor.pop_stdout!(0.5)
      lines << line
      break if line.include?("HELLO")
    rescue Umi::Proctor::Timeout, Umi::Proctor::ProcessExited
      break
    end
  end

  assert lines.any? { |l| l.include?("HELLO") }, "expected HELLO in output, got #{lines.inspect}"

  proctor.close_stdin
  proctor.join(timeout: 1.0)
end

# =============================================================================
# Ergonomics
# =============================================================================
puts "\n--- Ergonomics ---"

results << test("block form (open)") do
  # Use echo instead of drip for speed
  result = Umi::Proctor.open("cat") do |s|
    s << "hello\n"
    line = s.pop_stdout!(1.0)
    assert_equal "hello\n", line
    s.close_stdin
  end

  assert result.is_a?(Umi::Proctor::Result), "expected Result, got #{result.class}"
  assert result.success?
end

results << test("each_line enumeration") do
  # Use a simple echo that sends 3 lines and exits
  proctor = Umi::Proctor.new("ruby", "-e", "3.times { |i| puts i }")
  lines = []

  proctor.each_line(timeout: 2.0) do |line|
    lines << line.chomp
  end

  assert_equal ["0", "1", "2"], lines
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
