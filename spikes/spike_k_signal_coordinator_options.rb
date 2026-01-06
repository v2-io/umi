#!/usr/bin/env ruby
# frozen_string_literal: true

# spike_k_signal_coordinator_options.rb
#
# PURPOSE: Test architectural options for signal handling with coordinator.
#
# QUESTION: Should the coordinator be the main Ractor, or a child Ractor?
#
# CONSTRAINTS (from docs):
# 1. Signal handlers always execute in main Ractor context
# 2. Only port creator can receive from that port
# 3. Thread::Queue#push is signal-safe (explicitly documented)
# 4. Ractor::Port#send appears signal-safe (tested in spike_j)
#
# OPTIONS TO TEST:
# A. Coordinator IS main Ractor (current documented pattern)
# B. Coordinator is child, main Ractor relays via Queue
# C. Coordinator is child, signal handler sends directly to coordinator's port

require "bundler/setup"

puts "Ruby #{RUBY_VERSION}"
puts "=" * 70
puts "Signal + Coordinator Architecture Options"
puts "=" * 70
puts

$results = []

def test(name)
  print "#{name}... "
  $stdout.flush
  begin
    result = yield
    if result
      puts "[PASS]"
      $results << [name, :pass]
    else
      puts "[FAIL]"
      $results << [name, :fail]
    end
  rescue => e
    puts "[ERROR] #{e.class}: #{e.message}"
    puts e.backtrace.first(3).map { "  #{_1}" }.join("\n")
    $results << [name, :error, e]
  end
end

def receive_with_timeout(port, timeout)
  timer = Ractor::Port.new
  Thread.new(timer, timeout) { |t, to| sleep to; t << :timeout rescue nil }
  ready, val = Ractor.select(timer, port)
  ready == port ? [:ok, val] : [:timeout]
end

# ============================================================================
puts "\n## Option A: Coordinator IS Main Ractor"
puts "-" * 70
# ============================================================================

test "A1: Main Ractor receives signals directly" do
  signal_port = Ractor::Port.new
  handler_ran = false

  Signal.trap("USR1") do
    handler_ran = true
    signal_port << [:signal, :usr1] rescue nil
  end

  # Simulate coordinator work
  work_port = Ractor::Port.new

  # Spawn a worker that sends work
  worker = Ractor.new(work_port) do |port|
    sleep 0.05
    port << [:work, :task_complete]
  end

  # Send signal
  Process.kill("USR1", Process.pid)

  # Coordinator's select loop
  results = []
  2.times do
    timer = Ractor::Port.new
    Thread.new(timer) { |t| sleep 0.5; t << :timeout rescue nil }

    ready, val = Ractor.select(timer, signal_port, work_port)
    break if ready == timer
    results << [ready == signal_port ? :signal : :work, val]
  end

  worker.value rescue nil
  Signal.trap("USR1", "DEFAULT")

  handler_ran &&
    results.any? { |src, _| src == :signal } &&
    results.any? { |src, _| src == :work }
end

test "A2: Main coordinator handles multiple signal types" do
  signal_port = Ractor::Port.new
  received = []

  Signal.trap("USR1") { signal_port << [:signal, :usr1] rescue nil }
  Signal.trap("USR2") { signal_port << [:signal, :usr2] rescue nil }
  Signal.trap("HUP")  { signal_port << [:signal, :hup] rescue nil }

  Process.kill("USR1", Process.pid)
  Process.kill("USR2", Process.pid)
  Process.kill("HUP", Process.pid)
  sleep 0.05

  # Drain
  3.times do
    result = receive_with_timeout(signal_port, 0.2)
    break if result[0] == :timeout
    received << result[1]
  end

  Signal.trap("USR1", "DEFAULT")
  Signal.trap("USR2", "DEFAULT")
  Signal.trap("HUP", "DEFAULT")

  received.map(&:last).sort == [:hup, :usr1, :usr2].sort
end

# ============================================================================
puts "\n## Option B: Coordinator is Child, Main Relays via Queue"
puts "-" * 70
# ============================================================================

