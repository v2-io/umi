# spike_a_shareability.rb
# Exploring what objects can cross Ractor boundaries for Proctor
# Ruby 4.0 Ractor shareability spike
#
# NOTE: Ruby 4.0 changed the Ractor API significantly:
# - Ractor#take is gone, replaced by Ractor#value and Ractor#join
# - Ractor::Port is the primary communication mechanism
# - default_port provides each Ractor's built-in port
# - IMPORTANT: Only the Port's creator Ractor can call receive on it!

puts "=" * 60
puts "SPIKE A: Ractor Shareability Exploration"
puts "Ruby #{RUBY_VERSION}"
puts "=" * 60
puts

# Helper to safely test and report with timeout
def test(description, timeout_sec: 3)
  print "Testing: #{description}... "
  begin
    result  = nil
    thread  = Thread.new { result = yield }
    success = thread.join(timeout_sec)
    if success
      puts "SUCCESS"
      puts "  Result: #{result.inspect}"
      result
    else
      thread.kill
      puts "TIMEOUT"
      puts "  Test hung for #{timeout_sec}s"
      nil
    end
  rescue StandardError => e
    puts "FAILED"
    puts "  Error: #{e.class}: #{e.message}"
    nil
  end
end

# ============================================================
# BASELINE: Understand Ruby 4.0 Ractor API first
# ============================================================
puts "\n" + ("=" * 60)
puts "BASELINE: Ruby 4.0 Ractor API Discovery"
puts "=" * 60

puts "\n--- Test B1: Ractor.new and value (replaces take) ---"
test("Basic Ractor with value") do
  r = Ractor.new { 42 }
  r.value
end

puts "\n--- Test B2: Ractor.new with args ---"
test("Ractor with argument passing") do
  r = Ractor.new(10) { |x| x * 2 }
  r.value
end

puts "\n--- Test B3: Ractor::Port basics ---"
test("Create and use Ractor::Port") do
  port = Ractor::Port.new
  port.send("hello")
  msg = port.receive
  "Sent and received: #{msg}"
end

puts "\n--- Test B4: Cross-Ractor communication via Port ---"
test("Port between Ractors - Ractor sends, main receives") do
  port = Ractor::Port.new

  sender = Ractor.new(port) do |p|
    p.send("message from sender")
    "sender done"
  end

  msg = port.receive
  sender.value  # wait for completion
  "Main received: #{msg}"
end

puts "\n--- Test B5: default_port ---"
test("Ractor#default_port usage") do
  r = Ractor.new do
    msg = Ractor.receive  # receives from default_port
    "Ractor got: #{msg}"
  end

  r.default_port.send("via default port")
  r.value
end

# ============================================================
# Q1: Can IO objects (pipes from Process.spawn) be passed to a Ractor?
# ============================================================
puts "\n" + ("=" * 60)
puts "Q1: Can IO pipes cross Ractor boundaries?"
puts "=" * 60

puts "\n--- Test 1a: Create pipe, pass read-end to Ractor arg ---"
test("Send pipe read-end via Ractor.new argument") do
  rd, wr = IO.pipe
  wr.write("hello from pipe")
  wr.close

  r = Ractor.new(rd) do |pipe|
    data = pipe.read
    pipe.close
    "Ractor read: #{data}"
  end
  result = r.value
  begin
    rd.close
  rescue StandardError
    nil
  end
  result
end

puts "\n--- Test 1b: Pass pipe via default_port.send ---"
test("Send pipe via default_port") do
  rd, wr = IO.pipe

  r = Ractor.new do
    pipe = Ractor.receive
    pipe.write("from ractor")
    pipe.close
    "wrote to pipe"
  end

  r.default_port.send(wr)
  result = r.value
  begin
    wr.close
  rescue StandardError
    nil
  end
  data = rd.read
  rd.close
  "#{result}, main read: #{data}"
end

puts "\n--- Test 1c: Pipe from Process.spawn ---"
test("Pass spawn stdout pipe to Ractor") do
  rd, wr = IO.pipe
  pid = Process.spawn("echo 'hello from spawn'", out: wr)
  wr.close

  r = Ractor.new(rd) do |pipe|
    data = pipe.read.chomp
    pipe.close
    "Ractor got spawn output: #{data}"
  end

  Process.wait(pid)
  r.value
end

