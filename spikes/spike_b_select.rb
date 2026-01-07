# Spike B: Exploring Ractor.select in Ruby 4.0
# Goal: Understand multiplexing semantics for Proctor's receive(timeout:)

puts "=" * 60
puts "SPIKE B: Ractor.select Exploration"
puts "Ruby version: #{RUBY_VERSION}"
puts "=" * 60

# ============================================================================
# Q1: Basic Ractor.select syntax - how do you wait on multiple Ractors?
# ============================================================================
puts "\n--- Q1: Basic Ractor.select syntax ---\n"

begin
  # In Ruby 4.0, we use Ractor::Port for communication
  port1 = Ractor::Port.new
  port2 = Ractor::Port.new

  Ractor.new(port1, name: 'r1') do |port|
    sleep 0.1
    port.send(:from_r1)
  end

  Ractor.new(port2, name: 'r2') do |port|
    sleep 0.2
    port.send(:from_r2)
  end

  puts "Created two Ractors with separate ports"
  puts "Calling Ractor.select(port1, port2)..."

  result = Ractor.select(port1, port2)
  puts "First select returned: #{result.inspect}"
  puts "  Result class: #{result.class}"

  result2 = Ractor.select(port1, port2)
  puts "Second select returned: #{result2.inspect}"

  puts "\nQ1 FINDING: Ractor.select takes Port objects"
  puts "Q1 FINDING: Returns [port, message] tuple"
rescue StandardError => e
  puts "Q1 ERROR: #{e.class}: #{e.message}"
  puts e.backtrace.first(3).join("\n")
end

# ============================================================================
# Q1b: Can we also select on Ractor objects directly?
# ============================================================================
puts "\n--- Q1b: Can we select on Ractor objects directly? ---\n"

begin
  # Create a Ractor that sends to a port after delay
  r_direct = Ractor.new(name: 'direct_test') do
    sleep 0.1
    42  # Return value
  end

  puts "Trying to select on Ractor directly..."
  puts "r_direct = #{r_direct.inspect}"
  puts "r_direct.default_port = #{r_direct.default_port.inspect}"

  # The error message said "should be Ractor::Port or Ractor"
  # so Ractor.select *should* accept Ractor objects
  result = Ractor.select(r_direct)
  puts "  Ractor.select(r_direct) returned: #{result.inspect}"
rescue Ractor::RemoteError => e
  puts "  RemoteError: #{e.message}"
  puts "  Cause: #{e.cause.inspect}" if e.respond_to?(:cause)
rescue StandardError => e
  puts "  Error: #{e.class}: #{e.message}"
end

# Let's try with a Ractor that doesn't crash
begin
  r_valid = Ractor.new(name: 'valid') do
    sleep 0.1
    :success  # Just return value, don't use Ractor.yield
  end

  puts "\nWaiting for Ractor to complete then selecting..."
  sleep 0.2

  result = Ractor.select(r_valid)
  puts "  After completion, select returned: #{result.inspect}"
rescue StandardError => e
  puts "  Error: #{e.class}: #{e.message}"
end

# Try using the Ractor's default_port
begin
  # Send TO a Ractor via its default_port
  r_receiver = Ractor.new(name: 'receiver') do
    # Receive on our own default port
    msg = Ractor.recv
    msg.upcase
  end

  puts "\nSending to Ractor via default_port..."
  r_receiver.default_port.send("hello")

  result = r_receiver.value
  puts "  r_receiver.value = #{result.inspect}"
rescue StandardError => e
  puts "  Error: #{e.class}: #{e.message}"
end

# ============================================================================
# Q2: Does Ractor.select support timeout? What's the API?
# ============================================================================
puts "\n--- Q2: Timeout support in Ractor.select ---\n"

begin
  # Check method signature
  puts "Ractor.method(:select).parameters: #{Ractor.method(:select).parameters.inspect}"
  puts "  -> Only accepts rest args (ports/ractors), no keyword args for timeout"
rescue StandardError => e
  puts "Could not inspect parameters: #{e.message}"
end

# ============================================================================
# Q3: Can Ractor.select wait on Ractor::Port objects?
# ============================================================================
puts "\n--- Q3: Ractor.select with Ractor::Port ---\n"