test "B1: Main receives signal, relays to child coordinator" do
  # Main creates a Queue for signal relay (Thread::Queue#push is signal-safe)
  signal_queue = Thread::Queue.new

  Signal.trap("USR1") do
    signal_queue << [:signal, :usr1]  # Documented as safe!
  end

  # Setup port for child to send its inbox
  setup_port = Ractor::Port.new

  # Child coordinator
  coordinator = Ractor.new(setup_port) do |setup|
    inbox = Ractor::Port.new
    setup << inbox  # Give main our inbox

    # Wait for message
    timer = Ractor::Port.new
    Thread.new(timer) { |t| sleep 1.0; t << :timeout rescue nil }
    ready, val = Ractor.select(timer, inbox)
    ready == inbox ? [:received, val] : [:timeout]
  end

  coord_inbox = setup_port.receive  # Get coordinator's inbox

  # Relay thread: Queue -> Coordinator
  relay = Thread.new do
    loop do
      msg = signal_queue.pop
      coord_inbox << msg
      break if msg[0] == :shutdown
    end
  end

  # Send signal
  Process.kill("USR1", Process.pid)
  sleep 0.05

  # Stop relay
  signal_queue << [:shutdown]
  relay.join(0.5)

  result = coordinator.value
  Signal.trap("USR1", "DEFAULT")

  result == [:received, [:signal, :usr1]]
end

test "B2: Relay handles multiple signals before coordinator processes" do
  signal_queue = Thread::Queue.new
  received_by_coord = []

  Signal.trap("USR1") { signal_queue << [:signal, :usr1] }
  Signal.trap("USR2") { signal_queue << [:signal, :usr2] }

  setup_port = Ractor::Port.new

  coordinator = Ractor.new(setup_port) do |setup|
    inbox = Ractor::Port.new
    setup << inbox

    messages = []
    4.times do  # Expect 2 signals + shutdown
      timer = Ractor::Port.new
      Thread.new(timer) { |t| sleep 0.5; t << :timeout rescue nil }
      ready, val = Ractor.select(timer, inbox)
      break if ready == timer || val[0] == :shutdown
      messages << val
    end
    messages
  end

  coord_inbox = setup_port.receive

  relay = Thread.new do
    loop do
      msg = signal_queue.pop
      coord_inbox << msg
      break if msg[0] == :shutdown
    end
  end

  # Rapid signals
  Process.kill("USR1", Process.pid)
  Process.kill("USR2", Process.pid)
  sleep 0.1

  signal_queue << [:shutdown]
  relay.join(0.5)

  result = coordinator.value
  Signal.trap("USR1", "DEFAULT")
  Signal.trap("USR2", "DEFAULT")

  result.map(&:last).sort == [:usr1, :usr2].sort
end

# ============================================================================
puts "\n## Option C: Coordinator is Child, Direct Port Send"
puts "-" * 70
# ============================================================================

test "C1: Signal handler sends directly to child's port" do
  # Child creates port, sends it to main via setup port
  setup_port = Ractor::Port.new

  coordinator = Ractor.new(setup_port) do |setup|
    inbox = Ractor::Port.new
    setup << inbox

    timer = Ractor::Port.new
    Thread.new(timer) { |t| sleep 1.0; t << :timeout rescue nil }
    ready, val = Ractor.select(timer, inbox)
    ready == inbox ? [:received, val] : [:timeout]
  end

  coord_inbox = setup_port.receive

  # Signal handler sends DIRECTLY to coordinator's port
  # (No relay thread needed)
  Signal.trap("USR1") do
    coord_inbox << [:signal, :usr1] rescue nil
  end

  Process.kill("USR1", Process.pid)
  sleep 0.05

  result = coordinator.value
  Signal.trap("USR1", "DEFAULT")

  result == [:received, [:signal, :usr1]]
end

test "C2: Direct send under signal stress" do
  setup_port = Ractor::Port.new

  coordinator = Ractor.new(setup_port) do |setup|
    inbox = Ractor::Port.new
    setup << inbox

    messages = []
    50.times do
      timer = Ractor::Port.new
      Thread.new(timer) { |t| sleep 0.5; t << :timeout rescue nil }
      ready, val = Ractor.select(timer, inbox)
      break if ready == timer
      messages << val
    end
    messages.length
  end

  coord_inbox = setup_port.receive
  signal_count = 0

  Signal.trap("USR1") do
    signal_count += 1
    coord_inbox << [:signal, signal_count] rescue nil
  end

  # Rapid fire signals
  20.times do
    Process.kill("USR1", Process.pid)
    sleep 0.001
  end
  sleep 0.2

  result = coordinator.value
  Signal.trap("USR1", "DEFAULT")

  puts "\n  Signals sent: 20, Handler ran: #{signal_count}, Coordinator received: #{result}"
  result > 0  # At least some got through (coalescing expected)
end

