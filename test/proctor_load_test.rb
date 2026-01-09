#!/usr/bin/env ruby
# frozen_string_literal: true

# Load tests for Umi::Proctor
#
# These tests focus on concurrent behavior under load, especially:
# - Many proctors running simultaneously
# - Random kills during IO operations
# - Cleanup after forced termination (the shutdown path we fixed)
# - File descriptor exhaustion prevention
#
# Run with:
#   ruby test/proctor_load_test.rb
#   SEED=12345 ruby test/proctor_load_test.rb    # Reproduce
#   INTENSITY=high ruby test/proctor_load_test.rb # More aggressive
#
# These tests are designed to find race conditions and resource leaks.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'umi'
require 'tmpdir'
require 'fileutils'

# Reproducible randomness
SEED = (ENV['SEED'] || Random.new_seed).to_i
srand(SEED)

# Intensity levels affect counts and durations
INTENSITY = ENV.fetch('INTENSITY', 'normal')
MULTIPLIER = case INTENSITY
             when 'low' then 0.5
             when 'high' then 2.0
             when 'extreme' then 5.0
             else 1.0
             end

FIXTURES = File.expand_path('fixtures/processes', __dir__)

# Watchdog for hangs
WATCHDOG_TIMEOUT = (ENV['WATCHDOG_TIMEOUT'] || 180).to_i
$watchdog = Thread.new do
  sleep WATCHDOG_TIMEOUT
  warn "\n\n" + ("=" * 70)
  warn "WATCHDOG TIMEOUT (#{WATCHDOG_TIMEOUT}s) - Load test hung!"
  warn "SEED=#{SEED}  INTENSITY=#{INTENSITY}"
  warn "=" * 70
  Thread.list.each_with_index do |t, i|
    next if t == Thread.current
    warn "\n--- Thread #{i} [#{t.status || 'dead'}] ---"
    warn(t.backtrace&.first(15)&.join("\n") || "(no backtrace)")
  end
  warn "=" * 70
  exit! 1
end

Signal.trap("INT") do
  warn "\n\nInterrupted! SEED=#{SEED}"
  exit! 1
end

# Test helpers
$passed = 0
$failed = 0

def test(name)
  print "#{name}... "
  $stdout.flush
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  begin
    yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    puts "OK (#{elapsed.round(2)}s)"
    $passed += 1
    true
  rescue StandardError => e
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    puts "FAIL (#{elapsed.round(2)}s)"
    puts "  #{e.class}: #{e.message}"
    puts "  #{e.backtrace.first(5).join("\n  ")}"
    $failed += 1
    false
  end
end

def assert(cond, msg = "assertion failed")
  raise msg unless cond
end

def assert_equal(expected, actual)
  raise "expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

puts "=" * 70
puts "Umi::Proctor Load Tests"
puts "Ruby #{RUBY_VERSION}"
puts "SEED=#{SEED}  INTENSITY=#{INTENSITY}  MULTIPLIER=#{MULTIPLIER}"
puts "=" * 70
puts

# =============================================================================
# Test: Mass spawn and immediate kill
# =============================================================================
puts "--- Mass Spawn & Kill ---"

test("spawn #{(50 * MULTIPLIER).to_i} proctors and SIGKILL all") do
  count = (50 * MULTIPLIER).to_i
  proctors = count.times.map do
    Umi::Proctor.new("sleep", "60")
  end

  # Verify all started
  proctors.each { |p| assert p.alive?, "proctor should be alive" }

  # Kill all with SIGKILL
  proctors.each { |p| p.kill(:KILL) }

  # Join all with timeout
  proctors.each do |p|
    p.join(timeout: 2.0)
  rescue Umi::Proctor::Timeout
    raise "proctor failed to exit after SIGKILL"
  end

  # All should be exited
  proctors.each { |p| assert p.exited?, "proctor should be exited" }
end

test("spawn #{(50 * MULTIPLIER).to_i} proctors and SIGTERM all") do
  count = (50 * MULTIPLIER).to_i
  proctors = count.times.map do
    Umi::Proctor.new("sleep", "60")
  end

  proctors.each { |p| p.kill(:TERM) }
  proctors.each do |p|
    p.join(timeout: 2.0)
  rescue Umi::Proctor::Timeout
    p.kill(:KILL)
    p.join(timeout: 1.0)
  end

  proctors.each { |p| assert p.exited?, "proctor should be exited" }