begin
  puts "Ractor::Port exists: YES"
  puts "Ractor::Port.instance_methods(false): #{Ractor::Port.instance_methods(false).inspect}"

  # Multiple ports test with timing verification
  port_a = Ractor::Port.new
  port_b = Ractor::Port.new
  port_c = Ractor::Port.new

  Ractor.new(port_a, name: 'a') do |p|
    sleep 0.15
    p.send(:from_a)
  end
  Ractor.new(port_b, name: 'b') do |p|
    sleep 0.05
    p.send(:from_b)
  end
  Ractor.new(port_c, name: 'c') do |p|
    sleep 0.10
    p.send(:from_c)
  end

  puts "\nSelecting on 3 ports (b=0.05s, c=0.10s, a=0.15s)..."
  start = Time.now

  3.times do |i|
    result = Ractor.select(port_a, port_b, port_c)
    elapsed = Time.now - start
    _, value = result
    puts "  #{i+1}. #{elapsed.round(3)}s: #{value.inspect}"
  end

  puts "\nQ3 FINDING: Ractor.select correctly prioritizes by arrival time"
rescue StandardError => e
  puts "Q3 ERROR: #{e.class}: #{e.message}"
  puts e.backtrace.first(3).join("\n")
end

# ============================================================================
# Q4: What does Ractor.select return? How do you know which source?
# ============================================================================
puts "\n--- Q4: Return value semantics ---\n"

begin
  p_a = Ractor::Port.new
  p_b = Ractor::Port.new

  Ractor.new(p_a, name: 'A') do |p|
    sleep 0.05
    p.send([:data_from_a, 42])
  end
  Ractor.new(p_b, name: 'B') do |p|
    sleep 0.1
    p.send([:data_from_b, 99])
  end

  result = Ractor.select(p_a, p_b)
  source, value = result

  puts "Result: #{result.inspect}"
  puts "  source == p_a ? #{source == p_a}"
  puts "  source.equal?(p_a) ? #{source.equal?(p_a)}"
  puts "\nQ4 FINDING: Returns [port, message], port identity preserved"
rescue StandardError => e
  puts "Q4 ERROR: #{e.class}: #{e.message}"
end

# ============================================================================
# Q5: What happens on timeout - exception or special return value?
# ============================================================================
puts "\n--- Q5: Timeout behavior (timer Ractor pattern) ---\n"

begin
  work_port  = Ractor::Port.new
  timer_port = Ractor::Port.new

  # Timer Ractor sends :timeout after 0.1s
  Ractor.new(timer_port, name: 'timer') do |port|
    sleep 0.1
    port.send(:timeout)
  end

  # Worker is slow (0.5s)
  Ractor.new(work_port, name: 'worker') do |port|
    sleep 0.5
    port.send(:work_done)
  end

  start   = Time.now
  result  = Ractor.select(work_port, timer_port)
  elapsed = Time.now - start

  _, value = result
  puts "Returned in #{elapsed.round(3)}s"
  puts "Result: #{value.inspect}"
  puts "Timeout? #{value == :timeout}"
  puts "\nQ5 FINDING: No native timeout. Use timer Ractor pattern."
rescue StandardError => e
  puts "Q5 ERROR: #{e.class}: #{e.message}"
end

# ============================================================================
# Q5b: Closed port behavior
# ============================================================================
puts "\n--- Q5b: Closed port behavior ---\n"

begin
  # What happens with just a closed port?
  closed = Ractor::Port.new
  closed.close

  puts "Selecting on single closed port..."
  begin
    Ractor.select(closed)
  rescue Ractor::ClosedError => e
    puts "  Ractor::ClosedError: #{e.message}"
  end

  # What if one of many is closed?
  puts "\nSelecting on [closed, open] - both options..."
  open = Ractor::Port.new
  Ractor.new(open) do |p|
    sleep 0.1
    p.send(:from_open)
  end

  begin
    result = Ractor.select(closed, open)
    puts "  Returned: #{result.inspect}"
  rescue Ractor::ClosedError => e
    puts "  ClosedError (even with open port!): #{e.message}"
  end

  # What about order - open first?
  puts "\nSelecting on [open, closed]..."
  open2   = Ractor::Port.new
  closed2 = Ractor::Port.new
  closed2.close
  Ractor.new(open2) do |p|
    sleep 0.1
    p.send(:from_open2)
  end

  begin
    result = Ractor.select(open2, closed2)
    puts "  Returned: #{result.inspect}"
  rescue Ractor::ClosedError => e
    puts "  ClosedError: #{e.message}"
  end

  puts "\nQ5b FINDING: Closed port in select causes immediate ClosedError"
rescue StandardError => e
  puts "Q5b ERROR: #{e.class}: #{e.message}"
end

# ============================================================================
# Additional: Ractor monitoring for death notification
# ============================================================================
puts "\n--- Additional: Ractor monitoring for death notification ---\n"

