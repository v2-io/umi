#!/usr/bin/env ruby
# frozen_string_literal: true

# Spike E: Investigating Ractor Sequencing Issues
# ================================================
# Goal: Find the minimal reproduction case for why sequential
# Ractor creation/destruction causes hangs.

require 'open3'

# Dump all thread backtraces on SIGINT (Ctrl-C) or SIGQUIT (Ctrl-\)
def dump_threads
  puts "\n" + "=" * 60
  puts "THREAD DUMP (#{Thread.list.size} threads)"
  puts "=" * 60
  Thread.list.each_with_index do |t, i|
    status = t.status || "dead"
    name = t.name || "Thread-#{i}"
    puts "\n--- #{name} [#{status}] ---"
    if t.backtrace
      puts t.backtrace.first(15).join("\n")
      puts "  ... (#{t.backtrace.size - 15} more)" if t.backtrace.size > 15
    else
      puts "  (no backtrace available)"
    end
  end
  puts "\n" + "=" * 60
end

# Also try to show Ractor info
def dump_ractors
  puts "\n" + "=" * 60
  puts "RACTOR INFO"
  puts "=" * 60
  puts "Current Ractor: #{Ractor.current.inspect}"
  puts "Main Ractor: #{Ractor.main.inspect}"
  # Note: There's no Ractor.list in Ruby 4.0
  puts "=" * 60
end

Signal.trap("INT") do
  puts "\n\n*** SIGINT received - dumping state ***"
  dump_threads
  dump_ractors
  exit 1
end

Signal.trap("QUIT") do
  puts "\n\n*** SIGQUIT received - dumping state ***"
  dump_threads
  dump_ractors
  # Don't exit - allow continuing
end

puts "=" * 60
puts "SPIKE E: Ractor Sequencing Investigation"
puts "Ruby #{RUBY_VERSION}"
puts "(Ctrl-C to dump threads and exit, Ctrl-\\ to dump and continue)"
puts "=" * 60

$stdout.sync = true

def test(name, count: 5)
  print "#{name} (#{count}x)... "
  start = Time.now
  begin
    count.times do |i|
      yield i
    end
    elapsed = Time.now - start
    puts "OK (#{elapsed.round(2)}s)"
    true
  rescue => e
    puts "FAIL: #{e.class}: #{e.message}"
    false
  end
end

# =============================================================================
# TEST 1: Basic Ractors (no ports, no threads)
# =============================================================================
test("Basic Ractors") do |i|
  r = Ractor.new(i) { |n| n * 2 }
  r.value
end

# =============================================================================
# TEST 2: Ractors with Ports
# =============================================================================
test("Ractors with Ports") do |i|
  port = Ractor::Port.new
  r = Ractor.new(port, i) { |p, n| p.send(n * 2) }
  port.receive
  r.value
end

# =============================================================================
# TEST 3: Ractors with internal Threads
# =============================================================================
test("Ractors with Threads") do |i|
  port = Ractor::Port.new
  r = Ractor.new(port, i) do |p, n|
    t = Thread.new { p.send(n * 2) }
    t.join
    :done
  end
  port.receive
  r.value
end

# =============================================================================
# TEST 4: Ractors with Open3.popen3
# =============================================================================
test("Ractors with popen3") do |i|
  port = Ractor::Port.new
  r = Ractor.new(port, i) do |p, n|
    require 'open3'
    stdin, stdout, stderr, wait_thr = Open3.popen3("echo #{n}")
    result = stdout.read
    stdin.close; stdout.close; stderr.close
    wait_thr.value
    p.send(result.chomp)
    :done
  end
  port.receive
  r.value
end

# =============================================================================
# TEST 5: Ractors with popen3 + async threads (like Shellac)
# =============================================================================
test("Ractors with popen3 + threads") do |i|
  port = Ractor::Port.new
  r = Ractor.new(port, i) do |p, n|
    require 'open3'
    stdin, stdout, stderr, wait_thr = Open3.popen3("echo #{n}")

    stdout_thread = Thread.new do
      while line = stdout.gets
        p.send([:stdout, line])
      end
    end

    death_thread = Thread.new do
      status = wait_thr.value
      p.send([:died, status.exitstatus])
    end

    stdin.close
    stdout_thread.join
    stderr.close
    death_thread.join
    :done
  end

  # Drain messages
  loop do
    msg = port.receive
    break if msg[0] == :died
  end

  r.value
end

