# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "umi"

# Suppress Ractor experimental warnings during tests
# (They're informational, not errors)
Warning[:experimental] = false if Warning.respond_to?(:[]=)

module Umi
  # Base class for Umi tests with common utilities.
  class TestCase < Minitest::Test
    # Timeout for operations that should complete quickly
    FAST_TIMEOUT = 2.0

    # Timeout for operations that may take longer
    SLOW_TIMEOUT = 10.0

    # Wait for a condition with timeout.
    # Useful for async operations where we need to poll.
    #
    # @param timeout [Numeric] Maximum seconds to wait
    # @param interval [Numeric] Polling interval
    # @yield Block that returns truthy when condition is met
    # @return [Boolean] Whether condition was met
    def wait_for(timeout: FAST_TIMEOUT, interval: 0.05)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return true if yield

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return false if remaining <= 0

        sleep [interval, remaining].min
      end
    end

    # Assert that a condition becomes true within timeout.
    #
    # @param timeout [Numeric] Maximum seconds to wait
    # @param msg [String] Failure message
    # @yield Block that returns truthy when condition is met
    def assert_eventually(timeout: FAST_TIMEOUT, msg: nil, &)
      result = wait_for(timeout: timeout, &)
      assert result, msg || "Condition not met within #{timeout}s"
    end

    # Assert that a block raises one of the given exception types.
    #
    # @param exceptions [Array<Class>] Exception classes to expect
    # @yield Block that should raise
    def assert_raises_one_of(*exceptions)
      raised = nil
      begin
        yield
      rescue *exceptions => e
        raised = e
      end
      assert raised, "Expected one of #{exceptions.inspect} but nothing was raised"
      raised
    end

    # Create a simple worker Ractor that waits for a message then exits.
    # Useful for testing registration/monitoring without full Worker class.
    #
    # @return [Ractor]
    def create_simple_ractor = Ractor.new { Ractor.receive }

    # Stop a simple ractor by sending it any message.
    #
    # @param ractor [Ractor]
    def stop_simple_ractor(ractor)
      ractor << :stop
    rescue StandardError
      nil
    end

    # Wait for a message on a port with timeout.
    # Returns [value, :received] or [nil, :timeout]
    #
    # @param port [Ractor::Port]
    # @param timeout [Numeric]
    # @return [Array]
    def receive_with_timeout(port, timeout: FAST_TIMEOUT)
      timer_port = Ractor::Port.new
      timer      = Thread.new do
        sleep(timeout)
        begin
          timer_port << :timeout
        rescue StandardError
          nil
        end
      end

      begin
        ready, value = Ractor.select(port, timer_port)
        if ready == timer_port
          [nil, :timeout]
        else
          [value, :received]
        end
      ensure
        timer.kill
      end
    end
  end
end