puts "\n--- Test 1d: Full spawn with stdin/stdout pipes (via args) ---"
test("Bidirectional pipes via Ractor.new args - KNOWN TO HANG", timeout_sec: 2) do
  # NOTE: This test demonstrates that passing IO via Ractor.new args
  # may cause hangs with bidirectional pipes. See test 1d2 for working pattern.
  stdin_rd, stdin_wr = IO.pipe
  stdout_rd, stdout_wr = IO.pipe

  pid = Process.spawn("cat", in: stdin_rd, out: stdout_wr)
  stdin_rd.close
  stdout_wr.close

  r = Ractor.new(stdin_wr, stdout_rd) do |wr, rd|
    wr.write("echo this back")
    wr.close
    data = rd.read
    rd.close
    "Ractor bidirectional: #{data}"
  end

  result = r.value
  Process.wait(pid)
  result
end

puts "\n--- Test 1d2: Full spawn with move:true (WORKING PATTERN) ---"
test("Bidirectional pipes via Port#send move:true") do
  stdin_rd, stdin_wr = IO.pipe
  stdout_rd, stdout_wr = IO.pipe

  pid = Process.spawn("cat", in: stdin_rd, out: stdout_wr)
  stdin_rd.close
  stdout_wr.close

  r = Ractor.new do
    wr = Ractor.receive
    rd = Ractor.receive
    wr.write("echo this back")
    wr.close
    data = rd.read
    rd.close
    "Ractor bidirectional: #{data}"
  end

  r.default_port.send(stdin_wr, move: true)
  r.default_port.send(stdout_rd, move: true)

  result = r.value
  Process.wait(pid)
  result
end

puts "\n--- Test 1e: IO shareability check ---"
test("Is IO shareable?") do
  rd, wr = IO.pipe
  shareable = Ractor.shareable?(rd)
  rd.close
  wr.close
  "IO shareable? #{shareable}"
end

# ============================================================
# Q2: Can Ractor::Port objects be passed between Ractors?
# ============================================================
puts "\n" + ("=" * 60)
puts "Q2: Can Ractor::Port be passed between Ractors?"
puts "=" * 60

puts "\n--- Test 2a: Port shareability ---"
test("Is Ractor::Port shareable?") do
  port = Ractor::Port.new
  "Port shareable? #{Ractor.shareable?(port)}"
end

puts "\n--- Test 2b: Pass Port as Ractor argument (send direction) ---"
test("Pass Port to Ractor - Ractor sends to Port, main receives") do
  port = Ractor::Port.new  # Main creates, main will receive

  r = Ractor.new(port) do |p|
    p.send("hello from inside ractor")  # Ractor sends
    "sent message"
  end

  msg = port.receive  # Main receives (owner)
  r.value
  "Main received via shared port: #{msg}"
end

puts "\n--- Test 2c: Multiple Ractors sending to same Port ---"
test("Multiple Ractors write to same Port") do
  port = Ractor::Port.new  # Main owns

  r1 = Ractor.new(port) do |p|
    p.send("from r1")
    "r1 done"
  end
  r2 = Ractor.new(port) do |p|
    p.send("from r2")
    "r2 done"
  end

  msg1 = port.receive  # Main receives
  msg2 = port.receive
  r1.value
  r2.value
  "Received: #{msg1}, #{msg2}"
end

puts "\n--- Test 2d: Port receive ownership constraint ---"
test("Can only creator receive from Port?") do
  port = Ractor::Port.new  # Main creates

  r = Ractor.new(port) do |p|
    msg = p.receive  # Try to receive in non-creator
    "received: #{msg}"
  rescue StandardError => e
    "Error: #{e.class} - #{e.message}"
  end

  port.send("test message")  # Send something to unblock if it tries
  r.value
end

puts "\n--- Test 2e: Ractor creates Port, passes via default_port ---"
test("Ractor creates Port, sends to main's port, main sends back") do
  main_inbox = Ractor::Port.new  # Main's inbox - main receives here

  r = Ractor.new(main_inbox) do |main_port|
    my_inbox = Ractor::Port.new   # Ractor's inbox - ractor receives here
    main_port.send(my_inbox)      # Tell main about ractor's inbox
    msg = my_inbox.receive        # Wait for main to reply
    "Ractor received: #{msg}"
  end

  # Main gets ractor's inbox port
  ractor_inbox = main_inbox.receive
  # Main sends to ractor's inbox
  ractor_inbox.send("hello from main to ractor's port")
  r.value
end