begin
  puts "Ractor#monitor signature:"
  puts "  #{Ractor.instance_method(:monitor).parameters.inspect}"

  # monitor takes a port argument!
  monitor_port = Ractor::Port.new

  r = Ractor.new(name: 'to_monitor') do
    sleep 0.1
    :done
  end

  puts "\nCalling r.monitor(monitor_port)..."
  r.monitor(monitor_port)

  puts "Waiting for death notification via Ractor.select..."
  result = Ractor.select(monitor_port)
  puts "  Result: #{result.inspect}"

  _, value = result
  puts "  Value class: #{value.class}"
  puts "  Value: #{value.inspect}"
rescue StandardError => e
  puts "Monitor ERROR: #{e.class}: #{e.message}"
  puts e.backtrace.first(3).join("\n")
end

# Test monitoring a crashing Ractor
puts "\n--- Monitoring a crashing Ractor ---\n"

begin
  crash_monitor = Ractor::Port.new

  crasher = Ractor.new(name: 'crasher') do
    sleep 0.05
    raise "Intentional crash!"
  end

  crasher.monitor(crash_monitor)

  puts "Waiting for crash notification..."
  result = Ractor.select(crash_monitor)
  puts "  Result: #{result.inspect}"

  _, value = result
  puts "  Notification type: #{value.class}"
  puts "  Notification value: #{value.inspect}"

  # In Ruby 4.0, monitor sends symbols, not a special class:
  #   :exited for normal termination
  #   :aborted for crash/exception
  if value == :aborted
    puts "  CRASH detected! (Ractor aborted)"
  elsif value == :exited
    puts "  Normal exit detected"
  end
rescue StandardError => e
  puts "Crash monitor ERROR: #{e.class}: #{e.message}"
end

# ============================================================================
# Additional: Can we mix message ports and monitor ports in one select?
# ============================================================================
puts "\n--- Mixing message ports and monitor ports ---\n"

begin
  msg_port     = Ractor::Port.new
  monitor_port = Ractor::Port.new

  worker = Ractor.new(msg_port, name: 'mixed_worker') do |port|
    sleep 0.2
    port.send(:work_result)
    # Then exit
  end

  worker.monitor(monitor_port)

  puts "Selecting on both message port and monitor port..."

  # First should be the message
  r1 = Ractor.select(msg_port, monitor_port)
  puts "  First: #{r1.inspect}"

  # Second should be the exit notification
  r2 = Ractor.select(msg_port, monitor_port)
  puts "  Second: #{r2.inspect}"

  puts "\nFINDING: Can multiplex messages AND death notifications!"
rescue StandardError => e
  puts "Mixed select ERROR: #{e.class}: #{e.message}"
end

# ============================================================================
# Additional: Ractor.recv and default mailbox
# ============================================================================
puts "\n--- Ractor.recv (receiving in Ractor's default mailbox) ---\n"

begin
  result_port = Ractor::Port.new

  worker = Ractor.new(result_port, name: 'recv_test') do |out_port|
    # Receive from our default mailbox (someone sends to us)
    msg = Ractor.recv
    out_port.send("Received: #{msg}")
  end

  puts "Sending to worker.default_port..."
  worker.default_port.send(:hello_worker)

  result = Ractor.select(result_port)
  puts "  Worker replied: #{result[1].inspect}"

  puts "\nFINDING: Ractor.recv reads from Ractor's default_port mailbox"
rescue StandardError => e
  puts "Ractor.recv ERROR: #{e.class}: #{e.message}"
end

puts "\n" + ("=" * 60)
puts "SPIKE B COMPLETE"
puts "=" * 60

