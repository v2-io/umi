# frozen_string_literal: true

require 'timeout'

module Umi
  # Worker provides a supervised process abstraction that feels like a normal Ruby object.
  #
  # A Worker runs in its own Ractor. You interact with it through a proxy that
  # forwards method calls transparently via `method_missing`.
  #
  # ## Usage
  #
  # ```ruby
  # class Counter < Umi::Worker
  #   def init(args)
  #     @count = args[:start] || 0
  #   end
  #
  #   def get = @count
  #   def add(n) = @count += n
  #   def increment = @count += 1
  # end
  #
  # counter = Counter.new(start: 10)
  # counter.get        # => 10
  # counter.increment
  # counter.get        # => 11
  # counter.add(5)     # => 16
  # counter.shutdown
  # ```
  #
  # The proxy forwards all method calls to the worker Ractor. From the caller's
  # perspective, it's just a Counter object.
  #
  class Worker
    # Create a new worker running in its own Ractor.
    #
    # @param args [Hash] Arguments passed to init
    # @return [WorkerProxy] A proxy that behaves like the worker
    def self.new(args = {})
      setup_port   = Ractor::Port.new
      worker_class = self

      ractor = Ractor.new(setup_port, worker_class, args) do |setup, klass, init_args|
        command_port = Ractor::Port.new
        setup << command_port

        # Create the actual worker instance inside the Ractor
        worker = klass.allocate
        worker.instance_variable_set(:@_command_port, command_port)
        worker.send(:_init_worker, init_args)

        # Run message loop
        worker.send(:_run_loop)
      end

      command_port = setup_port.receive
      WorkerProxy.new(ractor, command_port)
    end

    # Initialize the worker state. Override in subclass.
    #
    # @param args [Hash] Arguments from new
    def init(args)
      # Default: no initialization needed
    end

    # Called before termination. Override in subclass.
    #
    # @param reason [Symbol, Exception] Why we're terminating
    def terminate(reason)
      # Default: no cleanup needed
    end

    private

    def _init_worker(args)
      init(args)
    end

    def _run_loop
      loop do
        msg = @_command_port.receive

        case msg
        in [:call, method, args, kwargs, reply_port]
          begin
            result = public_send(method, *args, **kwargs)
            reply_port << [:ok, result]
          rescue StandardError => e
            reply_port << [:error, e.class.name, e.message]
          end

        in [:shutdown, timeout]
          terminate(:shutdown)
          break
        end
      rescue StandardError => e
        terminate(e)
        raise
      end
    end
  end

  # Proxy that makes a Worker feel like a normal Ruby object.
  #
  # All method calls are forwarded to the worker Ractor transparently.
  #
  class WorkerProxy
    DEFAULT_TIMEOUT = 5.0

    def initialize(ractor, command_port)
      @ractor       = ractor
      @command_port = command_port
    end

    # Forward method calls to the worker.
    def method_missing(method, *args, **kwargs, &block)
      raise ArgumentError, "Worker methods cannot take blocks" if block

      reply_port = Ractor::Port.new
      @command_port << [:call, method, args, kwargs, reply_port]

      # Wait for reply with timeout
      timer_port = Ractor::Port.new
      timer = Thread.new do
        sleep(DEFAULT_TIMEOUT)
        timer_port << :timeout rescue nil
      end

      begin
        ready, value = Ractor.select(reply_port, timer_port)

        if ready == timer_port
          raise Timeout::Error, "Worker call timed out after #{DEFAULT_TIMEOUT}s"
        end

        case value
        in [:ok, result]                  then result
        in [:error, error_class, message] then raise WorkerError, "#{error_class}: #{message}"
        end
      ensure
        timer.kill
      end
    end

    def respond_to_missing?(method, include_private = false)
      true  # We forward everything
    end

    # Graceful shutdown.
    def shutdown(timeout: 5000)
      @command_port << [:shutdown, timeout]
    end

    # Register for death notification.
    #
    # @param port [Ractor::Port] Port to receive :exited or :aborted
    def monitor(port)
      @ractor.monitor(port)
    end

    # The underlying Ractor (for supervision).
    def ractor
      @ractor
    end

    # The command port (for advanced use).
    def command_port
      @command_port
    end
  end

  # Error raised when a worker call fails.
  class WorkerError < StandardError; end
end
