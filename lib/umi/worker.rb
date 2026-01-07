# frozen_string_literal: true

require 'timeout'

module Umi
  # Worker provides a supervised process abstraction with call/cast messaging.
  #
  # A Worker wraps a Ractor that runs a message loop. It supports:
  # - Call: synchronous request/response (blocks until reply)
  # - Cast: asynchronous fire-and-forget (returns immediately)
  # - Shutdown: graceful termination with cleanup callback
  #
  # ## Usage
  #
  # Subclass Worker and implement the callbacks:
  #
  # ```ruby
  # class Counter < Umi::Worker
  #   def init(args)
  #     @count = args[:start] || 0
  #   end
  #
  #   def handle_call(request)
  #     case request
  #     in [:get] then @count
  #     in [:add, n] then @count += n
  #     end
  #   end
  #
  #   def handle_cast(message)
  #     case message
  #     in [:increment] then @count += 1
  #     end
  #   end
  #
  #   def terminate(reason)
  #     puts "Counter shutting down: #{reason}"
  #   end
  # end
  #
  # handle = Counter.start_link(start: 10)
  # handle.call([:get])  # => 10
  # handle.cast([:increment])
  # handle.call([:get])  # => 11
  # handle.shutdown
  # ```
  #
  class Worker
    # Start a new worker Ractor.
    #
    # @param args [Hash] Arguments passed to init
    # @return [WorkerHandle] Handle for communicating with the worker
    def self.start_link(args = {})
      setup_port   = Ractor::Port.new
      worker_class = self

      ractor = Ractor.new(setup_port, worker_class, args) do |setup, klass, init_args|
        # Create command port inside Ractor so we can receive from it
        command_port = Ractor::Port.new
        setup << command_port

        # Instantiate worker and initialize
        worker = klass.allocate
        worker.instance_variable_set(:@_command_port, command_port)
        worker.send(:init, init_args)

        # Run message loop
        worker.send(:run_loop)
      end

      command_port = setup_port.receive
      WorkerHandle.new(ractor, command_port)
    end

    # Initialize the worker state. Override in subclass.
    #
    # @param args [Hash] Arguments from start_link
    def init(args)
      # Default: no initialization needed
    end

    # Handle a synchronous call. Override in subclass.
    #
    # @param request [Object] The request from the caller
    # @return [Object] Response to send back
    def handle_call(request) = raise NotImplementedError, "#{self.class} must implement handle_call"

    # Handle an asynchronous cast. Override in subclass.
    #
    # @param message [Object] The message (no response expected)
    def handle_cast(message)
      # Default: ignore casts
    end

    # Clean up before termination. Override in subclass.
    #
    # @param reason [Symbol, Exception] Why we're terminating
    def terminate(reason)
      # Default: no cleanup needed
    end

    private

    def run_loop
      loop do
        msg = @_command_port.receive

        case msg
        in [:call, request, reply_port]
          begin
            response = handle_call(request)
            reply_port << [:ok, response]
          rescue StandardError => e
            reply_port << [:error, e.class.name, e.message]
          end

        in [:cast, message] then handle_cast(message)

        in [:shutdown, timeout]
          terminate(:shutdown)
          break
        end
      rescue StandardError => e
        terminate(e)
        raise  # Re-raise so supervisor sees the crash
      end
    end
  end

  # Handle for communicating with a Worker.
  #
  # Provides a clean API that hides the message protocol.
  #
  class WorkerHandle
    # Timeout for call operations (seconds)
    DEFAULT_TIMEOUT = 5.0

    def initialize(ractor, command_port)
      @ractor       = ractor
      @command_port = command_port
      @terminated   = false
    end

    # Synchronous request/response.
    #
    # @param request [Object] The request to send
    # @param timeout [Numeric] Seconds to wait for response
    # @return [Object] The response from the worker
    # @raise [Timeout::Error] If no response within timeout
    # @raise [WorkerError] If worker returned an error
    def call(request, timeout: DEFAULT_TIMEOUT)
      reply_port = Ractor::Port.new
      @command_port << [:call, request, reply_port]

      # Wait for reply with timeout
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
        ready, value = Ractor.select(reply_port, timer_port)

        raise Timeout::Error, "Worker call timed out after #{timeout}s" if ready == timer_port

        case value
        in [:ok, response]                then response
        in [:error, error_class, message] then raise WorkerError, "#{error_class}: #{message}"
        end
      ensure
        timer.kill
      end
    end

    # Asynchronous fire-and-forget.
    #
    # @param message [Object] The message to send
    # @return [self]
    def cast(message)
      @command_port << [:cast, message]
      self
    end

    # Request graceful shutdown.
    #
    # @param timeout [Integer] Milliseconds for worker to clean up
    def shutdown(timeout: 5000) = @command_port << [:shutdown, timeout]

    # Register for death notification.
    #
    # @param port [Ractor::Port] Port to receive :exited or :aborted
    def monitor(port) = @ractor.monitor(port)

    # Check if worker is still running.
    #
    # Note: This is approximate - it tracks known termination but can't
    # detect crashes that haven't been observed yet. For reliable death
    # detection, use monitor() instead.
    def alive? = !@terminated

    # Mark as terminated (called internally when death is detected).
    def mark_terminated = @terminated = true

    # The underlying Ractor (for advanced use).
    attr_reader :ractor

    # The command port (for advanced use).
    attr_reader :command_port
  end

  # Error raised when a worker call fails.
  class WorkerError < StandardError; end
end