puts "\n--- Test 2f: Pass Port via Port (nested) ---"
test("Send Port via another Port - send directions") do
  # Main creates outer port (main will receive on it)
  outer_port = Ractor::Port.new
  # Main creates inner port (main will receive on it)
  inner_port = Ractor::Port.new

  r = Ractor.new(outer_port) do |op|
    # Ractor needs to receive from outer_port, but only main can receive!
    # This should fail - testing the constraint

    received_port = op.receive
    received_port.send("message via received port")
    "ractor received port and sent"
  rescue StandardError => e
    "Error: #{e.class}"
  end

  outer_port.send(inner_port)
  r.value
end

puts "\n--- Test 2g: Ractor sends its own Port to main ---"
test("Ractor creates Port, sends via main's port") do
  main_port = Ractor::Port.new  # Main can receive

  r = Ractor.new(main_port) do |mp|
    ractor_port = Ractor::Port.new  # Ractor can receive
    mp.send(ractor_port)            # Send to main
    msg = ractor_port.receive       # Wait for reply
    "Ractor got: #{msg}"
  end

  ractor_port = main_port.receive   # Main gets Ractor's port
  ractor_port.send("hello to ractor")
  r.value
end

# ============================================================
# Q3: What happens when we try to share non-frozen objects?
# ============================================================
puts "\n" + ("=" * 60)
puts "Q3: What errors do we get with non-shareable objects?"
puts "=" * 60

puts "\n--- Test 3a: Non-frozen String ---"
test("Pass mutable String to Ractor") do
  s = "mutable string"
  r = Ractor.new(s) { |str| "got: #{str}" }
  r.value
end

puts "\n--- Test 3b: Non-frozen Array ---"
test("Pass mutable Array to Ractor") do
  arr = [1, 2, 3]
  r = Ractor.new(arr) { |a| "got array: #{a.inspect}" }
  r.value
end

puts "\n--- Test 3c: Non-frozen Hash ---"
test("Pass mutable Hash to Ractor") do
  h = { key: "value" }
  r = Ractor.new(h) { |hash| "got hash: #{hash.inspect}" }
  r.value
end

puts "\n--- Test 3d: Frozen String (should work) ---"
test("Pass frozen String to Ractor") do
  s = "frozen string".freeze
  r = Ractor.new(s) { |str| "got frozen: #{str}" }
  r.value
end

puts "\n--- Test 3e: Frozen Array with frozen contents ---"
test("Pass deeply frozen Array to Ractor") do
  arr = ["a".freeze, "b".freeze].freeze
  r = Ractor.new(arr) { |a| "got frozen array: #{a.inspect}" }
  r.value
end

puts "\n--- Test 3f: Custom class instance ---"
test("Pass custom class instance to Ractor") do
  class MyData
    def initialize(val) = @val = val
    attr_reader :val
  end

  obj = MyData.new(42)
  r = Ractor.new(obj) { |o| "got: #{o.val}" }
  r.value
end

puts "\n--- Test 3g: Ractor::make_shareable ---"
test("Use Ractor.make_shareable on object") do
  arr = [1, 2, { nested: "hash" }]
  shareable = Ractor.make_shareable(arr)
  r = Ractor.new(shareable) { |a| "got shareable: #{a.inspect}" }
  r.value
end

puts "\n--- Test 3h: Shareability survey ---"
test("Shareability of different types") do
  results = {}
  results[:frozen_string] = Ractor.shareable?("hello".freeze)
  results[:mutable_string] = Ractor.shareable?("hello")
  results[:integer] = Ractor.shareable?(42)
  results[:symbol] = Ractor.shareable?(:sym)
  results[:nil] = Ractor.shareable?(nil)
  results[:range_frozen] = Ractor.shareable?(1..10)
  results[:range_mutable] = Ractor.shareable?(1..10)
  results[:frozen_array] = Ractor.shareable?([1, 2, 3].freeze)
  results[:ractor] = Ractor.shareable?(Ractor.current)
  results[:ractor_port] = Ractor.shareable?(Ractor::Port.new)
  results[:proc] = Ractor.shareable?(-> { 42 })

  rd, wr = IO.pipe
  results[:io_pipe] = Ractor.shareable?(rd)
  rd.close
  wr.close

  results
end

# ============================================================
# Q4: Move vs Share semantics for IO?
# ============================================================
puts "\n" + ("=" * 60)
puts "Q4: Move vs Share semantics for IO?"
puts "=" * 60