# =============================================================================
# TEST 6: Ractors with command loop (like Shellac's watcher)
# =============================================================================
test("Ractors with command loop", count: 3) do |i|
  port = Ractor::Port.new
  r = Ractor.new(port, i) do |p, n|
    require 'open3'
    stdin, stdout, stderr, wait_thr = Open3.popen3("cat")

    p.send([:started, wait_thr.pid])

    stdout_thread = Thread.new do
      while line = stdout.gets
        p.send([:stdout, line])
      end
      p.send([:stdout_closed])
    end

    death_thread = Thread.new do
      status = wait_thr.value
      p.send([:died, status.exitstatus])
    end

    # Command loop
    running = true
    while running
      cmd = Ractor.receive
      case cmd
      in [:stdin, data]
        stdin.write(data)
        stdin.flush
      in [:close]
        stdin.close
      in [:shutdown]
        running = false
      end
    end

    stdout_thread.join
    stderr.close
    death_thread.join
    :done
  end

  port.receive  # :started

  r << [:stdin, "hello #{i}\n"]
  port.receive  # :stdout

  r << [:close]

  # Drain until died
  loop do
    msg = port.receive
    break if msg[0] == :died
  end

  r << [:shutdown]
  r.value
end

# =============================================================================
# TEST 7: With Ractor.select (no timeout)
# =============================================================================
test("Ractors with Ractor.select") do |i|
  port = Ractor::Port.new
  r = Ractor.new(port, i) do |p, n|
    p.send(n * 2)
    :done
  end

  source, msg = Ractor.select(port)
  r.value
end

# =============================================================================
# TEST 8: With Ractor.select and timer Thread
# =============================================================================
test("Ractors with select + timer Thread") do |i|
  port = Ractor::Port.new
  timer_port = Ractor::Port.new

  r = Ractor.new(port, i) do |p, n|
    sleep 0.01  # Small delay
    p.send(n * 2)
    :done
  end

  # Timer thread
  Thread.new { sleep 1.0; timer_port.send(:timeout) rescue nil }

  source, msg = Ractor.select(port, timer_port)
  r.value
end

# =============================================================================
# TEST 9: With Ractor.monitor
# =============================================================================
test("Ractors with monitor") do |i|
  port = Ractor::Port.new
  r = Ractor.new(port, i) do |p, n|
    p.send(n * 2)
    :done
  end

  r.monitor(port)

  msgs = []
  2.times { msgs << port.receive }  # value + :exited

  r.value rescue nil
end

# =============================================================================
# TEST 10: Full Shellac pattern
# =============================================================================
test("Full Shellac pattern", count: 3) do |i|
  inbox = Ractor::Port.new

  watcher = Ractor.new(inbox, i) do |inbox, n|
    require 'open3'
    stdin, stdout, stderr, wait_thr = Open3.popen3("cat")
    pid = wait_thr.pid
    inbox.send([:started, pid])

    stdout_thread = Thread.new do
      while line = stdout.gets
        inbox.send([:stdout, line])
      end
      inbox.send([:stdout_closed])
    end

    stderr_thread = Thread.new do
      while line = stderr.gets
        inbox.send([:stderr, line])
      end
      inbox.send([:stderr_closed])
    end

    death_thread = Thread.new do
      status = wait_thr.value
      exit_code = status.exited? ? status.exitstatus : nil
      signal = status.signaled? ? Signal.signame(status.termsig) : nil
      inbox.send([:process_died, pid, exit_code, signal])
    end

    running = true
    while running
      cmd = Ractor.receive
      case cmd
      in [:stdin, data]
        stdin.write(data) rescue nil
        stdin.flush rescue nil
      in [:close_stdin]
        stdin.close rescue nil
      in [:kill, sig]
        Process.kill(sig, pid) rescue nil
      in [:shutdown]
        running = false
      end
    end

    stdout_thread.join
    stderr_thread.join
    death_thread.join
    :watcher_done
  end

  # Monitor watcher for crashes
  watcher.monitor(inbox)

  # Wait for started
  msg = inbox.receive
  raise "Expected started, got #{msg}" unless msg[0] == :started

  # Send data
  watcher << [:stdin, "test #{i}\n"]

  # Receive stdout
  msg = inbox.receive
  raise "Expected stdout, got #{msg}" unless msg[0] == :stdout

  # Close stdin
  watcher << [:close_stdin]

  # Drain until process_died
  loop do
    msg = inbox.receive
    break if msg[0] == :process_died
  end

  # Shutdown watcher
  watcher << [:shutdown]

  # Wait for watcher to finish
  result = watcher.value
  raise "Expected :watcher_done, got #{result}" unless result == :watcher_done
end

puts
puts "=" * 60
puts "All tests completed!"
puts "=" * 60