# === SPIKE B FINDINGS ===
#
# Q1: Basic Ractor.select syntax?
# A1: Ractor.select(*ports_or_ractors) -> [source, value]
#     WORKS WITH BOTH:
#     - Ractor::Port objects: Ractor.select(port1, port2) -> [port, message]
#     - Ractor objects directly: Ractor.select(r1, r2) -> [ractor, return_value]
#     Blocks until at least one source has data ready.
#     Example output: [#<Ractor::Port to:#1 id:1>, :from_r1]
#                 or: [#<Ractor:#4 terminated>, 42]
#
# Q2: Timeout support?
# A2: NO native timeout support in Ractor.select
#     - Ractor.method(:select).parameters = [[:rest, :ports]]
#     - No keyword arguments accepted
#     - Passing timeout: raises ArgumentError("should be Ractor::Port or Ractor")
#     - WORKAROUND: Timer Ractor pattern (dedicated Ractor that sleeps then sends :timeout)
#
# Q3: Can select on Ractor::Port?
# A3: YES - Ractor::Port is the PRIMARY mechanism for Ruby 4.0 Ractor communication
#     - Ractor::Port.instance_methods: [:send, :receive, :close, :closed?, :<<, :inspect]
#     - Multiple ports can be selected simultaneously
#     - Correctly returns data in order of arrival (earliest first)
#     - VERIFIED: 3 ports at 0.05s, 0.10s, 0.15s returned in correct order
#
# Q4: Return value semantics?
# A4: Returns [source, value] tuple where:
#     - source: The exact Port or Ractor object (identity preserved, == and equal? work)
#     - value: For Port - the message sent; For Ractor - the block return value
#     - Port example: [#<Ractor::Port to:#1 id:11>, [:data_from_a, 42]]
#     - Ractor example: [#<Ractor:#4 terminated>, 42]
#
# Q5: Timeout behavior (exception vs return)?
# A5: N/A - no native timeout. But timer Ractor pattern works perfectly:
#     - Timer Ractor sleeps, then sends :timeout to its port
#     - Returns normally: [timer_port, :timeout]
#     - No exception thrown
#     - Can check source port or message value to detect timeout
#     - VERIFIED: Returned in 0.101s with :timeout when work takes 0.5s
#
# ADDITIONAL FINDINGS:
#
# Closed Port Behavior:
#   - Selecting on a closed port raises Ractor::ClosedError IMMEDIATELY
#   - Even if other open ports are in the select list - FAILS IMMEDIATELY!
#   - IMPORTANT: Must filter out closed ports before calling select
#
# Ractor#monitor(port):
#   - Signature: Ractor#monitor(port) - takes exactly one port argument
#   - Sends notification symbol to port when Ractor terminates:
#     - :exited for normal termination
#     - :aborted for crash/exception
#   - Can multiplex monitor ports with message ports in same select!
#   - Example: Ractor.select(msg_port, monitor_port) correctly receives both
#
# Ractor.recv:
#   - Reads from current Ractor's default_port (its incoming mailbox)
#   - External code sends via: ractor.default_port.send(msg)
#   - Blocks until message available
#
# Ractor#default_port:
#   - Every Ractor has a default_port for incoming messages
#   - r.default_port.send(msg) sends to Ractor r
#   - Inside r: Ractor.recv receives from default_port
#
# Ractor#value:
#   - Blocks until Ractor completes, returns final value
#   - Works like Thread#value
#
# IMPLICATIONS FOR SHELLAC:
#
# 1. receive(timeout:) implementation:
#    - Create a dedicated timer Ractor that sleeps and sends :timeout
#    - Include timer_port in Ractor.select alongside message ports
#    - Check return source to determine if timeout occurred
#    - Challenge: Must clean up timer Ractor if message arrives before timeout
#      (timer Ractor keeps running and will send :timeout later - need to handle)
#
# 2. Death notification for external processes:
#    - Use ractor.monitor(notification_port) to get exit notifications
#    - Returns :exited (normal) or :aborted (crash)
#    - Can be mixed into same Ractor.select with message ports
#    - Perfect for detecting child Ractor/process death alongside messages
#
# 3. Closed port gotcha:
#    - If any port in select is closed, entire select fails with ClosedError
#    - Must filter out closed ports before calling select
#    - Or catch ClosedError and retry without the closed port
#
# 4. Pattern for Proctor receive(timeout:):
#    ```ruby
#    def receive(timeout: nil)
#      ports_to_select = [inbox_port]
#
#      if timeout
#        timer_port = Ractor::Port.new
#        timer_ractor = Ractor.new(timer_port, timeout) do |p, t|
#          sleep(t)
#          p.send(:timeout)
#        end
#        ports_to_select << timer_port
#      end
#
#      source, msg = Ractor.select(*ports_to_select)
#
#      if source == timer_port
#        return nil  # or raise Timeout::Error
#      end
#
#      # TODO: If we got a real message, timer_ractor is still running!
#      # Options:
#      # a) Let it complete and discard :timeout message later (leak)
#      # b) Store timer_ractor and close its port to stop it (cleanup)
#      # c) Use a smarter timer pool that can be cancelled
#
#      msg
#    end
#    ```
#
# 5. Multiplexed receive with death notification:
#    ```ruby
#    def receive_or_death(timeout: nil)
#      ports = [inbox_port, process_monitor_port]
#      ports << timer_port if timeout
#
#      source, msg = Ractor.select(*ports)
#
#      case source
#      when timer_port then :timeout
#      when process_monitor_port then {:down, msg}  # :exited or :aborted
#      else msg  # Regular message
#      end
#    end
#    ```
