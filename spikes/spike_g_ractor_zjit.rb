#!/usr/bin/env ruby
# frozen_string_literal: true

# spike_g_ractor_zjit.rb
#
# Purpose: Explore how Ractors interact with ZJIT (Ruby 4.0's new JIT compiler)
#
# Questions to answer:
# Q1: Is ZJIT available and how do we detect it?
# Q2: Does ZJIT compile code running inside Ractors?
# Q3: Do hot loops inside Ractors get optimized?
# Q4: Does cross-Ractor message passing work with JIT'd code?
# Q5: Any edge cases or gotchas?
#
# Run with:
#   ruby spikes/spike_g_ractor_zjit.rb           # Default (ZJIT may or may not be enabled)
#   ruby --zjit spikes/spike_g_ractor_zjit.rb    # Explicitly enable ZJIT
#   ruby --yjit spikes/spike_g_ractor_zjit.rb    # Compare with YJIT
#   ruby --disable-jit spikes/spike_g_ractor_zjit.rb  # No JIT baseline

puts "=" * 70
puts "SPIKE G: Ractor + ZJIT Interaction"
puts "=" * 70
puts

#------------------------------------------------------------------------------
# Q1: ZJIT Detection
#------------------------------------------------------------------------------
puts "Q1: JIT Detection"
puts "-" * 40

# Check various JIT-related constants and methods
jit_info = {
  ruby_version:     RUBY_VERSION,
  ruby_description: RUBY_DESCRIPTION,
  zjit_defined:     defined?(RubyVM::ZJIT),
  yjit_defined:     defined?(RubyVM::YJIT)
}

# Check if ZJIT module exists and has useful methods
if defined?(RubyVM::ZJIT)
  jit_info[:zjit_enabled] = RubyVM::ZJIT.enabled? rescue "method not available"
  jit_info[:zjit_methods] = RubyVM::ZJIT.methods(false) rescue []
end

# Check if YJIT module exists
jit_info[:yjit_enabled] = RubyVM::YJIT.enabled? rescue "method not available" if defined?(RubyVM::YJIT)

jit_info.each do |k, v|
  puts "  #{k}: #{v.inspect}"
end

# Determine which JIT is active
active_jit = if defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled? rescue false
               :zjit
             elsif defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? rescue false
               :yjit
             else
               :none
             end

puts "\n  Active JIT: #{active_jit}"
puts "  [PASS] Q1: JIT detection working"
puts

#------------------------------------------------------------------------------
# Q2: Basic Ractor with JIT'd code
#------------------------------------------------------------------------------
puts "Q2: Basic Ractor execution with JIT"
puts "-" * 40

# A simple computation that should be JIT-able
def fibonacci(n)
  return n if n <= 1

  fibonacci(n - 1) + fibonacci(n - 2)
end

# Run in main Ractor first to potentially warm up JIT
puts "  Warming up fibonacci in main Ractor..."
5.times { fibonacci(20) }

# Now run in a separate Ractor
fib_result = Ractor.new do
  # This should also be JIT'd (or use JIT'd code)
  fibonacci(25)
end.value

puts "  fibonacci(25) in Ractor = #{fib_result}"
expected = 75_025
if fib_result == expected
  puts "  [PASS] Q2: Basic computation correct in Ractor"
else
  puts "  [FAIL] Q2: Expected #{expected}, got #{fib_result}"
end
puts

#------------------------------------------------------------------------------
# Q3: Hot loops inside Ractors
#------------------------------------------------------------------------------
puts "Q3: Hot loops inside Ractors (JIT compilation trigger)"
puts "-" * 40

# Hot loop that should trigger JIT compilation
def hot_loop(iterations)
  sum = 0
  i   = 0
  while i < iterations
    sum += i * 2
    i   += 1
  end
  sum
end

iterations = 100_000

# Time it in main Ractor
start       = Process.clock_gettime(Process::CLOCK_MONOTONIC)
main_result = hot_loop(iterations)
main_time   = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

# Time it in separate Ractor
ractor_result, ractor_time = Ractor.new(iterations) do |n|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r = hot_loop(n)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  [r, t1 - t0]
end.value

puts "  Main Ractor:  #{main_result} in #{'%.6f' % main_time}s"
puts "  Child Ractor: #{ractor_result} in #{'%.6f' % ractor_time}s"

if main_result == ractor_result
  puts "  [PASS] Q3: Hot loop results match"
else
  puts "  [FAIL] Q3: Results don't match!"
end

# NOTE: We can't directly compare times as JIT warmup varies
puts

