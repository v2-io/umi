#!/usr/bin/env ruby
# frozen_string_literal: true

# Spike C: End-to-End Watcher Pattern
# ====================================
# Goal: Can we build a minimal watcher that turns external processes
# into Ractor-citizens with bidirectional messaging and death notification?
#
# Ruby 4.0 Ractor API Notes (discovered during spike):
# - r.value      - get final return value (replaces old r.take)
# - r << msg     - send message to Ractor
# - r.send(msg)  - same as above
# - Ractor.receive - receive message in current Ractor
# - parent << msg - send to parent Ractor
# - r.monitor(port) - get notified when Ractor exits (:exited or :aborted)
# - NO Ractor.yield in Ruby 4.0!

require 'open3'
require 'timeout'

puts "=" * 60
puts "SPIKE C: End-to-End Watcher Pattern"
puts "Ruby #{RUBY_VERSION}"
puts "=" * 60
puts

# Helper to safely report results
def report(label, success, details = nil)
  status = success ? "OK" : "FAIL"
  puts "[#{status}] #{label}"
  puts "       #{details}" if details
end

def section(title)
  puts
  puts "-" * 40
  puts title
  puts "-" * 40
end

# =============================================================================
# TEST 1: Spawn process inside Ractor
# =============================================================================
section "TEST 1: Spawn process inside Ractor"

begin
  r = Ractor.new {
    require 'open3'
    stdin, stdout, stderr, wait_thr = Open3.popen3("cat")

    stdin.puts "hello from ractor"
    stdin.close
    result = stdout.read
    stdout.close
    stderr.close
    wait_thr.value

    result
  }

  result = r.value
  report "Spawn process inside Ractor", true, "Got: #{result.inspect}"
rescue => e
  report "Spawn process inside Ractor", false, "#{e.class}: #{e.message}"
end

# =============================================================================
# TEST 2: Ractor owns process, notifies parent
# =============================================================================
section "TEST 2: Ractor owns process, notifies parent"

begin
  main = Ractor.current

  watcher = Ractor.new(main) do |parent|
    require 'open3'
    stdin, stdout, stderr, wait_thr = Open3.popen3("cat")
    pid = wait_thr.pid

    parent << [:spawned, pid]

    stdin.puts "test message"
    stdin.close
    data = stdout.read
    stdout.close
    stderr.close

    status = wait_thr.value
    parent << [:completed, pid, status.exitstatus, data.chomp]

    :done
  end

  msg1 = Ractor.receive
  msg2 = Ractor.receive
  report "Ractor owns process lifecycle", true, [msg1, msg2].inspect
rescue => e
  report "Ractor owns process lifecycle", false, "#{e.class}: #{e.message}"
end

# =============================================================================
# TEST 3: Multiple processes from coordinator
# =============================================================================
section "TEST 3: Multiple processes from coordinator"

begin
  main = Ractor.current

  coordinator = Ractor.new(main) do |parent|
    require 'open3'

    3.times do |i|
      stdin, stdout, stderr, wait_thr = Open3.popen3("echo process_#{i}")
      data = stdout.read.chomp
      stdin.close
      stdout.close
      stderr.close
      wait_thr.value
      parent << [:process_completed, i, data]
    end

    :all_done
  end

  results = []
  3.times { results << Ractor.receive }
  final = coordinator.value

  report "Multiple processes from coordinator", true, {results: results, final: final}.inspect
rescue => e
  report "Multiple processes from coordinator", false, "#{e.class}: #{e.message}"
end

# =============================================================================
# TEST 4: Command/response pattern
# =============================================================================
section "TEST 4: Command/response pattern"

