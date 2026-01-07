#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "test_helper"

# Tests for Umi::Registry - name-based Ractor lookup with auto-cleanup.
#
# These tests verify:
# - Basic CRUD operations (register, lookup, unregister, list)
# - Registration uniqueness and collision handling
# - Automatic cleanup when registered Ractors die
# - Concurrent access safety
# - Edge cases and error conditions
#
class RegistryTest < Umi::TestCase
  def setup
    @registry = Umi::Registry.new
    @ractors  = []  # Track for cleanup
  end

  def teardown
    @ractors.each do |r|
      r << :stop
    rescue StandardError
      nil
    end
    begin
      @registry.shutdown
    rescue StandardError
      nil
    end
    sleep 0.1  # Let things settle
  end

  # Helper to create and track a simple ractor
  def make_ractor
    r = create_simple_ractor
    @ractors << r
    r
  end

  # ===========================================================================
  # Basic Registration
  # ===========================================================================

  def test_register_returns_ok_on_success
    r      = make_ractor
    result = @registry.register(:test, r)
    assert_equal :ok, result
  end

  def test_lookup_returns_registered_ractor
    r = make_ractor
    @registry.register(:test, r)

    found = @registry.lookup(:test)
    assert_equal r, found
  end

  def test_lookup_returns_nil_for_unregistered_name
    result = @registry.lookup(:nonexistent)
    assert_nil result
  end

  def test_registered_returns_true_for_registered_name
    r = make_ractor
    @registry.register(:test, r)
    assert @registry.registered?(:test)
  end

  def test_registered_returns_false_for_unregistered_name = refute @registry.registered?(:nonexistent)

  def test_registration_collision_returns_error
    r1 = make_ractor
    r2 = make_ractor

    result1 = @registry.register(:same_name, r1)
    result2 = @registry.register(:same_name, r2)

    assert_equal :ok, result1
    assert_equal [:error, :already_registered], result2
  end

  def test_registration_with_symbol_name
    r = make_ractor
    @registry.register(:symbol_name, r)
    assert_equal r, @registry.lookup(:symbol_name)
  end

  def test_registration_with_string_name
    r = make_ractor
    @registry.register("string_name", r)
    assert_equal r, @registry.lookup("string_name")
  end

  # ===========================================================================
  # Unregistration
  # ===========================================================================

  def test_unregister_removes_name
    r = make_ractor
    @registry.register(:to_remove, r)
    assert @registry.registered?(:to_remove)

    result = @registry.unregister(:to_remove)

    assert_equal :ok, result
    refute @registry.registered?(:to_remove)
    assert_nil @registry.lookup(:to_remove)
  end

  def test_unregister_nonexistent_name_returns_ok
    # Idempotent - unregistering non-existent name is not an error
    result = @registry.unregister(:never_existed)
    assert_equal :ok, result
  end

  def test_can_reregister_after_unregister
    r = make_ractor
    @registry.register(:reusable, r)
    @registry.unregister(:reusable)

    result = @registry.register(:reusable, r)
    assert_equal :ok, result
    assert_equal r, @registry.lookup(:reusable)
  end

  # ===========================================================================
  # Listing
  # ===========================================================================

  def test_list_returns_empty_array_initially
    names = @registry.list
    assert_empty names
  end

  def test_list_returns_all_registered_names
    r1 = make_ractor
    r2 = make_ractor
    r3 = make_ractor

    @registry.register(:alpha, r1)
    @registry.register(:beta, r2)
    @registry.register(:gamma, r3)

    names = @registry.list
    assert_equal 3, names.size
    assert_includes names, :alpha
    assert_includes names, :beta
    assert_includes names, :gamma
  end

  def test_list_returns_frozen_array
    r = make_ractor
    @registry.register(:test, r)

    names = @registry.list
    assert names.frozen?, "list should return frozen array"
  end

  def test_list_returns_snapshot_not_live_view
    r1 = make_ractor
    @registry.register(:first, r1)

    names = @registry.list

    r2 = make_ractor
    @registry.register(:second, r2)

    # Original list should not include :second
    refute_includes names, :second
  end

  # ===========================================================================
  # Multiple Names per Ractor
  # ===========================================================================

  def test_same_ractor_can_have_multiple_names
    r = make_ractor

    result1 = @registry.register(:name_one, r)
    result2 = @registry.register(:name_two, r)

    assert_equal :ok, result1
    assert_equal :ok, result2
    assert_equal r, @registry.lookup(:name_one)
    assert_equal r, @registry.lookup(:name_two)
  end

  def test_unregister_one_name_keeps_other_names
    r = make_ractor
    @registry.register(:name_a, r)
    @registry.register(:name_b, r)

    @registry.unregister(:name_a)

    refute @registry.registered?(:name_a)
    assert @registry.registered?(:name_b)
    assert_equal r, @registry.lookup(:name_b)
  end

  # ===========================================================================
  # Auto-cleanup on Ractor Death
  # ===========================================================================

  def test_auto_unregister_on_normal_exit
    r = Ractor.new do
      Ractor.receive
      :done
    end
    @registry.register(:will_exit, r)

    assert @registry.registered?(:will_exit)

    # Tell ractor to exit
    r << :go
    r.value  # Wait for completion

    # Wait for registry to process death notification
    assert_eventually(timeout: 1.0, msg: "should auto-unregister after exit") do
      !@registry.registered?(:will_exit)
    end
  end

  def test_auto_unregister_on_crash
    r = Ractor.new do
      Ractor.receive
      raise "boom"
    end
    @registry.register(:will_crash, r)

    assert @registry.registered?(:will_crash)

    # Trigger crash
    r << :go
    begin
      r.value
    rescue StandardError
      nil
    end  # Swallow RemoteError

    # Wait for registry to process death notification
    assert_eventually(timeout: 1.0, msg: "should auto-unregister after crash") do
      !@registry.registered?(:will_crash)
    end
  end

  def test_auto_unregister_removes_all_names_for_dead_ractor
    r = Ractor.new do
      Ractor.receive
      :done
    end
    @registry.register(:name_x, r)
    @registry.register(:name_y, r)

    r << :go
    r.value

    assert_eventually(timeout: 1.0) { !@registry.registered?(:name_x) }
    assert_eventually(timeout: 1.0) { !@registry.registered?(:name_y) }
  end

  # ===========================================================================
  # Concurrent Access
  # ===========================================================================

  def test_concurrent_registrations_are_serialized
    ractors = 20.times.map { make_ractor }

    threads = ractors.each_with_index.map do |r, i|
      Thread.new { @registry.register(:"worker_#{i}", r) }
    end

    results = threads.map(&:value)
    assert results.all? { |r| r == :ok }, "all registrations should succeed"

    names = @registry.list
    assert_equal 20, names.size
  end

  def test_concurrent_lookups_are_safe
    r = make_ractor
    @registry.register(:shared, r)

    threads = 50.times.map do
      Thread.new { @registry.lookup(:shared) }
    end

    results = threads.map(&:value)
    assert(results.all? { |found| found == r })
  end

  def test_concurrent_mixed_operations
    # Mix of registers, lookups, and unregisters
    r1 = make_ractor
    r2 = make_ractor
    @registry.register(:stable, r1)

    threads = []

    # Some threads do lookups
    10.times do
      threads << Thread.new { 10.times { @registry.lookup(:stable) } }
    end

    # Some threads do register/unregister cycles
    5.times do |i|
      threads << Thread.new do
        @registry.register(:"temp_#{i}", r2)
        sleep 0.01
        @registry.unregister(:"temp_#{i}")
      end
    end

    threads.each(&:join)

    # Stable registration should survive
    assert_equal r1, @registry.lookup(:stable)
  end

  # ===========================================================================
  # Edge Cases
  # ===========================================================================

  def test_shutdown_stops_registry
    r = make_ractor
    @registry.register(:test, r)

    @registry.shutdown

    # After shutdown, operations should fail (port closed)
    assert_raises(Ractor::ClosedError) do
      @registry.lookup(:test)
    end
  end

  def test_rapid_register_unregister_cycles
    r = make_ractor

    100.times do |i|
      name = :"rapid_#{i}"
      @registry.register(name, r)
      assert @registry.registered?(name)
      @registry.unregister(name)
      refute @registry.registered?(name)
    end
  end

  def test_many_registrations
    ractors = 100.times.map { make_ractor }

    ractors.each_with_index do |r, i|
      @registry.register(:"worker_#{i}", r)
    end

    assert_equal 100, @registry.list.size

    # Verify all are findable
    ractors.each_with_index do |r, i|
      assert_equal r, @registry.lookup(:"worker_#{i}")
    end
  end
end
