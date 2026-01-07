# frozen_string_literal: true

desc "Run tests"

flag :all, "-a", "--all", desc: "Run all tests including chaos/stress"
flag :quick, "--quick", desc: "Run only minitest (fastest)"
flag :standalone, "-s", "--standalone", desc: "Run standalone tests only"
flag :stress, "--stress", desc: "Run stress tests"

include Devex::Exec

MINITEST_FILES = %w[
  test/registry_test.rb
  test/worker_test.rb
  test/supervisor_test.rb
].freeze

STANDALONE_TESTS = %w[
  test/proctor_test.rb
  test/proctor_api_test.rb
  test/mcp_client_test.rb
].freeze

CHAOS_TESTS = %w[
  test/mcp_chaos_test.rb
].freeze

STRESS_TESTS = %w[
  test/proctor_stress_test.rb
].freeze

def run
  if quick
    run_minitest
  elsif standalone
    run_standalone
  elsif stress
    run_stress
  elsif all
    run_minitest
    run_standalone
    run_chaos
    run_stress
  else
    # Default: minitest + quick standalone (skip chaos/stress)
    run_minitest
    run_standalone
  end
end

def run_minitest
  puts "\n=== Running Minitest ==="
  # Run each test file - they require test_helper which sets up minitest
  MINITEST_FILES.each do |test_file|
    cmd("ruby", test_file).exit_on_failure!
  end
end

def run_standalone
  STANDALONE_TESTS.each do |test_file|
    puts "\n=== Running #{test_file} ==="
    cmd("ruby", test_file).exit_on_failure!
  end
end

def run_chaos
  CHAOS_TESTS.each do |test_file|
    puts "\n=== Running #{test_file} ==="
    cmd("ruby", test_file).exit_on_failure!
  end
end

def run_stress
  STRESS_TESTS.each do |test_file|
    puts "\n=== Running #{test_file} (this may take a while) ==="
    cmd("ruby", test_file).exit_on_failure!
  end
end