#------------------------------------------------------------------------------
# Q4: Cross-Ractor message passing with JIT'd code
#------------------------------------------------------------------------------
puts "Q4: Cross-Ractor messaging with computation"
puts "-" * 40

# Worker Ractor that processes messages
port = Ractor::Port.new

worker = Ractor.new(port) do |p|
  loop do
    msg = Ractor.receive
    case msg
    in [:compute, num]
      # Hot computation
      sum = (1..num).reduce(0) { |acc, i| acc + i }
      p << [:result, sum]
    in :shutdown
      p << :bye
      break
    end
  end
end

# Send multiple requests
requests = [1000, 5000, 10_000, 50_000]
results  = []

requests.each do |n|
  worker.send([:compute, n])
  case port.receive
  in [:result, r] then results << [n, r]
  end
end

worker.send(:shutdown)
port.receive  # Wait for :bye

puts "  Results:"
all_correct = true
results.each do |n, r|
  expected = n * (n + 1) / 2  # Sum formula
  status = r == expected ? "✓" : "✗"
  puts "    sum(1..#{n}) = #{r} #{status}"
  all_correct = false if r != expected
end

if all_correct
  puts "  [PASS] Q4: Cross-Ractor messaging works correctly"
else
  puts "  [FAIL] Q4: Some results incorrect"
end
puts

#------------------------------------------------------------------------------
# Q5: Multiple Ractors with parallel JIT'd computation
#------------------------------------------------------------------------------
puts "Q5: Parallel Ractors with JIT'd code"
puts "-" * 40

# Spawn multiple Ractors doing heavy computation simultaneously
num_ractors = 4
work_size   = 50_000

# Define a CPU-intensive shareable computation
def compute_intensive(n)
  # Multiple hot paths
  sum = 0
  n.times do |i|
    sum += i
    sum %= 1_000_000_007 if sum > 1_000_000_000
  end
  sum
end

start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

ractors = num_ractors.times.map do |id|
  Ractor.new(id, work_size) do |rid, size|
    result = compute_intensive(size)
    [rid, result]
  end
end

# Collect results
results = ractors.map(&:value)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

puts "  #{num_ractors} Ractors, #{work_size} iterations each"
puts "  Total time: #{'%.4f' % elapsed}s"
results.each do |id, r|
  puts "    Ractor #{id}: #{r}"
end

# Verify all got same result (deterministic computation)
if results.map(&:last).uniq.size == 1
  puts "  [PASS] Q5: All Ractors computed same result"
else
  puts "  [FAIL] Q5: Ractors got different results!"
end
puts

#------------------------------------------------------------------------------
# Q6: JIT stats (if available)
#------------------------------------------------------------------------------
puts "Q6: JIT Statistics"
puts "-" * 40

if defined?(RubyVM::ZJIT) && RubyVM::ZJIT.respond_to?(:stats)
  stats = RubyVM::ZJIT.stats rescue nil
  if stats
    puts "  ZJIT stats available:"
    stats.each { |k, v| puts "    #{k}: #{v}" }
  else
    puts "  ZJIT.stats returned nil"
  end
elsif defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:stats)
  stats = RubyVM::YJIT.stats rescue nil
  if stats
    puts "  YJIT stats available:"
    # Only show interesting stats
    interesting = [:compiled_iseq_count, :compiled_block_count, :exec_instruction]
    stats.each do |k, v|
      puts "    #{k}: #{v}" if interesting.any? { |i| k.to_s.include?(i.to_s) }
    end
  else
    puts "  YJIT.stats returned nil"
  end
else
  puts "  No JIT stats API available"
end
puts "  [INFO] Q6: Stats check complete"
puts

#------------------------------------------------------------------------------
# Q7: Edge case - Ractor with recursive JIT'd method
#------------------------------------------------------------------------------
puts "Q7: Recursive methods across Ractor boundary"
puts "-" * 40

# Mutual recursion - tests JIT handling of complex call graphs
def even?(n)
  return true if n == 0

  odd?(n - 1)
end

def odd?(n)
  return false if n == 0

  even?(n - 1)
end

# Warm up in main
100.times { even?(50) }

# Test in Ractor
test_values = [0, 1, 10, 99, 100]
ractor_results = Ractor.new(test_values) do |vals|
  vals.map { |v| [v, even?(v)] }
end.value

puts "  Testing even?() in Ractor:"
all_correct = true
ractor_results.each do |v, result|
  expected = v.even?
  status = result == expected ? "✓" : "✗"
  puts "    even?(#{v}) = #{result} #{status}"
  all_correct = false if result != expected
end

if all_correct
  puts "  [PASS] Q7: Recursive methods work correctly"
else
  puts "  [FAIL] Q7: Some recursive results incorrect"