end

test("spawn and stop (graceful) #{(30 * MULTIPLIER).to_i} proctors") do
  count = (30 * MULTIPLIER).to_i
  proctors = count.times.map do
    Umi::Proctor.new("cat")  # cat exits on stdin close
  end

  proctors.each(&:stop)
  proctors.each do |p|
    p.join(timeout: 3.0)
  rescue Umi::Proctor::Timeout
    raise "graceful stop timed out"
  end

  proctors.each { |p| assert p.exited?, "proctor should be exited" }
end

# =============================================================================
# Test: IO-heavy processes with random kills
# =============================================================================
puts "\n--- IO Heavy + Random Kills ---"

test("firehose producers killed at random times") do
  count = (15 * MULTIPLIER).to_i
  proctors = []
  threads = []
  errors = []

  # First: spawn all firehose processes
  # (Separating creation from reading avoids GVL contention during startup)
  count.times do
    proctors << Umi::Proctor.new("#{FIXTURES}/firehose")
  end

  # Then: start reader threads for each proctor
  # (Small stagger prevents thread creation burst from hitting OS limits)
  proctors.each_with_index do |p, i|
    threads << Thread.new(p, i) do |proctor, id|
      lines = 0
      loop do
        case proctor.pop_stdout(0.1)
        in [:ok, _]
          lines += 1
        in [:closed, _]
          break
        in nil
          # timeout, continue
        end
      end
    rescue StandardError => e
      errors << "reader #{id}: #{e.class}: #{e.message}"
    end
    sleep 0.005  # Stagger to avoid thread creation burst hitting OS limits
  end

  # Let them run briefly
  sleep 0.2

  # Kill them in random order with random signals
  signals = [:TERM, :KILL, :KILL, :KILL]  # Bias toward KILL
  proctors.shuffle.each_with_index do |p, i|
    sleep rand * 0.05  # Random delay
    sig = signals.sample
    p.kill(sig) rescue nil  # May already be exited
  end

  # Wait for all threads
  threads.each { |t| t.join(5) }

  # Join all proctors
  proctors.each do |p|
    p.join(timeout: 2.0)
  rescue Umi::Proctor::Timeout
    p.kill(:KILL)
    p.join(timeout: 1.0) rescue nil
  end

  assert errors.empty?, "Errors: #{errors.join(', ')}"
end

test("interleaved stdout/stderr with random kills") do
  count = (15 * MULTIPLIER).to_i
  proctors = []
  threads = []
  errors = []

  # Create all proctors first
  count.times do
    proctors << Umi::Proctor.new("#{FIXTURES}/interleaved")
  end

  # Then start readers with small stagger
  proctors.each_with_index do |p, i|
    threads << Thread.new(p, i) do |proctor, id|
      loop do
        case proctor.pop(0.1)
        in [:stdout, _] | [:stderr, _]
          # got output
        in [:closed, _]
          break
        in nil
          # timeout
        end
      end
    rescue StandardError => e
      errors << "#{id}: #{e.class}: #{e.message}"
    end
    sleep 0.005
  end

  sleep 0.1 + rand * 0.1

  # Kill in waves
  proctors.each_slice(5) do |batch|
    batch.each { |p| p.kill(:KILL) rescue nil }
    sleep 0.02
  end

  threads.each { |t| t.join(5) }
  proctors.each { |p| p.join(timeout: 2.0) rescue nil }

  assert errors.empty?, "Errors: #{errors.join(', ')}"
end

# =============================================================================
# Test: Temp directory IO with kills
# =============================================================================
puts "\n--- Temp Directory IO + Kills ---"

