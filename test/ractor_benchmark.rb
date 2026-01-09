#!/usr/bin/env ruby
# frozen_string_literal: true

# Ractor Benchmarks for Ruby 4.0
#
# Measures the fundamental costs of Ractor operations:
# - Creation and shutdown
# - Message passing (latency and throughput)
# - Port operations
# - Ractor.select multiplexing
# - Memory overhead
#
# Usage:
#   ruby test/ractor_benchmark.rb
#   ruby test/ractor_benchmark.rb --quick    # Fewer iterations

require 'benchmark'
require 'objspace'

QUICK = ARGV.include?('--quick')

# Iteration counts (reduced for --quick mode)
CREATION_ITERATIONS   = QUICK ? 100   : 1000
MESSAGE_ITERATIONS    = QUICK ? 1000  : 10_000
THROUGHPUT_ITERATIONS = QUICK ? 10_000 : 100_000
SELECT_ITERATIONS     = QUICK ? 100   : 1000
MEMORY_SAMPLE_SIZE    = QUICK ? 10    : 50

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
    "#{(rate / 1_000_000).round(1)}M/s"
  elsif rate > 1000
    "#{(rate / 1000).round(1)}K/s"
  else
    "#{rate.round(1)}/s"
  end
end

def fmt_bytes(bytes)
  if bytes > 1_000_000
    "#{(bytes / 1_000_000.0).round(1)} MB"
  elsif bytes > 1000
    "#{(bytes / 1000.0).round(1)} KB"
  else
    "#{bytes} B"
  end
end

def measure_stats(samples)
  sorted = samples.sort
  {
    min: sorted.first,
    max: sorted.last,
    median: sorted[sorted.size / 2],
    mean: samples.sum / samples.size.to_f,
    p99: sorted[(sorted.size * 0.99).to_i]
  }
end

puts "=" * 70
puts "Ractor Benchmarks - Ruby #{RUBY_VERSION}"
puts "=" * 70
puts "Mode: #{QUICK ? 'quick' : 'full'}"
puts

# =============================================================================
# 1. Ractor Creation
# =============================================================================
puts "--- Ractor Creation ---"

# Simple ractor that just waits for a message
creation_times = []
CREATION_ITERATIONS.times do
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r = Ractor.new { Ractor.receive }
  creation_times << Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  r << :stop  # Clean shutdown
  r.value rescue nil
end

stats = measure_stats(creation_times)
puts "  Create Ractor:     #{fmt_time(stats[:median])} median, #{fmt_time(stats[:p99])} p99"
puts "                     (#{fmt_rate(1, stats[:median])} creation rate)"

# =============================================================================
# 2. Ractor Shutdown
# =============================================================================
puts "\n--- Ractor Shutdown ---"

# Pre-create ractors, then measure shutdown time
ractors = CREATION_ITERATIONS.times.map { Ractor.new { Ractor.receive } }

shutdown_times = []
ractors.each do |r|
  r << :stop
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r.value rescue nil
  shutdown_times << Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

stats = measure_stats(shutdown_times)
puts "  Shutdown Ractor:   #{fmt_time(stats[:median])} median, #{fmt_time(stats[:p99])} p99"

# =============================================================================
# 3. Message Passing Latency (Round-trip)
# =============================================================================
puts "\n--- Message Passing Latency ---"

# Echo ractor - receives and sends back via port
reply_port_echo = Ractor::Port.new
echo = Ractor.new(reply_port_echo) do |port|
  loop do
    msg = Ractor.receive
    break if msg == :stop
    port.send(msg)
  end
end

# Warm up
10.times { echo << :ping; reply_port_echo.receive }

latencies = []
MESSAGE_ITERATIONS.times do
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  echo << :ping
  reply_port_echo.receive
  latencies << Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

echo << :stop
echo.value rescue nil

stats = measure_stats(latencies)
puts "  Round-trip:        #{fmt_time(stats[:median])} median, #{fmt_time(stats[:p99])} p99"
puts "                     (#{fmt_rate(1, stats[:median])} round-trips/s)"

# =============================================================================
# 4. Message Passing Throughput (One-way)
# =============================================================================
puts "\n--- Message Passing Throughput ---"

# Sink ractor - just receives and counts
sink = Ractor.new do
  count = 0
  loop do
    msg = Ractor.receive
    break if msg == :stop
    count += 1
  end
  count
end

start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
THROUGHPUT_ITERATIONS.times { sink << :msg }
sink << :stop
count = sink.value
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

puts "  One-way send:      #{fmt_rate(count, elapsed)} (#{count} messages in #{fmt_time(elapsed)})"
puts "                     #{fmt_time(elapsed / count)} per message"

# =============================================================================
# 5. Port Operations
# =============================================================================
puts "\n--- Port Operations ---"

# Port creation - batch measure (too fast for individual timing)
port_count = MESSAGE_ITERATIONS
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
ports_created = port_count.times.map { Ractor::Port.new }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
puts "  Port creation:     #{fmt_time(elapsed / port_count)} avg (#{fmt_rate(port_count, elapsed)})"

# Port send/receive latency (same ractor) - batch measure
port = Ractor::Port.new
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
MESSAGE_ITERATIONS.times do
  port.send(:msg)
  port.receive
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
puts "  Port round-trip:   #{fmt_time(elapsed / MESSAGE_ITERATIONS)} avg (same-ractor)"