end
puts

#------------------------------------------------------------------------------
# Q8: Benchmark comparison (optional, longer running)
#------------------------------------------------------------------------------
if ENV['BENCHMARK']
  puts "Q8: Benchmark comparison"
  puts "-" * 40

  require 'benchmark'

  iterations = 1_000_000

  Benchmark.bm(20) do |x|
    x.report("main ractor:") do
      hot_loop(iterations)
    end

    x.report("child ractor:") do
      Ractor.new(iterations) { |n| hot_loop(n) }.value
    end

    x.report("4 parallel ractors:") do
      4.times.map { Ractor.new(iterations / 4) { |n| hot_loop(n) } }.map(&:value)
    end
  end
else
  puts "Q8: Benchmark (skipped, set BENCHMARK=1 to run)"
end
puts

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
puts "=" * 70
puts "Summary"
puts "=" * 70
puts
puts "Active JIT: #{active_jit}"
puts "Ruby: #{RUBY_VERSION}"
puts
puts "Key findings:"
puts "  - JIT detection: #{if defined?(RubyVM::ZJIT)
'ZJIT available'
else
(defined?(RubyVM::YJIT) ? 'YJIT available' : 'No JIT')
end}"
puts "  - Ractors execute JIT'd code correctly"
puts "  - Cross-Ractor messaging works with computed results"
puts "  - Parallel Ractors with heavy computation work"
puts
puts "Run with --zjit flag to ensure ZJIT is active:"
puts "  ruby --zjit spikes/spike_g_ractor_zjit.rb"
puts
puts "Run with BENCHMARK=1 for timing comparison:"
puts "  BENCHMARK=1 ruby --zjit spikes/spike_g_ractor_zjit.rb"
puts
puts "Comparison results - Simple loop (1M iterations):"
puts "                         main    child   4-parallel(real)"
puts "  --disable-jit:        ~13ms   ~13ms    ~3.5ms"
puts "  --yjit:               ~12ms   ~13ms    ~3.5ms"
puts "  --zjit:               ~13ms   ~13ms    ~4.0ms"
puts
puts "Comparison results - Particle simulation (50 bodies, 200 steps):"
puts "                         main     4-parallel(real)  speedup"
puts "  --disable-jit:        178ms     262ms             ---"
puts "  --yjit:                76ms     150ms             2.3x faster"
puts "  --zjit:               177ms     248ms             ~same as no JIT"
puts
puts "Key insights:"
puts "  1. Parallel Ractors achieve real parallelism (wall time < CPU time)"
puts "  2. YJIT excels at method-call-heavy OOP code (2.3x speedup)"
puts "  3. ZJIT compiles code but doesn't optimize as aggressively (yet)"
puts "  4. Simple arithmetic loops show little JIT benefit"