test("processes writing to temp files, killed mid-write") do
  Dir.mktmpdir("proctor_load_test") do |tmpdir|
    count = (20 * MULTIPLIER).to_i
    proctors = []

    # Spawn processes that write to files
    count.times do |i|
      outfile = File.join(tmpdir, "output_#{i}.txt")
      # Use shell to write continuously
      cmd = "while true; do echo line >> #{outfile}; done"
      p = Umi::Proctor.new("sh", "-c", cmd)
      proctors << p
    end

    # Let them write for a bit
    sleep 0.3

    # Kill all suddenly
    proctors.each { |p| p.kill(:KILL) }

    # Join with timeout
    proctors.each do |p|
      p.join(timeout: 2.0)
    rescue Umi::Proctor::Timeout
      raise "proctor didn't exit after SIGKILL"
    end

    # Verify files were created (at least some)
    files = Dir.glob(File.join(tmpdir, "output_*.txt"))
    assert files.length > 0, "expected some output files"

    # All proctors should be cleanly exited
    proctors.each { |p| assert p.exited?, "proctor should be exited" }
  end
end

test("processes reading from temp files, killed mid-read") do
  Dir.mktmpdir("proctor_load_test") do |tmpdir|
    # Create input files
    10.times do |i|
      File.write(File.join(tmpdir, "input_#{i}.txt"), "line\n" * 10000)
    end

    count = (15 * MULTIPLIER).to_i
    proctors = []
    threads = []
    errors = []

    count.times do |i|
      infile = File.join(tmpdir, "input_#{i % 10}.txt")
      p = Umi::Proctor.new("cat", infile)
      proctors << p

      threads << Thread.new(p, i) do |proctor, id|
        loop do
          case proctor.pop_stdout(0.5)
          in [:ok, _] then next
          in [:closed, _] then break
          in nil then next
          end
        end
      rescue StandardError => e
        errors << "#{id}: #{e.class}: #{e.message}"
      end
    end

    sleep 0.05

    # Kill half with TERM, half with KILL
    proctors.each_with_index do |p, i|
      p.kill(i.even? ? :TERM : :KILL) rescue nil  # May already be exited
    end

    threads.each { |t| t.join(5) }
    proctors.each { |p| p.join(timeout: 2.0) rescue nil }

    assert errors.empty?, "Errors: #{errors.join(', ')}"
  end
end

# =============================================================================
# Test: Proctor.select with multiple active proctors
# =============================================================================
puts "\n--- Proctor.select Under Load ---"

test("select across #{(30 * MULTIPLIER).to_i} producing proctors") do
  count = (30 * MULTIPLIER).to_i
  proctors = count.times.map do |i|
    # Drip produces output slowly
    Umi::Proctor.new("#{FIXTURES}/drip")
  end

  received = 0
  deadline = Time.now + 3

  while Time.now < deadline
    active = proctors.reject(&:exited?)
    break if active.empty?

    case Umi::Proctor.select(*active, timeout: 0.5)
    in [proctor, [:stdout, _]]
      received += 1
    in [proctor, [:stderr, _]]
      received += 1  # stderr counts too
    in [proctor, [:closed, _]]
      # done
    in nil
      # timeout
    end
  end

  # Kill remaining
  proctors.each { |p| p.kill(:KILL) unless p.exited? }
  proctors.each { |p| p.join(timeout: 1.0) rescue nil }

  assert received > 0, "should have received some output"
end

test("select with proctors being killed during select") do
  count = (20 * MULTIPLIER).to_i
  proctors = count.times.map { Umi::Proctor.new("#{FIXTURES}/firehose") }
  errors = []

  # Killer thread
  killer = Thread.new do
    sleep 0.1
    proctors.shuffle.each do |p|
      sleep rand * 0.02
      p.kill(:KILL) rescue nil
    end
  end

  # Select loop
  deadline = Time.now + 3
  while Time.now < deadline
    active = proctors.reject(&:exited?)
    break if active.empty?

    begin
      Umi::Proctor.select(*active, timeout: 0.1)
    rescue StandardError => e
      errors << e.message
    end
  end

  killer.join(5)
  proctors.each { |p| p.join(timeout: 1.0) rescue nil }

  # Some errors might be expected, but shouldn't crash
  proctors.each { |p| assert p.exited?, "all proctors should exit" }
end

# =============================================================================
# Test: Child processes inheriting file descriptors (the scenario we fixed)
# =============================================================================
puts "\n--- Child FD Inheritance (Shutdown Fix) ---"

