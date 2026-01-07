#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "test_helper"

# Tests for Umi::Worker - supervised process abstraction with call/cast.
#
# These tests verify:
# - Call (synchronous request/response)
# - Cast (asynchronous fire-and-forget)
# - Lifecycle (init, terminate, shutdown)
# - Error handling and propagation
# - Monitor notifications
# - Timeout behavior
# - Concurrent access
#
class WorkerTest < Umi::TestCase
  # ===========================================================================
  # Test Worker Implementations
  # ===========================================================================

  # Simple echo worker for basic tests
  class EchoWorker < Umi::Worker
    def init(args)
      @prefix      = args[:prefix] || ""
      @initialized = true
    end

    def handle_call(request)
      case request
      in [:echo, msg] then "#{@prefix}#{msg}"
      in [:get_prefix] then @prefix
      in [:initialized?] then @initialized
      in [:raise_error, msg] then raise msg
      in [:slow, seconds]
        sleep(seconds)
        :done
      end
    end

    def handle_cast(message)
      case message
      in [:set_prefix, p] then @prefix = p
      end
    end

    attr_accessor :terminate_reason

    def terminate(reason) = @terminate_reason = reason
  end

  # Counter worker for state tests
  class CounterWorker < Umi::Worker
    def init(args) = @count = args[:start] || 0

    def handle_call(request)
      case request
      in [:get] then @count
      in [:add, n] then @count += n
      end
    end

    def handle_cast(message)
      case message
      in [:increment] then @count += 1
      in [:decrement] then @count -= 1
      in [:add, n] then @count    += n
      end
    end
  end

  # Worker that crashes on demand
  class CrashWorker < Umi::Worker
    def handle_call(request)
      case request
      in [:crash] then raise "intentional crash"
      in [:ok] then :ok
      end
    end
  end

  def teardown = sleep 0.05

  # ===========================================================================
  # Basic Call Operations
  # ===========================================================================

  def test_call_returns_response
    handle   = EchoWorker.start_link(prefix: "Hello, ")
    response = handle.call([:echo, "World"])

    assert_equal "Hello, World", response
  ensure
    handle&.shutdown
  end

  def test_call_with_different_arguments
    handle = CounterWorker.start_link(start: 100)

    assert_equal 100, handle.call([:get])
    assert_equal 110, handle.call([:add, 10])
    assert_equal 110, handle.call([:get])
  ensure
    handle&.shutdown
  end

  def test_call_receives_init_args
    handle = EchoWorker.start_link(prefix: "Test:")

    assert_equal "Test:", handle.call([:get_prefix])
    assert handle.call([:initialized?])
  ensure
    handle&.shutdown
  end

  def test_multiple_calls_in_sequence
    handle = CounterWorker.start_link(start: 0)

    10.times { handle.call([:add, 1]) }

    assert_equal 10, handle.call([:get])
  ensure
    handle&.shutdown
  end

  # ===========================================================================
  # Cast Operations
  # ===========================================================================

  def test_cast_is_fire_and_forget
    handle = CounterWorker.start_link(start: 0)

    # Cast returns immediately
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    handle.cast([:increment])
    handle.cast([:increment])
    handle.cast([:increment])
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

    # Should be nearly instant (no waiting for response)
    assert_operator elapsed, :<, 0.1, "cast should return immediately"

    # Give casts time to process
    sleep 0.1
    assert_equal 3, handle.call([:get])
  ensure
    handle&.shutdown
  end

  def test_cast_modifies_state_seen_by_call
    handle = EchoWorker.start_link(prefix: "A:")

    assert_equal "A:test", handle.call([:echo, "test"])

    handle.cast([:set_prefix, "B:"])
    sleep 0.05  # Give cast time to process

    assert_equal "B:test", handle.call([:echo, "test"])
  ensure
    handle&.shutdown
  end

  def test_cast_returns_handle_for_chaining
    handle = CounterWorker.start_link(start: 0)

    result = handle.cast([:increment])

    assert_equal handle, result, "cast should return handle for chaining"
  ensure
    handle&.shutdown
  end

  def test_many_casts_in_rapid_succession
    handle = CounterWorker.start_link(start: 0)

    100.times { handle.cast([:increment]) }
    sleep 0.2  # Give casts time to process

    assert_equal 100, handle.call([:get])
  ensure
    handle&.shutdown
  end

  # ===========================================================================
  # Error Handling
  # ===========================================================================

  def test_call_error_returns_worker_error
    handle = EchoWorker.start_link

    error = assert_raises(Umi::WorkerError) do
      handle.call([:raise_error, "test error message"])
    end

    assert_includes error.message, "test error message"
  ensure
    handle&.shutdown
  end

  def test_call_timeout_raises_timeout_error
    handle = EchoWorker.start_link

    error = assert_raises(Timeout::Error) do
      handle.call([:slow, 10], timeout: 0.1)
    end

    assert_includes error.message, "0.1s"
  
    # Worker may still be processing - can't cleanly shutdown
  end

  def test_worker_continues_after_call_error
    handle = EchoWorker.start_link(prefix: "still:")

    # First call raises error
    assert_raises(Umi::WorkerError) do
      handle.call([:raise_error, "boom"])
    end

    # Worker should still be alive and functional
    assert_equal "still:alive", handle.call([:echo, "alive"])
  ensure
    handle&.shutdown
  end

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  def test_shutdown_terminates_worker
    handle = EchoWorker.start_link
    assert handle.alive?

    handle.shutdown
    sleep 0.1

    # After shutdown, calls should fail
    assert_raises_one_of(Timeout::Error, Ractor::ClosedError) do
      handle.call([:echo, "test"], timeout: 0.5)
    end
  end

  def test_monitor_receives_exited_on_clean_shutdown
    handle       = EchoWorker.start_link
    monitor_port = Ractor::Port.new
    handle.monitor(monitor_port)

    handle.shutdown
    sleep 0.1

    value, status = receive_with_timeout(monitor_port, timeout: 1.0)
    assert_equal :received, status
    assert_equal :exited, value
  end

  def test_monitor_receives_notification_on_crash
    # Worker that crashes in message loop (not caught by handle_call wrapper)
    crash_worker_class = Class.new(Umi::Worker) do
      def handle_cast(message)
        case message
        in [:crash_hard] then raise "hard crash in message loop"
        end
      end
    end

    handle       = crash_worker_class.start_link
    monitor_port = Ractor::Port.new
    handle.monitor(monitor_port)

    # Cast triggers crash (cast doesn't expect response, so exception escapes)
    handle.cast([:crash_hard])

    # Wait for crash notification
    value, status = receive_with_timeout(monitor_port, timeout: 2.0)
    assert_equal :received, status, "should receive monitor notification"
    assert_includes [:exited, :aborted], value
  end

  # ===========================================================================
  # Concurrent Access
  # ===========================================================================

  def test_concurrent_calls_are_serialized
    handle = CounterWorker.start_link(start: 0)

    # Multiple threads all calling
    threads = 10.times.map do
      Thread.new { 10.times { handle.call([:add, 1]) } }
    end

    threads.each(&:join)

    # All 100 increments should have happened
    assert_equal 100, handle.call([:get])
  ensure
    handle&.shutdown
  end

  def test_concurrent_casts_dont_lose_messages
    handle = CounterWorker.start_link(start: 0)

    # Many threads all casting
    threads = 20.times.map do
      Thread.new { 50.times { handle.cast([:increment]) } }
    end

    threads.each(&:join)
    sleep 0.3  # Give casts time to process

    # All 1000 increments should have happened
    assert_equal 1000, handle.call([:get])
  ensure
    handle&.shutdown
  end

  def test_mixed_calls_and_casts
    handle = CounterWorker.start_link(start: 0)

    threads = []

    # Some threads do calls
    5.times do
      threads << Thread.new { 10.times { handle.call([:add, 1]) } }
    end

    # Some threads do casts
    5.times do
      threads << Thread.new { 10.times { handle.cast([:add, 1]) } }
    end

    threads.each(&:join)
    sleep 0.1

    # All 100 operations should have happened
    assert_equal 100, handle.call([:get])
  ensure
    handle&.shutdown
  end

  # ===========================================================================
  # WorkerHandle API
  # ===========================================================================

  def test_handle_exposes_ractor
    handle = EchoWorker.start_link

    assert_kind_of Ractor, handle.ractor
  ensure
    handle&.shutdown
  end

  def test_handle_exposes_command_port
    handle = EchoWorker.start_link

    assert_kind_of Ractor::Port, handle.command_port
  ensure
    handle&.shutdown
  end

  def test_handle_alive_initially_true
    handle = EchoWorker.start_link

    assert handle.alive?
  ensure
    handle&.shutdown
  end

  # ===========================================================================
  # Edge Cases
  # ===========================================================================

  def test_multiple_workers_independent
    h1 = CounterWorker.start_link(start: 100)
    h2 = CounterWorker.start_link(start: 200)

    h1.call([:add, 10])
    h2.call([:add, 20])

    assert_equal 110, h1.call([:get])
    assert_equal 220, h2.call([:get])
  ensure
    h1&.shutdown
    h2&.shutdown
  end

  def test_rapid_start_stop_cycles
    10.times do
      handle = CounterWorker.start_link(start: 0)
      handle.call([:add, 1])
      handle.shutdown
      sleep 0.02
    end
    # No assertions - just shouldn't crash or leak
  end

  def test_default_init_works
    # Worker with no init override should still work
    plain_class = Class.new(Umi::Worker) do
      def handle_call(request)
        case request
        in [:ping] then :pong
        end
      end
    end

    handle = plain_class.start_link
    assert_equal :pong, handle.call([:ping])
  ensure
    handle&.shutdown
  end
end