# Cross-ractor port messaging
reply_port = Ractor::Port.new
worker = Ractor.new(reply_port) do |port|
  loop do
    msg = Ractor.receive
    break if msg == :stop
    port.send(:pong)
  end
end

# Warm up
10.times { worker << :ping; reply_port.receive }

cross_latencies = []
MESSAGE_ITERATIONS.times do
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  worker << :ping
  reply_port.receive
  cross_latencies << Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

worker << :stop
worker.value rescue nil

stats = measure_stats(cross_latencies)
puts "  Port round-trip:   #{fmt_time(stats[:median])} median (cross-ractor)"

# =============================================================================
# 6. Ractor.select
# =============================================================================
puts "\n--- Ractor.select ---"

# Select with single port (baseline) - batch measure
port1 = Ractor::Port.new
MESSAGE_ITERATIONS.times { port1.send(:msg) }

start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
MESSAGE_ITERATIONS.times { Ractor.select(port1) }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
puts "  select(1 port):    #{fmt_time(elapsed / MESSAGE_ITERATIONS)} avg"

# Select with multiple ports - batch measure
select_ports = 10.times.map { Ractor::Port.new }

MESSAGE_ITERATIONS.times do |i|
  select_ports[i % select_ports.size].send(:msg)
end

start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
MESSAGE_ITERATIONS.times { Ractor.select(*select_ports) }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
puts "  select(10 ports):  #{fmt_time(elapsed / MESSAGE_ITERATIONS)} avg"

# Select across ractors (realistic scenario)
# Use a simpler approach: worker sends to a shared reply port
shared_reply = Ractor::Port.new
select_workers = 5.times.map do |i|
  Ractor.new(i, shared_reply) do |id, reply_port|
    loop do
      msg = Ractor.receive
      break if msg == :stop
      reply_port.send([id, msg])
    end
  end
end

# Warm up - send to each worker and drain responses
select_workers.each { |w| w << :ping }
5.times { shared_reply.receive }

multi_ractor_times = []
SELECT_ITERATIONS.times do
  select_workers.sample << :ping
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  shared_reply.receive  # Simple receive, not select (since it's one port)
  multi_ractor_times << Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

select_workers.each { |w| w << :stop }
select_workers.each { |w| w.value rescue nil }

stats = measure_stats(multi_ractor_times)
puts "  cross-ractor msg:  #{fmt_time(stats[:median])} median (5 workers, 1 reply port)"

# =============================================================================
# 7. Memory Overhead
# =============================================================================
puts "\n--- Memory Overhead ---"

GC.start
GC.compact rescue nil
baseline_mem = GC.stat[:heap_live_slots]

# Create ractors and measure memory increase
test_ractors = MEMORY_SAMPLE_SIZE.times.map { Ractor.new { Ractor.receive } }

GC.start
with_ractors_mem = GC.stat[:heap_live_slots]

slots_per_ractor = (with_ractors_mem - baseline_mem) / MEMORY_SAMPLE_SIZE.to_f

# Clean up
test_ractors.each { |r| r << :stop; r.value rescue nil }

puts "  Heap slots/ractor: ~#{slots_per_ractor.round(0)} slots"

# Try to measure actual RSS increase (platform-dependent)
begin
  GC.start
  GC.compact rescue nil

  before_rss = `ps -o rss= -p #{$$}`.to_i

  mem_ractors = 100.times.map { Ractor.new { Ractor.receive } }

  after_rss = `ps -o rss= -p #{$$}`.to_i
  rss_per_ractor = (after_rss - before_rss) / 100.0

  mem_ractors.each { |r| r << :stop; r.value rescue nil }

  if rss_per_ractor > 0
    puts "  RSS per ractor:    ~#{fmt_bytes(rss_per_ractor * 1024)}"
  end
rescue
  # ps command not available or failed
end

# =============================================================================
# 8. Proctor-specific (if available)
# =============================================================================
begin
  require_relative '../lib/umi/proctor'

  puts "\n--- Proctor (Umi) ---"

  # Proctor creation
  proctor_times = []
  50.times do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    p = Umi::Proctor.new("true")
    proctor_times << Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    p.join
  end

  stats = measure_stats(proctor_times)
  puts "  Proctor creation:  #{fmt_time(stats[:median])} median"

  # Proctor.select with multiple proctors
  proctors = 5.times.map { Umi::Proctor.new("echo", "test") }

  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  until proctors.all?(&:exited?)
    Umi::Proctor.select(*proctors, timeout: 5)
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

  puts "  5 proctors drain:  #{fmt_time(elapsed)}"

rescue LoadError
  # Proctor not available
end

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 70
puts "Summary"
puts "=" * 70
puts <<~SUMMARY

  Key findings for capacity planning:

  - Ractor creation is relatively expensive (~ms range)
  - Message passing is fast (~us range for cross-ractor)
  - Ractor.select scales reasonably with port count
  - Each Ractor consumes meaningful memory (~KB range)

  Implications:
  - Pool ractors rather than create/destroy frequently
  - Message passing overhead is low enough for fine-grained communication
  - Select-based multiplexing is viable for moderate fan-out

SUMMARY