begin
  main = Ractor.current

  watcher = Ractor.new(main) do |parent|
    require 'open3'

    stdin, stdout, stderr, wait_thr = Open3.popen3("cat")
    parent << [:ready, wait_thr.pid]

    running = true
    while running
      cmd = Ractor.receive
      case cmd
      in [:write, data]
        stdin.write(data)
        stdin.flush
        parent << [:wrote, data.bytesize]
      in [:close_input]
        stdin.close
        parent << [:input_closed]
      in [:read_all]
        data = stdout.read
        parent << [:stdout_data, data]
      in [:wait_exit]
        status = wait_thr.value
        stdout.close
        stderr.close
        parent << [:exited, status.exitstatus]
        running = false
      end
    end

    :watcher_done
  end

  responses = []
  responses << Ractor.receive  # :ready

  watcher << [:write, "hello\n"]
  responses << Ractor.receive

  watcher << [:write, "world\n"]
  responses << Ractor.receive

  watcher << [:close_input]
  responses << Ractor.receive

  watcher << [:read_all]
  responses << Ractor.receive

  watcher << [:wait_exit]
  responses << Ractor.receive

  report "Command/response pattern", true, responses.inspect
rescue => e
  report "Command/response pattern", false, "#{e.class}: #{e.message}\n#{e.backtrace.first(2).join("\n")}"
end

# =============================================================================
# TEST 5: Async with internal threads
# =============================================================================
section "TEST 5: Async with internal threads"

begin
  main = Ractor.current

  watcher = Ractor.new(main) do |parent|
    require 'open3'

    stdin, stdout, stderr, wait_thr = Open3.popen3("cat")
    parent << [:ready, wait_thr.pid]

    # Thread to read stdout and send to parent
    stdout_thread = Thread.new do
      while line = stdout.gets
        parent << [:stdout_line, line.chomp]
      end
      parent << [:stdout_eof]
    end

    # Thread to monitor for death
    death_thread = Thread.new do
      status = wait_thr.value
      parent << [:process_exited, status.exitstatus]
    end

    # Main loop handles incoming commands
    running = true
    while running
      cmd = Ractor.receive
      case cmd
      in [:write, data]
        stdin.write(data)
        stdin.flush
      in [:close_input]
        stdin.close
      in [:shutdown]
        running = false
      end
    end

    stdout_thread.join
    stderr.close
    death_thread.join

    :watcher_done
  end

  messages = []
  messages << Ractor.receive  # :ready

  watcher << [:write, "async line 1\n"]
  watcher << [:write, "async line 2\n"]
  watcher << [:close_input]

  # Collect async messages
  loop do
    msg = Ractor.receive
    messages << msg
    break if msg[0] == :process_exited
  end

  watcher << [:shutdown]
  watcher.value  # Wait for clean shutdown

  report "Async with internal threads", true, messages.inspect
rescue => e
  report "Async with internal threads", false, "#{e.class}: #{e.message}\n#{e.backtrace.first(2).join("\n")}"
end

# =============================================================================
# TEST 6: Ractor.monitor for crash detection
# =============================================================================
section "TEST 6: Ractor.monitor for crash detection"

begin
  main = Ractor.current

  crasher = Ractor.new(main) do |parent|
    parent << [:starting]
    sleep 0.1
    raise "Intentional crash!"
  end

  crasher.monitor(main.default_port)

  messages = []
  messages << Ractor.receive  # :starting
  messages << Ractor.receive  # Should be :aborted

  success = messages[1] == :aborted
  report "Ractor.monitor for crash detection", success, messages.inspect
rescue => e
  report "Ractor.monitor for crash detection", false, "#{e.class}: #{e.message}"
end

# =============================================================================
# TEST 7: Ractor.monitor for normal exit
# =============================================================================
section "TEST 7: Ractor.monitor for normal exit"

begin
  main = Ractor.current

  worker = Ractor.new(main) do |parent|
    parent << [:working]
    sleep 0.1
    parent << [:done]
    :finished
  end

  worker.monitor(main.default_port)

  messages = []
  messages << Ractor.receive  # :working
  messages << Ractor.receive  # :done
  messages << Ractor.receive  # Should be :exited

  success = messages[2] == :exited
  report "Ractor.monitor for normal exit", success, messages.inspect
rescue => e
  report "Ractor.monitor for normal exit", false, "#{e.class}: #{e.message}"
end

# =============================================================================
# FINAL: Complete Shellac Pattern
# =============================================================================
section "FINAL: Complete Shellac Pattern"