test("git clone simulation - child processes with inherited FDs") do
  # Simulate git spawning child processes that inherit stdout/stderr
  count = (10 * MULTIPLIER).to_i
  proctors = []
  errors = []

  count.times do |i|
    # Shell spawns a subprocess that also writes to stdout
    cmd = <<~SH
      echo "parent start"
      (sleep 0.2; echo "child output") &
      echo "parent end"
      wait
    SH
    p = Umi::Proctor.new("sh", "-c", cmd)
    proctors << p
  end

  # Read some output then kill
  proctors.each do |p|
    2.times { p.pop_stdout(0.5) rescue nil }
    p.kill(:KILL)
  end

  # This is where we used to hang - join should complete
  start = Time.now
  proctors.each do |p|
    begin
      p.join(timeout: 2.0)
    rescue Umi::Proctor::Timeout
      errors << "join timed out"
    end
  end
  elapsed = Time.now - start

  assert errors.empty?, "Errors: #{errors.join(', ')}"
  assert elapsed < 5, "joins took too long: #{elapsed}s (should be <5s)"
end

test("fork-bomb-lite killed during fork") do
  count = (8 * MULTIPLIER).to_i
  proctors = count.times.map { Umi::Proctor.new("#{FIXTURES}/fork-bomb-lite") }

  sleep 0.2  # Let them fork

  proctors.each { |p| p.kill(:KILL) }

  start = Time.now
  proctors.each { |p| p.join(timeout: 3.0) rescue nil }
  elapsed = Time.now - start

  assert elapsed < 10, "cleanup took too long: #{elapsed}s"
  proctors.each { |p| assert p.exited?, "proctor should be exited" }
end

# =============================================================================
# Test: Rapid create/destroy cycles
# =============================================================================
puts "\n--- Rapid Create/Destroy Cycles ---"

test("#{(100 * MULTIPLIER).to_i} rapid create/kill/join cycles") do
  count = (100 * MULTIPLIER).to_i
  errors = []

  count.times do |i|
    p = Umi::Proctor.new("echo", "cycle #{i}")
    p.kill(:KILL)
    begin
      p.join(timeout: 2.0)
    rescue StandardError => e
      errors << "cycle #{i}: #{e.message}"
    end
  end

  assert errors.length < count * 0.01, "Too many errors: #{errors.length}/#{count}"
end

test("#{(50 * MULTIPLIER).to_i} create/read/kill cycles") do
  count = (50 * MULTIPLIER).to_i
  errors = []

  count.times do |i|
    p = Umi::Proctor.new("echo", "output #{i}")
    begin
      case p.pop_stdout(1.0)
      in [:ok, line]
        assert line.include?("output #{i}"), "wrong output"
      in [:closed, _]
        # OK, fast exit
      in nil
        errors << "cycle #{i}: timeout"
      end
    rescue StandardError => e
      errors << "cycle #{i}: #{e.message}"
    ensure
      p.kill(:KILL) rescue nil
      p.join(timeout: 1.0) rescue nil
    end
  end

  assert errors.empty?, "Errors: #{errors.first(5).join(', ')}"
end

# =============================================================================
# Test: Mixed scenarios simultaneously
# =============================================================================
puts "\n--- Mixed Chaos ---"

test("#{(50 * MULTIPLIER).to_i} threads doing random operations") do
  thread_count = (50 * MULTIPLIER).to_i
  errors = Ractor.make_shareable([])  # Thread-safe array alternative
  errors_mutex = Mutex.new

  scenarios = [
    # Quick echo
    -> {
      p = Umi::Proctor.new("echo", "hello")
      p.pop_stdout(1.0)
      p.join(timeout: 1.0)
    },
    # Cat with input
    -> {
      p = Umi::Proctor.new("cat")
      p << "test\n"
      p.pop_stdout(1.0)
      p.close_stdin
      p.join(timeout: 1.0)
    },
    # Sleep killed
    -> {
      p = Umi::Proctor.new("sleep", "10")
      sleep rand * 0.1
      p.kill([:TERM, :KILL].sample)
      p.join(timeout: 2.0)
    },
    # Firehose burst
    -> {
      p = Umi::Proctor.new("#{FIXTURES}/firehose")
      5.times { p.pop_stdout(0.1) rescue nil }
      p.kill(:KILL)
      p.join(timeout: 1.0)
    },
    # Timeout scenario
    -> {
      p = Umi::Proctor.new("#{FIXTURES}/hang")
      p.pop_stdout(0.05) rescue nil
      p.kill(:KILL)
      p.join(timeout: 1.0)
    },
    # Multiple outputs
    -> {
      p = Umi::Proctor.new("#{FIXTURES}/counter")
      3.times do
        p << "x\n"
        p.pop_stdout(0.5) rescue nil
      end
      p.close_stdin
      p.join(timeout: 2.0) rescue nil
    }
  ]

  threads = thread_count.times.map do |i|
    Thread.new(i) do |id|
      scenario = scenarios.sample
      begin
        scenario.call
      rescue StandardError => e
        errors_mutex.synchronize { errors << "#{id}: #{e.class}: #{e.message}" }
      end
    end
  end

  threads.each { |t| t.join(30) }

  assert errors.empty?, "Errors: #{errors.first(5).join('; ')}"
