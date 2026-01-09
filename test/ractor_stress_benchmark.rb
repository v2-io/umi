#!/usr/bin/env ruby
# frozen_string_literal: true

# Ractor Stress Benchmark - High Load Testing
#
# Tests Ractor primitives under sustained high load to verify
# performance characteristics hold at scale.

ITERATIONS = (ARGV[0] || 100_000).to_i
RACTOR_COUNT = (ARGV[1] || 100).to_i

def fmt_time(seconds)
  if seconds < 0.000_001
    "#{(seconds * 1_000_000_000).round(1)} ns"
  elsif seconds < 0.001
    "#{(seconds * 1_000_000).round(1)} us"
  elsif seconds < 1
    "#{(seconds * 1000).round(2)} ms"
  else
    "#{seconds.round(3)} s"
  end
end

def fmt_rate(count, seconds)
  rate = count / seconds
  if rate > 1_000_000
    "#{(rate / 1_000_000).round(2)}M/s"
  elsif rate > 1000
    "#{(rate / 1000).round(1)}K/s"
  else
    "#{rate.round(1)}/s"
  end
end

puts "=" * 70
puts "Ractor Stress Benchmark - Ruby #{RUBY_VERSION}"
puts "=" * 70
puts "Iterations: #{ITERATIONS.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
puts "Ractor pool size: #{RACTOR_COUNT}"
puts

# =============================================================================
# 1. Mass Ractor Creation/Destruction
# =============================================================================
puts "--- Mass Ractor Creation/Destruction ---"

# Create many ractors as fast as possible
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
ractors = RACTOR_COUNT.times.map { Ractor.new { Ractor.receive } }
create_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

puts "  Create #{RACTOR_COUNT} ractors: #{fmt_time(create_elapsed)} (#{fmt_rate(RACTOR_COUNT, create_elapsed)})"

# Shut them all down
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
ractors.each { |r| r << :stop }
ractors.each { |r| r.value rescue nil }
shutdown_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

puts "  Shutdown #{RACTOR_COUNT} ractors: #{fmt_time(shutdown_elapsed)} (#{fmt_rate(RACTOR_COUNT, shutdown_elapsed)})"

# Repeated create/destroy cycles
cycles = RACTOR_COUNT
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
cycles.times do
  r = Ractor.new { Ractor.receive }
  r << :stop
  r.value rescue nil
end
cycle_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

puts "  Create+destroy cycles: #{fmt_time(cycle_elapsed / cycles)} avg (#{fmt_rate(cycles, cycle_elapsed)})"

# =============================================================================
# 2. Sustained Message Throughput
# =============================================================================
puts "\n--- Sustained Message Throughput ---"

# Single producer -> single consumer
reply = Ractor::Port.new
consumer = Ractor.new(reply) do |port|
  count = 0
  loop do
    msg = Ractor.receive
    break if msg == :stop
    count += 1
  end
  port.send(count)
end

start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
ITERATIONS.times { consumer << :msg }
consumer << :stop
received = reply.receive
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

puts "  1:1 throughput:    #{fmt_rate(received, elapsed)} (#{received} msgs in #{fmt_time(elapsed)})"

# Multiple producers -> single consumer (fan-in)
fan_in_reply = Ractor::Port.new
fan_in_consumer = Ractor.new(fan_in_reply) do |port|
  count = 0
  loop do
    msg = Ractor.receive
    break if msg == :stop
    count += 1
  end
  port.send(count)
end

producer_count = 10
msgs_per_producer = ITERATIONS / producer_count

producers = producer_count.times.map do
  Ractor.new(fan_in_consumer, msgs_per_producer) do |target, count|
    count.times { target << :msg }
  end
end

start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
producers.each { |p| p.value rescue nil }
fan_in_consumer << :stop
received = fan_in_reply.receive
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

puts "  #{producer_count}:1 fan-in:      #{fmt_rate(received, elapsed)} (#{received} msgs in #{fmt_time(elapsed)})"

# Single producer -> multiple consumers (fan-out via Ractor inbox)
consumer_count = 10
msgs_per_consumer = ITERATIONS / consumer_count
result_port = Ractor::Port.new

fan_out_consumers = consumer_count.times.map do |id|
  Ractor.new(id, msgs_per_consumer, result_port) do |my_id, expected, reply|
    count = 0
    expected.times { Ractor.receive; count += 1 }
    reply.send([my_id, count])
  end
end

start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
ITERATIONS.times do |i|
  fan_out_consumers[i % consumer_count] << :msg
end
results = consumer_count.times.map { result_port.receive }
total_received = results.map { |_, count| count }.sum
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

puts "  1:#{consumer_count} fan-out:     #{fmt_rate(total_received, elapsed)} (#{total_received} msgs in #{fmt_time(elapsed)})"

# =============================================================================
# 3. Port Stress Test
# =============================================================================
puts "\n--- Port Stress Test ---"

# Many ports, round-robin send/receive
port_count = 1000
stress_ports = port_count.times.map { Ractor::Port.new }

start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
ITERATIONS.times do |i|
  p = stress_ports[i % port_count]
  p.send(:msg)
  p.receive
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

puts "  #{port_count} ports round-robin: #{fmt_rate(ITERATIONS, elapsed)} (#{fmt_time(elapsed / ITERATIONS)} per op)"