test "C3: Child coordinator with work + signals on same select" do
  setup_port = Ractor::Port.new

  coordinator = Ractor.new(setup_port) do |setup|
    inbox = Ractor::Port.new
    setup << inbox

    work_results = []
    signal_results = []

    5.times do
      timer = Ractor::Port.new
      Thread.new(timer) { |t| sleep 0.5; t << :timeout rescue nil }
      ready, val = Ractor.select(timer, inbox)
      break if ready == timer

      case val
      in [:signal, sig]
        signal_results << sig
      in [:work, data]
        work_results << data
      in [:shutdown]
        break
      end
    end

    { signals: signal_results, work: work_results }
  end

  coord_inbox = setup_port.receive

  Signal.trap("USR1") { coord_inbox << [:signal, :usr1] rescue nil }

  # Send work
  coord_inbox << [:work, :task1]
  coord_inbox << [:work, :task2]

  # Send signal
  Process.kill("USR1", Process.pid)
  sleep 0.05

  # Shutdown
  coord_inbox << [:shutdown]

  result = coordinator.value
  Signal.trap("USR1", "DEFAULT")

  result[:work].include?(:task1) &&
    result[:work].include?(:task2) &&
    result[:signals].include?(:usr1)
end

# ============================================================================
puts "\n## Comparison: Main as Thin Relay vs Main as Coordinator"
puts "-" * 70
# ============================================================================

test "D1: Main as thin signal relay (minimal main Ractor)" do
  # Pattern: Main Ractor does ONLY signal handling
  # All other coordination in child

  signal_queue = Thread::Queue.new
  shutdown = false

  Signal.trap("USR1") { signal_queue << [:signal, :usr1] }
  Signal.trap("USR2") { signal_queue << [:signal, :usr2] }

  setup_port = Ractor::Port.new

  # Full coordinator as child
  coordinator = Ractor.new(setup_port) do |setup|
    inbox = Ractor::Port.new
    setup << inbox

    state = { signals: [], work: [] }

    loop do
      timer = Ractor::Port.new
      Thread.new(timer) { |t| sleep 0.5; t << :timeout rescue nil }
      ready, val = Ractor.select(timer, inbox)

      break state if ready == timer

      case val
      in [:signal, sig]
        state[:signals] << sig
      in [:work, data]
        state[:work] << data
      in [:shutdown]
        break state
      end
    end
  end

  coord_inbox = setup_port.receive

  # Main's only job: relay signals
  relay = Thread.new do
    until shutdown
      msg = signal_queue.pop
      coord_inbox << msg rescue break
    end
  end

  # External work (could come from other Ractors)
  coord_inbox << [:work, :external_task]

  # Signals
  Process.kill("USR1", Process.pid)
  Process.kill("USR2", Process.pid)
  sleep 0.1

  # Shutdown
  shutdown = true
  signal_queue << [:shutdown]
  relay.join(0.5)

  result = coordinator.value
  Signal.trap("USR1", "DEFAULT")
  Signal.trap("USR2", "DEFAULT")

  result[:signals].sort == [:usr1, :usr2].sort &&
    result[:work] == [:external_task]
end

# ============================================================================
puts "\n## Summary"
puts "=" * 70
# ============================================================================

passed = $results.count { |r| r[1] == :pass }
failed = $results.count { |r| r[1] == :fail }
errors = $results.count { |r| r[1] == :error }

puts "Passed: #{passed}"
puts "Failed: #{failed}"
puts "Errors: #{errors}"

puts
puts "ARCHITECTURAL OPTIONS COMPARISON:"
puts
puts "Option A: Coordinator IS Main Ractor"
puts "  + Simplest: no relay, no extra Ractor"
puts "  + Signal handlers naturally in coordinator context"
puts "  + Direct port ownership (main creates, main receives)"
puts "  - Main Ractor must handle all coordination logic"
puts "  - If coordinator code is complex, main becomes complex"
puts
puts "Option B: Child Coordinator, Queue Relay"
puts "  + Coordinator is isolated in child Ractor"
puts "  + Uses documented signal-safe Thread::Queue"
puts "  + Main stays simple (just relay)"
puts "  - Extra relay thread required"
puts "  - Extra hop: signal -> queue -> relay -> port"
puts
puts "Option C: Child Coordinator, Direct Port Send"
puts "  + Coordinator is isolated in child Ractor"
puts "  + No relay thread needed"
puts "  + Direct: signal -> port"
puts "  - Relies on port << being signal-safe (tested, not documented)"
puts "  - Child must yield port before signals can be set up"
puts
puts "RECOMMENDATION:"
puts "  Option A (coordinator IS main) is simplest and most robust."
puts "  Option C works if you need coordinator in child Ractor."
puts "  Option B is safest if you don't trust port << in signal handlers."