end

# =============================================================================
# Test: Watcher Ractor termination vs process kill
# =============================================================================
puts "\n--- Watcher Ractor vs Process Termination ---"

# These tests distinguish between:
# - kill(:TERM/:KILL) - sends signal to the external process
# - stop() - graceful shutdown: closes stdin, sends TERM, then KILL after timeout
# - The watcher Ractor shutting down (via :shutdown message during join/cleanup)

test("process kill vs watcher shutdown timing") do
  count = (15 * MULTIPLIER).to_i
  errors = []

  # Scenario 1: Kill process, then let watcher clean up via join
  count.times do |i|
    p = Umi::Proctor.new("sleep", "60")
    p.kill(:KILL)  # Kill the external process
    # join() will receive [:process_died], then send :shutdown to watcher
    begin
      p.join(timeout: 2.0)
    rescue StandardError => e
      errors << "scenario1-#{i}: #{e.message}"
    end
    assert p.exited?, "proctor should show exited"
  end

  # Scenario 2: Just call stop() - it handles both process and watcher
  count.times do |i|
    p = Umi::Proctor.new("cat")  # cat waits for stdin
    begin
      p.stop(timeout: 2.0)  # Graceful: close stdin, wait, escalate to KILL
    rescue StandardError => e
      errors << "scenario2-#{i}: #{e.message}"
    end
    assert p.exited?, "proctor should show exited"
  end

  # Scenario 3: Kill process while actively reading, then cleanup
  count.times do |i|
    p = Umi::Proctor.new("#{FIXTURES}/firehose")
    # Start reading
    p.pop_stdout(0.1) rescue nil
    # Kill while read might be happening
    p.kill(:KILL)
    begin
      p.join(timeout: 2.0)
    rescue StandardError => e
      errors << "scenario3-#{i}: #{e.message}"
    end
  end

  assert errors.empty?, "Errors: #{errors.join(', ')}"
end

test("watcher cleanup with blocked IO threads") do
  # This specifically tests the scenario we fixed:
  # - Process spawns children that inherit FDs
  # - Parent process is killed
  # - Children keep FDs open
  # - Watcher's IO threads are blocked on gets()
  # - :shutdown triggers IO close which unblocks threads

  count = (10 * MULTIPLIER).to_i
  errors = []

  count.times do |i|
    # Shell that spawns a background child
    cmd = <<~SH
      (sleep 5 &)  # Background child that inherits stdout
      echo "parent"
      sleep 60     # Parent blocks
    SH
    p = Umi::Proctor.new("sh", "-c", cmd)

    # Read the parent output
    case p.pop_stdout(1.0)
    in [:ok, line]
      assert line.strip == "parent", "unexpected output"
    in other
      errors << "#{i}: unexpected #{other.inspect}"
    end

    # Kill parent - but child still has FDs open!
    p.kill(:KILL)

    # This should NOT hang - our fix closes IOs before joining threads
    start = Time.now
    begin
      p.join(timeout: 3.0)
    rescue Umi::Proctor::Timeout
      errors << "#{i}: join timed out (watcher cleanup hung)"
    end
    elapsed = Time.now - start

    if elapsed > 2.5
      errors << "#{i}: join was slow (#{elapsed.round(2)}s)"
    end
  end

  assert errors.empty?, "Errors: #{errors.join(', ')}"