begin
  main = Ractor.current

  # Complete pattern:
  # - Ractor owns and spawns the process
  # - Internal threads handle async stdout/stderr
  # - Command loop handles stdin writes
  # - Parent monitors the watcher for crashes
  # - Clean shutdown protocol

  watcher = Ractor.new(main) do |parent|
    require 'open3'

    stdin, stdout, stderr, wait_thr = Open3.popen3("cat")
    pid = wait_thr.pid

    parent << [:process_started, pid]

    # Thread to stream stdout
    stdout_reader = Thread.new do
      while line = stdout.gets
        parent << [:stdout, line]
      end
      parent << [:stdout_closed]
    end

    # Thread to stream stderr
    stderr_reader = Thread.new do
      while line = stderr.gets
        parent << [:stderr, line]
      end
      parent << [:stderr_closed]
    end

    # Thread to detect death
    death_monitor = Thread.new do
      status = wait_thr.value
      parent << [:process_died, pid, status.exitstatus]
    end

    # Command loop
    running = true
    while running
      cmd = Ractor.receive
      case cmd
      in [:stdin, data]
        begin
          stdin.write(data)
          stdin.flush
        rescue Errno::EPIPE
          # Process closed its stdin
        end
      in [:close_stdin]
        stdin.close rescue nil
      in [:kill, signal]
        Process.kill(signal, pid) rescue nil
      in [:shutdown]
        running = false
      end
    end

    # Clean up
    stdout_reader.join
    stderr_reader.join
    death_monitor.join

    :watcher_finished
  end

  # Monitor the watcher
  watcher.monitor(main.default_port)

  messages = []
  messages << Ractor.receive  # :process_started

  # Send some data
  watcher << [:stdin, "hello shellac\n"]
  watcher << [:stdin, "goodbye shellac\n"]
  watcher << [:close_stdin]

  # Collect events until process dies
  loop do
    msg = Ractor.receive
    messages << msg
    break if msg[0] == :process_died
  end

  watcher << [:shutdown]
  final = watcher.value

  # Should get :exited from monitor
  monitor_msg = Ractor.receive
  messages << [:watcher_exited, monitor_msg]

  report "Complete Shellac Pattern", true, {messages: messages, final: final}.inspect

  puts
  puts "=" * 60
  puts "SUCCESS! Full bidirectional process watcher with death notification!"
  puts "=" * 60

rescue => e
  report "Complete Shellac Pattern", false, "#{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
end

puts
puts "=" * 60
puts "SPIKE COMPLETE"
puts "=" * 60

__END__