puts "\n--- Test 4a: Can we still use IO after passing to Ractor? ---"
test("Use IO in main after passing to Ractor (move semantics?)") do
  rd, wr = IO.pipe

  r = Ractor.new(rd) do |pipe|
    sleep 0.1  # Give main thread time to try accessing
    data = pipe.read
    pipe.close
    "Ractor read: #{data}"
  end

  # Try to use rd in main thread after passing to Ractor
  wr.write("test data")
  wr.close

  begin
    # Can we still check rd here?
    can_read = rd.read(1)  # Try to read
    "Main could still read: #{can_read.inspect}, Ractor: #{r.value}"
  rescue StandardError => e
    "Main got error: #{e.class} - #{e.message}, Ractor: #{r.value}"
  end
end

puts "\n--- Test 4b: Pass same IO to multiple Ractors ---"
test("Same IO to multiple Ractors") do
  rd, wr = IO.pipe
  wr.write("shared data")
  wr.close

  begin
    r1 = Ractor.new(rd) { |_p| "r1 has pipe" }
    r2 = Ractor.new(rd) { |_p| "r2 has pipe" }
    [r1.value, r2.value]
  rescue StandardError => e
    begin
      rd.close
    rescue StandardError
      nil
    end
    "Error: #{e.class} - #{e.message}"
  end
end

puts "\n--- Test 4c: IO object_id before and after ---"
test("Check if IO is moved or copied") do
  rd, = IO.pipe
  original_id = rd.object_id

  r = Ractor.new(rd) do |pipe|
    "Ractor pipe id: #{pipe.object_id}"
  end

  # Can we get object_id of rd after passing?
  begin
    after_id = rd.object_id
    result = r.value
    "Original: #{original_id}, After: #{after_id}, #{result}"
  rescue StandardError => e
    result = r.value
    "Error accessing original: #{e.class}, #{result}"
  end
end

puts "\n--- Test 4d: Test if move option exists ---"
test("Port#send move: option check") do
  Ractor::Port.new
  rd, wr = IO.pipe
  wr.write("move test")
  wr.close

  r = Ractor.new do
    pipe = Ractor.receive
    data = pipe.read
    pipe.close
    "Ractor read: #{data}"
  end

  begin
    r.default_port.send(rd, move: true)
    # Try to access rd after move
    begin
      rd.closed?
      "rd still accessible after move:true, Ractor: #{r.value}"
    rescue StandardError => e
      "rd inaccessible after move: #{e.class}, Ractor: #{r.value}"
    end
  rescue ArgumentError => e
    r.default_port.send(rd)
    "move: option error (#{e.message}), used regular send. Ractor: #{r.value}"
  end
end

# ============================================================
# EXTRA: Ractor references and select
# ============================================================
puts "\n" + ("=" * 60)
puts "EXTRA: Ractor references and Ractor.select"
puts "=" * 60

puts "\n--- Test X1: Pass Ractor reference to another Ractor ---"
test("Send Ractor reference to another Ractor") do
  worker = Ractor.new do
    msg = Ractor.receive
    "worker got: #{msg}"
  end

  dispatcher = Ractor.new(worker) do |w|
    w.default_port.send("hello from dispatcher")
    "dispatched"
  end

  dispatcher.value
  worker.value
end

puts "\n--- Test X2: Ractor.select with ports ---"
test("Ractor.select with multiple ports") do
  p1 = Ractor::Port.new
  p2 = Ractor::Port.new

  Ractor.new(p1) do |p|
    sleep 0.05
    p.send("from p1")
  end
  Ractor.new(p2) do |p|
    sleep 0.1
    p.send("from p2")
  end

  results = []
  2.times do
    selected, msg = Ractor.select(p1, p2)
    results << "#{selected == p1 ? 'p1' : 'p2'}: #{msg}"
  end
  results
end

puts "\n--- Test X3: Streaming values via Port ---"
test("Ractor streams multiple values via Port (replaces yield)") do
  results_port = Ractor::Port.new  # Main receives

  r = Ractor.new(results_port) do |port|
    port.send("first value")
    port.send("second value")
    "final return"
  end

  results = []
  results << results_port.receive
  results << results_port.receive
  results << r.value
  results
end

puts "\n" + ("=" * 60)
puts "SPIKE COMPLETE"
puts "=" * 60