# =============================================================================
# 4. Ractor.select Stress
# =============================================================================
puts "\n--- Ractor.select Stress ---"

# Select with increasing port counts
[10, 50, 100, 500].each do |n|
  next if n > port_count

  test_ports = n.times.map { Ractor::Port.new }
  test_iterations = [ITERATIONS, 10_000].min  # Cap iterations for large n

  # Pre-fill ports
  test_iterations.times { |i| test_ports[i % n].send(:msg) }

  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  test_iterations.times { Ractor.select(*test_ports) }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

  puts "  select(#{n.to_s.rjust(3)} ports):   #{fmt_rate(test_iterations, elapsed)} (#{fmt_time(elapsed / test_iterations)} per select)"
end

# =============================================================================
# 5. Parallel Worker Pool
# =============================================================================
puts "\n--- Parallel Worker Pool ---"

# Simulate realistic work: pool of workers processing jobs
pool_size = 20
jobs = ITERATIONS
reply_port = Ractor::Port.new

workers = pool_size.times.map do |id|
  Ractor.new(id, reply_port) do |worker_id, port|
    processed = 0
    loop do
      msg = Ractor.receive
      break if msg == :stop
      # Simulate tiny bit of work
      processed += 1
    end
    port.send([worker_id, processed])
  end
end

start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Distribute jobs round-robin
jobs.times do |i|
  workers[i % pool_size] << :work
end

# Shutdown and collect results
workers.each { |w| w << :stop }
results = pool_size.times.map { reply_port.receive }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

total_processed = results.map { |_, count| count }.sum
distribution = results.map { |id, count| count }.minmax

puts "  #{pool_size} workers, #{jobs} jobs: #{fmt_time(elapsed)} (#{fmt_rate(total_processed, elapsed)})"
puts "  Distribution: #{distribution[0]}-#{distribution[1]} jobs/worker"

# =============================================================================
# 6. Latency Under Load
# =============================================================================
puts "\n--- Latency Under Load ---"

# Measure round-trip latency while system is under load
load_port = Ractor::Port.new
latency_port = Ractor::Port.new

# Background load generator
load_worker = Ractor.new(load_port) do |port|
  count = 0
  loop do
    msg = Ractor.receive
    break if msg == :stop
    port.send(:ack)
    count += 1
  end
  count
end

# Latency probe worker
probe_worker = Ractor.new(latency_port) do |port|
  loop do
    msg = Ractor.receive
    break if msg == :stop
    port.send(:pong)
  end
end

# Generate background load in a thread
load_count = 0
load_thread = Thread.new do
  while load_count < ITERATIONS / 2
    load_worker << :ping
    load_port.receive
    load_count += 1
  end
end

# Measure probe latencies while load is running
sleep 0.01  # Let load start
latencies = []
1000.times do
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  probe_worker << :ping
  latency_port.receive
  latencies << Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

load_thread.join
load_worker << :stop
probe_worker << :stop
load_worker.value rescue nil
probe_worker.value rescue nil

sorted = latencies.sort
puts "  Under load (#{load_count} bg msgs):"
puts "    p50: #{fmt_time(sorted[latencies.size / 2])}"
puts "    p99: #{fmt_time(sorted[(latencies.size * 0.99).to_i])}"
puts "    max: #{fmt_time(sorted.last)}"

# =============================================================================
# 7. Memory Stability
# =============================================================================
puts "\n--- Memory Stability ---"

# Warm up and stabilize memory first
10.times do
  GC.start
  sleep 0.05
end
3.times { GC.compact rescue nil }

initial_rss = `ps -o rss= -p #{$$}`.to_i rescue 0

# Create/destroy many ractors to check for leaks
leak_test_cycles = 500
leak_test_cycles.times do
  r = Ractor.new { Ractor.receive }
  r << :stop
  r.value rescue nil
end

# Aggressive GC to reclaim
5.times do
  GC.start
  sleep 0.05
end
3.times { GC.compact rescue nil }

mid_rss = `ps -o rss= -p #{$$}`.to_i rescue 0

# Another round
leak_test_cycles.times do
  r = Ractor.new { Ractor.receive }
  r << :stop
  r.value rescue nil
end

5.times do
  GC.start
  sleep 0.05
end
3.times { GC.compact rescue nil }

final_rss = `ps -o rss= -p #{$$}`.to_i rescue 0

rss_change_1 = mid_rss - initial_rss
rss_change_2 = final_rss - mid_rss

puts "  After #{leak_test_cycles} cycles: RSS #{initial_rss} -> #{mid_rss} KB (#{rss_change_1 > 0 ? '+' : ''}#{rss_change_1})"
puts "  After #{leak_test_cycles} more:   RSS #{mid_rss} -> #{final_rss} KB (#{rss_change_2 > 0 ? '+' : ''}#{rss_change_2})"

if rss_change_2.abs < 500
  puts "  OK - memory stable after warmup"
elsif rss_change_2 > 2000
  puts "  WARNING - possible leak (#{rss_change_2} KB growth in second batch)"
else
  puts "  Likely OK - some growth but may be Ruby internals"
end

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 70
puts "Benchmark complete"
puts "=" * 70