end

test("rapid stop() calls (watcher shutdown path)") do
  # stop() is the clean way to terminate - it:
  # 1. Closes stdin
  # 2. Sends SIGTERM
  # 3. Waits briefly
  # 4. Sends SIGKILL if needed
  # 5. Joins (which shuts down watcher)

  count = (30 * MULTIPLIER).to_i
  errors = []

  threads = count.times.map do |i|
    Thread.new(i) do |id|
      p = Umi::Proctor.new("sleep", "60")
      begin
        p.stop(timeout: 2.0)
      rescue StandardError => e
        errors << "#{id}: #{e.message}"
      end
    end
  end

  threads.each { |t| t.join(10) }

  assert errors.empty?, "Errors: #{errors.join(', ')}"
end

test("abandoned proctors (no explicit cleanup)") do
  # When proctors go out of scope without explicit cleanup, the finalizer
  # should shut down the watcher Ractor, preventing FD leaks.

  fd_before = Dir.entries("/dev/fd").length rescue 50

  5.times do
    # Create and abandon
    _p = Umi::Proctor.new("sleep", "60")
    # Don't call stop, kill, or join - just let it go out of scope
  end

  # Force GC to trigger finalizers
  GC.start
  sleep 0.3
  GC.start

  fd_after = Dir.entries("/dev/fd").length rescue 50
  leak = fd_after - fd_before

  # With finalizer working, FDs should return to baseline (small variance OK)
  assert leak < 10, "FD leak: #{leak} (before=#{fd_before}, after=#{fd_after}) - finalizer may not be working"
end

test("process dies naturally vs killed") do
  errors = []

  # Process exits on its own
  10.times do |i|
    p = Umi::Proctor.new("true")  # Exits immediately with 0
    begin
      result = p.join(timeout: 2.0)
      assert result.success?, "true should exit successfully"
    rescue StandardError => e
      errors << "natural-#{i}: #{e.message}"
    end
  end

  # Process exits with error
  10.times do |i|
    p = Umi::Proctor.new("false")  # Exits immediately with 1
    begin
      result = p.join(timeout: 2.0)
      assert !result.success?, "false should exit with error"
      assert_equal 1, result.exit_code
    rescue StandardError => e
      errors << "error-#{i}: #{e.message}"
    end
  end

  # Process killed by signal
  10.times do |i|
    p = Umi::Proctor.new("sleep", "60")
    p.kill(:KILL)
    begin
      result = p.join(timeout: 2.0)
      assert !result.success?, "killed process should not be success"
      # Signal can be string or symbol depending on Ruby version
      assert result.signal.to_s == "KILL", "expected KILL signal, got #{result.signal.inspect}"
    rescue StandardError => e
      errors << "killed-#{i}: #{e.message}"
    end
  end

  assert errors.empty?, "Errors: #{errors.join(', ')}"
end

# =============================================================================
# Test: File descriptor exhaustion prevention
# =============================================================================
puts "\n--- Resource Leak Prevention ---"

test("no FD leak after #{(100 * MULTIPLIER).to_i} proctors") do
  count = (100 * MULTIPLIER).to_i

  # Get baseline FD count (approximate via /dev/fd)
  fd_count_before = Dir.entries("/dev/fd").length rescue 50

  count.times do
    p = Umi::Proctor.new("echo", "test")
    p.pop_stdout(1.0) rescue nil
    p.join(timeout: 1.0) rescue nil
  end

  # Force GC to clean up
  GC.start
  sleep 0.1

  fd_count_after = Dir.entries("/dev/fd").length rescue 50

  # Allow some variance but not proportional to count
  max_leak = 20
  actual_leak = fd_count_after - fd_count_before
  assert actual_leak < max_leak,
         "FD leak detected: before=#{fd_count_before} after=#{fd_count_after} (#{actual_leak} leaked)"
end

# =============================================================================
# Summary
# =============================================================================

$watchdog.kill

puts
puts "=" * 70
puts "Results: #{$passed} passed, #{$failed} failed"
puts "SEED=#{SEED}  (use this to reproduce)"
puts "=" * 70

exit($failed > 0 ? 1 : 0)
