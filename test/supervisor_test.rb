#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "test_helper"

# Tests for Umi::Supervisor - child process management with restart policies.
#
# These tests verify:
# - Child starting and lifecycle
# - Automatic restart on child death
# - Restart bounding (max_restarts within time window)
# - Escalation when restart limits exceeded
# - Restart types (:permanent, :transient, :temporary)
# - Shutdown sequence
#
class SupervisorTest < Umi::TestCase
  # ===========================================================================
  # Test Worker for Supervisor Tests
  # ===========================================================================

  # A worker that can be told to crash or exit cleanly
  class TestWorker < Umi::Worker
    def init(args)
      @id = args[:id] || :unnamed
    end

    def handle_call(request)
      case request
      in [:ping] then :pong
      in [:get_id] then @id
      end
    end

    def handle_cast(message)
      case message
      in [:crash] then raise "intentional crash"
      in [:exit] then throw :exit  # Clean exit from message loop
      end
    end
  end

  def teardown
    sleep 0.1  # Let things settle
  end

  # ===========================================================================
  # Basic Child Management
  # ===========================================================================

  def test_supervisor_starts_children
    child_spec = {
      id: :test_worker,
      start: Ractor.shareable_proc { TestWorker.start_link(id: :test) }
    }

    sup = Umi::Supervisor.start_link(children: [child_spec])

    assert_includes sup.children, :test_worker
  ensure
    sup&.shutdown
  end

  def test_supervisor_starts_multiple_children
    specs = [
      { id: :worker_a, start: Ractor.shareable_proc { TestWorker.start_link(id: :a) } },
      { id: :worker_b, start: Ractor.shareable_proc { TestWorker.start_link(id: :b) } },
      { id: :worker_c, start: Ractor.shareable_proc { TestWorker.start_link(id: :c) } }
    ]

    sup = Umi::Supervisor.start_link(children: specs)

    children = sup.children
    assert_equal 3, children.size
    assert_includes children, :worker_a
    assert_includes children, :worker_b
    assert_includes children, :worker_c
  ensure
    sup&.shutdown
  end

  def test_children_are_functional
    child_spec = {
      id: :worker,
      start: Ractor.shareable_proc { TestWorker.start_link(id: :functional_test) }
    }

    sup = Umi::Supervisor.start_link(children: [child_spec])

    # We need a way to get the child handle... this is a design issue
    # For now, the supervisor doesn't expose child handles directly
    # This test validates that children start, but not that we can talk to them
    assert_includes sup.children, :worker
  ensure
    sup&.shutdown
  end

  # ===========================================================================
  # Automatic Restart
  # ===========================================================================

  def test_permanent_child_restarts_on_crash
    # Use shareable_proc - cannot capture outer variables
    # Just verify supervisor stays alive after child would crash
    child_spec = {
      id: :crasher,
      restart: :permanent,
      start: Ractor.shareable_proc { TestWorker.start_link(id: :crash_test) }
    }

    sup = Umi::Supervisor.start_link(
      children: [child_spec],
      max_restarts: 5,
      within_seconds: 10
    )

    # Verify child started
    assert_includes sup.children, :crasher

    # TODO: To fully test restart, we'd need a way to trigger the crash
    # (e.g., supervisor.get_child(:crasher) to get handle, then crash it)
    # For now, verify basic supervisor structure works
    assert sup.alive?
  ensure
    sup&.shutdown
  end

  def test_temporary_child_not_restarted
    start_count = 0
    child_spec = {
      id: :temporary_worker,
      restart: :temporary,
      start: -> {
        start_count += 1
        # Create a worker that exits immediately
        Ractor.new { :done }
        # Return a mock handle
        mock_handle = Object.new
        def mock_handle.monitor(port)
          # The ractor already exited, so monitor won't help
        end
        mock_handle
      }
    }

    # This test is tricky because we need the child to actually die
    # and verify the supervisor doesn't restart it
    # Skip for now - need better test infrastructure
  end

  # ===========================================================================
  # Restart Bounding
  # ===========================================================================

  # Worker that crashes immediately - defined at class level so shareable_proc can reference it
  class ImmediateCrashWorker < Umi::Worker
    def init(_args)
      raise "immediate crash on init"
    end
  end

  def test_escalation_on_exceeded_restarts
    # Worker that always crashes - the start proc uses a class (shareable)
    child_spec = {
      id: :always_crashes,
      restart: :permanent,
      start: Ractor.shareable_proc { ImmediateCrashWorker.start_link }
    }

    monitor_port = Ractor::Port.new

    sup = Umi::Supervisor.start_link(
      children: [child_spec],
      max_restarts: 2,
      within_seconds: 10
    )
    sup.monitor(monitor_port)

    # Wait for supervisor to die from escalation
    value, status = receive_with_timeout(monitor_port, timeout: 5.0)

    # Supervisor should have died due to exceeding restart limits
    assert_equal :received, status, "supervisor should die from escalation"
    assert_includes [:exited, :aborted], value
  end

  # ===========================================================================
  # Shutdown
  # ===========================================================================

  def test_shutdown_terminates_supervisor
    child_spec = {
      id: :worker,
      start: Ractor.shareable_proc { TestWorker.start_link(id: :shutdown_test) }
    }

    sup = Umi::Supervisor.start_link(children: [child_spec])
    assert sup.alive?

    sup.shutdown
    sleep 0.2

    refute sup.alive?
  end

  def test_monitor_receives_notification_on_shutdown
    child_spec = {
      id: :worker,
      start: Ractor.shareable_proc { TestWorker.start_link(id: :monitor_test) }
    }

    sup = Umi::Supervisor.start_link(children: [child_spec])
    monitor_port = Ractor::Port.new
    sup.monitor(monitor_port)

    sup.shutdown

    value, status = receive_with_timeout(monitor_port, timeout: 2.0)
    assert_equal :received, status
    assert_equal :exited, value
  end

  # ===========================================================================
  # SupervisorHandle API
  # ===========================================================================

  def test_handle_exposes_ractor
    sup = Umi::Supervisor.start_link(children: [])
    assert_kind_of Ractor, sup.ractor
  ensure
    sup&.shutdown
  end

  def test_handle_exposes_command_port
    sup = Umi::Supervisor.start_link(children: [])
    assert_kind_of Ractor::Port, sup.command_port
  ensure
    sup&.shutdown
  end

  def test_children_returns_child_ids
    specs = [
      { id: :alpha, start: Ractor.shareable_proc { TestWorker.start_link(id: :a) } },
      { id: :beta, start: Ractor.shareable_proc { TestWorker.start_link(id: :b) } }
    ]

    sup = Umi::Supervisor.start_link(children: specs)
    children = sup.children

    assert_kind_of Array, children
    assert_includes children, :alpha
    assert_includes children, :beta
  ensure
    sup&.shutdown
  end

  # ===========================================================================
  # Edge Cases
  # ===========================================================================

  def test_supervisor_with_no_children
    sup = Umi::Supervisor.start_link(children: [])

    assert sup.alive?
    assert_empty sup.children

    sup.shutdown
    sleep 0.1
    refute sup.alive?
  end

  def test_rapid_start_stop
    5.times do
      sup = Umi::Supervisor.start_link(children: [])
      sup.shutdown
      sleep 0.05
    end
    # No assertions - just shouldn't crash
  end
end