# === SPIKE A FINDINGS ===
#
# Q1: Can IO pipes cross Ractor boundaries?
# A1: YES! IO objects can be passed via Ractor.new args or Port#send.
#     - IO is NOT shareable (Ractor.shareable? returns false)
#     - IO uses MOVE semantics by default - the object is transferred
#     - Pipes from Process.spawn work perfectly with Ractors
#     - CRITICAL BUG: Passing IO via Ractor.new args can HANG for bidirectional pipes!
#       Use Port#send(io, move: true) instead - this is the reliable pattern
#     - CRITICAL: Without move:true, BOTH sender and receiver can access the IO!
#       This creates race conditions (Test 4a: main read "t", ractor read "est data")
#
# Q2: Can Ractor::Port be passed between Ractors?
# A2: YES, with important ownership constraints:
#     - Ractor::Port IS shareable (Ractor.shareable? returns true)
#     - Ports can be passed as Ractor args or via other Ports
#     - CRITICAL OWNERSHIP RULE: Only the creator Ractor can call receive()!
#       Error: "only allowed from the creator Ractor of this port"
#     - ANY Ractor can call send() on a Port
#     - Pattern: Create Port where you need to receive, share it for others to send
#     - Multiple Ractors can send to the same Port (many-to-one)
#     - Ractor can create its own Port and send it to main for bidirectional comm
#
# Q3: What errors do we get with non-shareable objects?
# A3: SURPRISE - Ruby 4.0 uses implicit move semantics!
#     - Mutable strings, arrays, hashes ALL work (they get moved/copied)
#     - Custom class instances work too (moved)
#     - No errors for non-frozen objects in Ractor.new args
#     - Ractor.make_shareable() deep-freezes objects for true sharing
#     - Shareability survey:
#       SHAREABLE: frozen strings, integers, symbols, nil, ranges, frozen arrays,
#                  Ractor references, Ractor::Port
#       NOT SHAREABLE: mutable strings, procs/lambdas, IO objects
#
# Q4: Move vs Share semantics for IO?
# A4: IO uses MOVE semantics, but Ruby 4.0 has nuances:
#     - Default behavior: IO gets "moved" but original reference may still work!
#       This is DANGEROUS - creates race conditions on the file descriptor
#     - With Port#send(obj, move: true): Original becomes inaccessible
#       Accessing moved object raises: Ractor::MovedError
#     - Object IDs differ across boundary (original: 32, in Ractor: 40)
#       This suggests wrapping/proxying rather than true object movement
#     - Same IO CAN be passed to multiple Ractors (Test 4b succeeded!)
#       All Ractors get access - this is probably a bug or undefined behavior
#
# RUBY 4.0 API CHANGES (vs 3.x):
# - Ractor#take is GONE - use Ractor#value instead
# - Ractor.yield is GONE - use Ractor::Port for streaming values
# - Ractor::Port is the primary communication mechanism
# - Each Ractor has a default_port for receiving (Ractor.receive)
# - Ractor.select works with Ports and Ractors
#
# IMPLICATIONS FOR SHELLAC:
# 1. IO pipes CAN cross Ractor boundaries - core requirement is MET
# 2. MUST use Port#send(io, move:true) for IO transfer (not Ractor.new args)
#    - Ractor.new args can hang with bidirectional pipes (confirmed bug)
#    - move:true prevents race conditions on the file descriptor
#    - move:true makes original reference raise Ractor::MovedError
# 3. Port ownership model matches Erlang's mailbox model well:
#    - Each Ractor owns its "inbox" Port (only owner can receive)
#    - ANY Ractor can send to a Port
#    - Pattern: Create Port in the Ractor that needs to receive
# 4. For bidirectional Ractor<->Ractor comm:
#    - Each side creates own Port (its inbox)
#    - Exchange Port references via messages
#    - Each can send to other's inbox, receive from own inbox
# 5. Proctor design pattern:
#    - Main creates worker Ractor
#    - Main spawns subprocess with pipes
#    - Main sends pipes to worker via Port#send(pipe, move:true)
#    - Worker owns both stdin_wr and stdout_rd
#    - Worker sends results back via Port (not pipes)
#    - Worker's Port created inside worker, sent to main's inbox
# 6. Death notification can use Port closure or Ractor error propagation
# 7. RECOMMENDED: Create helper that always uses move:true for IO to prevent footguns
# 8. Ractor.select enables multiplexing on multiple Ports (like Erlang receive)
