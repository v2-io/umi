# frozen_string_literal: true

module Umi
  # Supervisor manages child workers with automatic restart on failure.
  #
  # Implements the `:one_for_one` strategy: when a child dies, only that
  # child is restarted. Other children continue running.
  #
  # ## Child Specification
  #
  # Each child is specified as a Hash:
  # ```ruby
  # {
  #   id: :worker_name,           # Unique identifier
  #   start: -> { Worker.start_link(...) },  # Returns WorkerHandle
  #   restart: :permanent         # :permanent, :transient, or :temporary
  # }
  # ```
  #
  # Restart types:
  # - `:permanent` - Always restart (default)
  # - `:transient` - Restart only on abnormal exit (:aborted)
  # - `:temporary` - Never restart
  #
  # ## Restart Bounding
  #
  # If a child restarts more than `max_restarts` times within
  # `within_seconds`, the supervisor itself terminates. This prevents
  # infinite restart loops.
  #
  # @example Basic usage
  #   sup = Umi::Supervisor.start_link(
  #     children: [
  #       { id: :counter, start: -> { Counter.start_link(start: 0) } },
  #       { id: :cache, start: -> { Cache.start_link } }
  #     ],
  #     max_restarts: 3,
  #     within_seconds: 5
  #   )
  #
  class Supervisor
    # Start a new supervisor.
    #
    # @param children [Array<Hash>] Child specifications
    # @param max_restarts [Integer] Max restarts before escalation (default 3)
    # @param within_seconds [Integer] Time window for restart counting (default 5)
    # @return [SupervisorHandle]
    def self.start_link(children:, max_restarts: 3, within_seconds: 5)
      setup_port = Ractor::Port.new

      ractor = Ractor.new(setup_port, children, max_restarts, within_seconds) do |setup, child_specs, max_r, within_s|
        sup = Supervisor.new(child_specs, max_r, within_s)
        setup << sup.command_port
        sup.run
      end

      command_port = setup_port.receive
      SupervisorHandle.new(ractor, command_port)
    end

    def initialize(child_specs, max_restarts, within_seconds)
      @child_specs    = child_specs
      @max_restarts   = max_restarts
      @within_seconds = within_seconds

      @command_port  = Ractor::Port.new
      @children      = {}        # id → { handle:, spec:, monitor_port: }
      @monitors      = {}        # monitor_port → id
      @restart_times = {}   # id → [timestamps]
      @active_ports  = []    # All monitor ports to select on
    end

    attr_reader :command_port

    def run
      # Start all children
      @child_specs.each { |spec| start_child(spec) }

      # Main loop
      loop do
        ports = [@command_port] + @active_ports
        ready, value = Ractor.select(*ports)

        if ready == @command_port
          case value
          in [:shutdown, timeout]
            shutdown_children(timeout)
            break
          in [:get_children, reply_port] then reply_port << @children.keys.dup.freeze
          end

        else
          # Death notification from a child
          handle_child_death(ready, value)
        end
      end
    end

    private

    def start_child(spec)
      id     = spec[:id]
      handle = spec[:start].call

      # Create monitor port for this child
      monitor_port = Ractor::Port.new
      handle.monitor(monitor_port)

      @children[id] = {
        handle:       handle,
        spec:         spec,
        monitor_port: monitor_port
      }
      @monitors[monitor_port] = id
      @active_ports << monitor_port
      @restart_times[id] ||= []

      handle
    end

    def handle_child_death(monitor_port, status)
      # status is :exited or :aborted
      id = @monitors.delete(monitor_port)
      return unless id

      child = @children.delete(id)
      return unless child

      @active_ports.delete(monitor_port)
      begin
        monitor_port.close
      rescue StandardError
        nil
      end

      spec         = child[:spec]
      restart_type = spec[:restart] || :permanent

      should_restart = case restart_type
                       when :permanent then true
                       when :transient then status == :aborted
                       when :temporary then false
                       else true
                       end

      return unless should_restart

      # Record restart time
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @restart_times[id] << now

      # Prune old restart times
      cutoff = now - @within_seconds
      @restart_times[id].reject! { |t| t < cutoff }

      # Check if we've exceeded max restarts
      if @restart_times[id].size > @max_restarts
        # Escalate - supervisor dies
        raise SupervisorEscalation,
              "Child #{id} exceeded max restarts (#{@max_restarts} in #{@within_seconds}s)"
      end

      # Restart the child
      start_child(spec)
    end

    def shutdown_children(timeout_ms)
      timeout_per_child = (timeout_ms.to_f / [@children.size, 1].max).to_i

      # Shutdown in reverse start order
      @child_specs.reverse.each do |spec|
        id = spec[:id]
        child = @children[id]
        next unless child

        begin
          child[:handle].shutdown(timeout: timeout_per_child)
        rescue Ractor::ClosedError
          # Already dead
        end

        # Wait briefly for clean exit
        sleep 0.1
      end
    end
  end

  # Handle for communicating with a Supervisor.
  class SupervisorHandle
    def initialize(ractor, command_port)
      @ractor       = ractor
      @command_port = command_port
      @terminated   = false
    end

    # Request graceful shutdown.
    #
    # @param timeout [Integer] Milliseconds for shutdown
    def shutdown(timeout: 5000)
      @command_port << [:shutdown, timeout]
      @terminated = true
    end

    # Get list of child IDs.
    #
    # @return [Array<Symbol>]
    def children
      reply_port = Ractor::Port.new
      @command_port << [:get_children, reply_port]
      reply_port.receive
    end

    # Register for supervisor death notification.
    def monitor(port) = @ractor.monitor(port)

    def alive? = !@terminated

    attr_reader :ractor, :command_port
  end

  # Raised when supervisor exceeds restart limits.
  class SupervisorEscalation < StandardError; end
end