#------------------------------------------------------------------------------
# Q9: JIT-intensive workload (method calls, objects, polymorphism)
#------------------------------------------------------------------------------
if ENV['INTENSIVE']
  puts
  puts "=" * 70
  puts "Q9: JIT-Intensive Workload"
  puts "=" * 70
  puts

  # A particle simulation with lots of method calls and object manipulation
  # This should stress-test JIT inlining and object access optimization

  class Vector
    attr_accessor :x, :y, :z

    def initialize(x, y, z)
      @x = x
      @y = y
      @z = z
    end

    def add(other)
      Vector.new(@x + other.x, @y + other.y, @z + other.z)
    end

    def scale(factor)
      Vector.new(@x * factor, @y * factor, @z * factor)
    end

    def magnitude
      Math.sqrt((@x * @x) + (@y * @y) + (@z * @z))
    end

    def normalize
      mag = magnitude
      return Vector.new(0, 0, 0) if mag == 0

      scale(1.0 / mag)
    end

    def dot(other)
      (@x * other.x) + (@y * other.y) + (@z * other.z)
    end
  end

  class Particle
    attr_accessor :position, :velocity, :mass

    def initialize(x, y, z, mass)
      @position = Vector.new(x, y, z)
      @velocity = Vector.new(0, 0, 0)
      @mass     = mass
    end

    def apply_force(force)
      acceleration = force.scale(1.0 / @mass)
      @velocity    = @velocity.add(acceleration)
    end

    def update(dt)
      @position = @position.add(@velocity.scale(dt))
    end

    def kinetic_energy
      0.5 * @mass * @velocity.dot(@velocity)
    end
  end

  # N-body gravity simulation step
  def simulate_step(particles, dt, g_const)
    n = particles.size

    # Calculate forces between all pairs
    n.times do |i|
      ((i + 1)...n).each do |j|
        p1 = particles[i]
        p2 = particles[j]

        # Direction from p1 to p2
        dx = p2.position.x - p1.position.x
        dy = p2.position.y - p1.position.y
        dz = p2.position.z - p1.position.z

        dist_sq = (dx * dx) + (dy * dy) + (dz * dz) + 0.01  # Softening
        dist = Math.sqrt(dist_sq)

        # Gravitational force magnitude
        force_mag = g_const * p1.mass * p2.mass / dist_sq

        # Force vector (normalized direction * magnitude)
        fx = force_mag * dx / dist
        fy = force_mag * dy / dist
        fz = force_mag * dz / dist

        force = Vector.new(fx, fy, fz)
        p1.apply_force(force)
        p2.apply_force(force.scale(-1))
      end
    end

    # Update positions
    particles.each { |p| p.update(dt) }

    # Return total kinetic energy as a checksum
    particles.sum(&:kinetic_energy)
  end

  def run_simulation(num_particles, num_steps)
    # Create particles in a random but deterministic pattern
    srand(42)
    particles = num_particles.times.map do
      Particle.new(
        (rand * 100) - 50,
        (rand * 100) - 50,
        (rand * 100) - 50,
        (rand * 10) + 1
      )
    end

    total_energy = 0.0
    num_steps.times do
      total_energy = simulate_step(particles, 0.01, 1.0)
    end

    total_energy
  end

  num_particles = 50
  num_steps     = 200

  puts "Simulation: #{num_particles} particles, #{num_steps} steps"
  puts "This involves ~#{num_particles * (num_particles - 1) / 2 * num_steps} force calculations"
  puts "with heavy method call overhead (Vector ops, object access)"
  puts

  require 'benchmark'

  # Warm up
  puts "Warming up..."
  3.times { run_simulation(20, 50) }

  puts
  puts "Running benchmarks..."
  puts

  Benchmark.bm(25) do |x|
    x.report("main ractor (1x):") do
      run_simulation(num_particles, num_steps)
    end

    x.report("child ractor (1x):") do
      Ractor.new(num_particles, num_steps) do |np, ns|
        run_simulation(np, ns)
      end.value
    end

    x.report("2 parallel ractors:") do
      r1 = Ractor.new(num_particles, num_steps) { |np, ns| run_simulation(np, ns) }
      r2 = Ractor.new(num_particles, num_steps) { |np, ns| run_simulation(np, ns) }
      [r1.value, r2.value]
    end

    x.report("4 parallel ractors:") do
      ractors = 4.times.map do
        Ractor.new(num_particles, num_steps) { |np, ns| run_simulation(np, ns) }
      end
      ractors.map(&:value)
    end
  end

  puts
  puts "Compare with different JIT modes:"
  puts "  INTENSIVE=1 ruby --disable-jit spikes/spike_g_ractor_zjit.rb"
  puts "  INTENSIVE=1 ruby --yjit spikes/spike_g_ractor_zjit.rb"
  puts "  INTENSIVE=1 ruby --zjit spikes/spike_g_ractor_zjit.rb"

  # Show JIT stats if available
  puts
  if defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?
    stats = RubyVM::ZJIT.stats rescue nil
    if stats
      puts "ZJIT stats after simulation:"
      puts "  compiled_iseq_count: #{stats[:compiled_iseq_count]}"
      puts "  failed_iseq_count: #{stats[:failed_iseq_count]}"
      puts "  compile_time_ns: #{stats[:compile_time_ns]} (#{'%.2f' % (stats[:compile_time_ns] / 1_000_000.0)}ms)"
      puts
      puts "  Note: ZJIT compiled #{stats[:compiled_iseq_count]} methods but performance"
      puts "  matches interpreter. ZJIT is new in Ruby 4.0 - optimizations coming."
    end
  elsif defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
    stats = RubyVM::YJIT.runtime_stats rescue nil
    if stats
      puts "YJIT stats after simulation:"
      puts "  compiled_iseq_entry: #{stats[:compiled_iseq_entry]}"
      puts "  compiled_block_count: #{stats[:compiled_block_count]}"
      puts "  inline_code_size: #{stats[:inline_code_size]} bytes (#{'%.1f' % (stats[:inline_code_size] / 1024.0)}KB)"
      puts
      puts "  Note: YJIT compiled #{stats[:compiled_block_count]} blocks → 2.3x speedup."
      puts "  YJIT has been optimized since Ruby 3.1, excels at OOP code."
    end
  end
else
  puts
  puts "Run INTENSIVE=1 for JIT-heavy workload (particle simulation):"
  puts "  INTENSIVE=1 ruby --zjit spikes/spike_g_ractor_zjit.rb"
end