# === SPIKE C FINDINGS ===
#
# TEST RESULTS (All 8 tests PASSED):
# ----------------------------------
# TEST 1: Spawn process inside Ractor              - OK
# TEST 2: Ractor owns process lifecycle            - OK
# TEST 3: Multiple processes from coordinator      - OK
# TEST 4: Command/response pattern                 - OK
# TEST 5: Async with internal threads              - OK
# TEST 6: Ractor.monitor for crash detection       - OK
# TEST 7: Ractor.monitor for normal exit           - OK
# FINAL:  Complete Shellac Pattern                 - OK
#
# WHAT WORKED:
# - Spawning processes INSIDE Ractors with Open3.popen3 - WORKS!
# - This is the key insight: let the Ractor own the entire process lifecycle
# - Threads inside Ractors for async I/O - WORKS!
# - Ractor.monitor(port) for death notification - WORKS! (:exited, :aborted)
# - Message passing via parent << msg and Ractor.receive - WORKS!
# - Process.kill(signal, pid) from within Ractor - WORKS!
# - Pattern matching with `in` for cleaner command handling - WORKS!
# - Multiple concurrent readers (stdout, stderr) with threads - WORKS!
# - Clean shutdown protocol with :shutdown command - WORKS!
#
# WHAT DIDN'T WORK (in earlier attempts):
# - Passing IO objects from main to Ractor - isolation violation
# - Process.wait2(pid) in Ractor when process spawned in main - ECHILD
# - Passing Thread objects (Process::Waiter) to Ractors - not shareable
# - Ractor.yield - does not exist in Ruby 4.0!
# - Ractor.take - replaced by r.value in Ruby 4.0
#
# RUBY 4.0 RACTOR API (different from earlier proposals):
# - r.value replaces r.take (gets final return value, blocks until done)
# - r << msg or r.send(msg) to send message to Ractor
# - Ractor.receive or Ractor.recv to receive message in current Ractor
# - r.monitor(port) for death notification (:exited on normal, :aborted on crash)
# - r.default_port for getting the port to send to
# - r.join waits for Ractor to finish (like Thread#join)
# - NO Ractor.yield - use parent << msg instead for streaming values
#
# KEY INSIGHT:
# The process MUST be spawned INSIDE the Ractor, not outside!
# This is because:
# 1. IO objects can't cross Ractor boundaries (isolation)
# 2. Process.wait2 only works on children of the current Ractor/context
# 3. Ractors are like separate process spaces for child management
# 4. The Ractor that spawns the process "owns" it
#
# ARCHITECTURE THAT EMERGED:
# 1. Ractor spawns the process internally with Open3.popen3
# 2. Ractor owns stdin, stdout, stderr, and wait_thr
# 3. Internal threads handle async reading from stdout/stderr
# 4. Command loop receives [:stdin, data], [:close_stdin], [:kill, sig]
# 5. Thread waits on wait_thr.value for process death
# 6. All events sent to parent via parent << [:event, ...]
# 7. Parent monitors Ractor with r.monitor(port) for Ractor crashes
#
# SHELLAC PATTERN (VERIFIED WORKING):
#
#   main Ractor
#       |
#       +-- creates ProcessWatcher Ractor (passing parent ref)
#       +-- monitors it with watcher.monitor(main.default_port)
#       |
#       +-- sends: [:stdin, data], [:close_stdin], [:kill, sig], [:shutdown]
#       +-- receives: [:process_started, pid], [:stdout, line],
#       |             [:stderr, line], [:stdout_closed], [:stderr_closed],
#       |             [:process_died, pid, exit_code],
#       |             :exited (from monitor when watcher Ractor terminates)
#
#   ProcessWatcher Ractor
#       |-- spawns process with Open3.popen3
#       |-- owns all IOs internally
#       |-- stdout_thread: reads stdout line by line, sends to parent
#       |-- stderr_thread: reads stderr line by line, sends to parent
#       |-- death_thread: waits on wait_thr.value, sends to parent
#       |-- main loop: Ractor.receive -> process command -> write to stdin
#       |-- on :shutdown: joins all threads, returns :watcher_finished
#
# EXAMPLE OUTPUT FROM FINAL TEST:
# {messages: [[:process_started, 49933],
#             [:stdout, "hello shellac\n"],
#             [:stdout, "goodbye shellac\n"],
#             [:stdout_closed],
#             [:stderr_closed],
#             [:process_died, 49933, 0],
#             [:watcher_exited, :exited]],
#  final: :watcher_finished}
#
# IMPLICATIONS FOR SHELLAC:
# 1. ProcessWatcher must spawn process internally - cannot receive FDs
# 2. Open3 works inside Ractors (require 'open3' inside the Ractor block)
# 3. Threads inside Ractor for concurrent I/O - works great
# 4. Use monitor for crash detection of watcher itself (two-level death detection)
# 5. Line-buffered reading with .gets works perfectly
# 6. For raw/binary mode, use .readpartial or .read_nonblock instead
# 7. PTY support would need similar pattern - spawn PTY inside Ractor
# 8. Pattern matching with `in` makes command handling clean
#
# NEXT STEPS FOR SHELLAC:
# 1. Create ProcessWatcher class encapsulating this pattern
# 2. Add options: command, args, env, cwd, line_buffered vs raw
# 3. Add timeout support (Timer thread + Process.kill)
# 4. Test with interactive processes (shells, REPLs)
# 5. Consider supervision/restart patterns (auto-restart on crash)
# 6. Build higher-level "Port" abstraction on top
# 7. Add bidirectional flow control if needed
# 8. Consider multiple named ports for different message types
