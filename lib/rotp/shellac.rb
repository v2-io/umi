# frozen_string_literal: true

require 'open3'

module ROTP
  # Shellac wraps a long-lived external process as a Ractor-citizen.
  #
  # Key properties:
  # - Bidirectional messaging (stdin/stdout as send/receive)
  # - Death notification (via Ractor.monitor)
  # - Isolation (process crashes become messages, not Ruby crashes)
  #
  # The name: Shell + Actor, or shellac (a protective coating).
  #
  # @example Basic usage
  #   shellac = ROTP::Shellac.new("cat")
  #   shellac << "hello\n"
  #   puts shellac.receive  # => "hello\n"
  #   shellac.close_stdin
  #   result = shellac.join
  #   puts result.success?  # => true
  #
  # @example Multi-shot conversation
  #   shellac = ROTP::Shellac.new("dot", "-Tplain")
  #   shellac << "digraph G { A -> B; }\n"
  #   while (line = shellac.receive) != "stop\n"
  #     process(line)
  #   end
  #   # Send another graph...
  #
  class Shellac
    # Raised when a receive times out
    class Timeout < StandardError; end

    # Raised when the process has already exited
    class ProcessExited < StandardError; end

    # Result of a completed process
    class Result
      attr_reader :pid, :exit_code, :signal, :duration

      def initialize(pid:, exit_code:, signal:, duration:)
        @pid = pid
        @exit_code = exit_code
        @signal = signal
        @duration = duration
      end

      def success?
        @exit_code == 0
      end

      def signaled?
        !@signal.nil?
      end

      def inspect
        status = signaled? ? "signal=#{signal}" : "exit=#{exit_code}"
        "#<ROTP::Shellac::Result pid=#{pid} #{status} duration=#{duration.round(3)}s>"
      end
    end

    attr_reader :pid

    # Open a Shellac, yield it, and ensure cleanup.
    #
    # @param cmd [String] The command to run
    # @param args [Array<String>] Arguments
    # @param opts [Hash] Options (see #initialize)
    # @yield [Shellac] The shellac instance
    # @return [Result] The process result
    def self.open(cmd, *args, **opts)
      shellac = new(cmd, *args, **opts)
      begin
        yield shellac
      ensure
        if shellac.alive?
          # Give process a moment to exit naturally, then force stop
          begin
            shellac.join(timeout: 0.5)
          rescue Timeout
            shellac.stop(timeout: 2.0)
          end
        end
      end
      shellac.result || shellac.join(timeout: 1.0)
    end

    # Create a new Shellac wrapping the given command.
    #
    # @param cmd [String] The command to run
    # @param args [Array<String>] Arguments to the command
    # @param env [Hash] Environment variables (optional)
    # @param chdir [String] Working directory (optional)
    # @param stderr [Symbol] :separate (default), :merge, or :discard
    def initialize(cmd, *args, env: {}, chdir: nil, stderr: :separate)
      @cmd = cmd
      @args = args
      @env = env
      @chdir = chdir
      @stderr_mode = stderr

      @inbox = Ractor::Port.new
      @started_at = Time.now
      @exited = false
      @result = nil
      @exit_callbacks = []
      @message_buffer = []

      start_watcher
    end

    # Send data to the process's stdin.
    #
    # @param data [String] Data to send
    # @return [self]
    def <<(data)
      send_command(:stdin, data)
      self
    end
    alias_method :write, :<<

    # Send data with a newline appended.
    #
    # @param line [String] Line to send (newline added)
    # @return [self]
    def puts(line)
      self << "#{line}\n"
    end

    # Close the process's stdin (signals EOF).
    #
    # @return [self]
    def close_stdin
      send_command(:close_stdin)
      self
    end

    # Receive the next line/chunk from stdout.
    #
    # @param timeout [Float, nil] Seconds to wait (nil = forever)
    # @return [String] The received data
    # @raise [Timeout] If timeout expires
    # @raise [ProcessExited] If process has exited and no more data
    def receive(timeout: nil)
      # If already exited, check buffer for remaining stdout, else raise
      if @exited
        buffered = @message_buffer.find { |m| m[0] == :stdout }
        if buffered
          @message_buffer.delete(buffered)
          return buffered[1]
        end
        raise ProcessExited, "Process has exited"
      end

      # Check buffer first
      msg = drain_until_stdout(timeout: timeout)

      case msg
      in [:stdout, data]
        data
      in [:stderr, data]
        # If we got stderr, buffer it and try again
        @message_buffer << msg
        receive(timeout: timeout)
      in [:process_died, _pid, exit_code, sig]
        handle_death(exit_code, sig)
        raise ProcessExited, "Process exited with code #{exit_code}"
      in :timeout
        raise Timeout, "No data received within #{timeout}s"
      end
    end

    # Receive from stderr specifically.
    #
    # @param timeout [Float, nil] Seconds to wait
    # @return [String] The stderr data
    def receive_stderr(timeout: nil)
      msg = drain_until_stderr(timeout: timeout)

      case msg
      in [:stderr, data]
        data
      in [:stdout, data]
        @message_buffer << msg
        receive_stderr(timeout: timeout)
      in [:process_died, _pid, exit_code, sig]
        handle_death(exit_code, sig)
        raise ProcessExited, "Process exited with code #{exit_code}"
      in :timeout
        raise Timeout, "No stderr received within #{timeout}s"
      end
    end

    # Check if data is available without blocking.
    #
    # @return [Boolean]
    def readable?
      return true unless @message_buffer.empty?

      # Try a zero-timeout receive
      begin
        msg = receive_message(timeout: 0)
        @message_buffer << msg if msg
        !msg.nil?
      rescue
        false
      end
    end

    # Register a callback for when the process exits.
    #
    # @yield [Result] Called when process terminates
    # @return [self]
    def on_exit(&block)
      if @exited
        block.call(@result)
      else
        @exit_callbacks << block
      end
      self
    end

    # Send a signal to the process.
    #
    # @param sig [Symbol, Integer] Signal name or number
    # @return [self]
    def kill(sig = :TERM)
      send_command(:kill, sig)
      self
    end

    # Graceful shutdown: TERM, wait, KILL if needed.
    #
    # @param timeout [Float] Seconds to wait after TERM before KILL
    # @return [Result]
    def stop(timeout: 5.0)
      return @result if @exited

      kill(:TERM)

      begin
        join(timeout: timeout)
      rescue Timeout
        kill(:KILL)
        join(timeout: 1.0)
      end
    end

    # Wait for the process to exit.
    #
    # @param timeout [Float, nil] Seconds to wait
    # @return [Result]
    # @raise [Timeout] If timeout expires before exit
    def join(timeout: nil)
      return @result if @exited

      # Drain messages until we get process_died
      loop do
        msg = receive_message(timeout: timeout)

        case msg
        in [:process_died, _pid, exit_code, sig]
          handle_death(exit_code, sig)
          @watcher << [:shutdown]  # Direct send, bypass exited check
          @watcher.value rescue nil  # Wait for watcher to clean up
          return @result
        in [:stdout, _] | [:stderr, _]
          # Discard remaining output
          next
        in [:stdout_closed] | [:stderr_closed]
          next
        in :exited | :aborted
          # Watcher Ractor exited
          break
        in :timeout
          raise Timeout, "Process did not exit within #{timeout}s"
        else
          next
        end
      end

      @result
    end

    # Check if the process is still running.
    #
    # @return [Boolean]
    def alive?
      !@exited
    end

    # Check if the process has exited.
    #
    # @return [Boolean]
    def exited?
      @exited
    end

    # Get the result if the process has exited.
    #
    # @return [Result, nil]
    def result
      @result
    end

    # Iterate over stdout lines until process exits.
    #
    # @param timeout [Float] Max time to wait for each line (default 30s)
    # @yield [String] Each line from stdout
    # @return [Result] The process result
    def each_line(timeout: 30.0)
      return enum_for(:each_line, timeout: timeout) unless block_given?

      loop do
        begin
          line = receive(timeout: timeout)
          yield line
        rescue ProcessExited, Timeout
          break
        end
      end

      @result || join(timeout: timeout)
    end

    # Iterate over all output (stdout and stderr interleaved).
    #
    # @yield [Symbol, String] [:stdout, line] or [:stderr, line]
    # @return [Result]
    def each_output
      return enum_for(:each_output) unless block_given?

      loop do
        msg = receive_message
        case msg
        in [:stdout, line]
          yield :stdout, line
        in [:stderr, line]
          yield :stderr, line
        in [:process_died, _, _, _]
          handle_death(msg[2], msg[3])
          break
        in [:stdout_closed] | [:stderr_closed]
          next
        else
          next
        end
      end

      @result
    end

    def inspect
      status = @exited ? "exited" : "running pid=#{@pid}"
      "#<ROTP::Shellac #{@cmd} #{status}>"
    end

    private

    def start_watcher
      cmd = @cmd
      args = @args
      env = @env
      chdir = @chdir
      stderr_mode = @stderr_mode
      inbox = @inbox
      parent = Ractor.current

      @watcher = Ractor.new(cmd, args, env, chdir, stderr_mode, inbox, parent) do |cmd, args, env, chdir, stderr_mode, inbox, parent|
        require 'open3'

        # Build spawn options
        spawn_opts = {}
        spawn_opts[:chdir] = chdir if chdir

        # Spawn the process
        stdin, stdout, stderr, wait_thr = Open3.popen3(env, cmd, *args, spawn_opts)
        pid = wait_thr.pid

        inbox.send([:started, pid])

        # Threads for async I/O
        stdout_thread = Thread.new do
          while line = stdout.gets
            inbox.send([:stdout, line])
          end
          inbox.send([:stdout_closed])
        end

        stderr_thread = Thread.new do
          case stderr_mode
          when :separate
            while line = stderr.gets
              inbox.send([:stderr, line])
            end
          when :merge
            while line = stderr.gets
              inbox.send([:stdout, line])  # Send as stdout
            end
          when :discard
            stderr.read  # Consume and discard
          end
          inbox.send([:stderr_closed])
        end

        death_thread = Thread.new do
          status = wait_thr.value
          exit_code = status.exited? ? status.exitstatus : nil
          signal = status.signaled? ? Signal.signame(status.termsig) : nil
          inbox.send([:process_died, pid, exit_code, signal])
        end

        # Command loop
        running = true
        while running
          cmd_msg = Ractor.receive
          case cmd_msg
          in [:stdin, data]
            begin
              stdin.write(data)
              stdin.flush
            rescue Errno::EPIPE
              inbox.send([:stdin_broken])
            end
          in [:close_stdin]
            stdin.close rescue nil
          in [:kill, sig]
            Process.kill(sig, pid) rescue nil
          in [:shutdown]
            running = false
          end
        end

        # Cleanup
        stdout_thread.join
        stderr_thread.join
        death_thread.join

        :watcher_done
      end

      # Monitor the watcher for crashes
      @watcher.monitor(@inbox)

      # Wait for started message
      msg = @inbox.receive
      case msg
      in [:started, pid]
        @pid = pid
      end
    end

    def send_command(*cmd)
      raise ProcessExited, "Process has exited" if @exited
      @watcher << cmd
    end

    def receive_message(timeout: nil)
      # Check buffer first
      return @message_buffer.shift unless @message_buffer.empty?

      if timeout.nil?
        @inbox.receive
      elsif timeout <= 0
        # Non-blocking check - just return nil if nothing available
        # Unfortunately Ractor.select doesn't support non-blocking, so use tiny timer
        timer_port = Ractor::Port.new
        Thread.new { sleep(0.001); timer_port.send(:timeout) }

        source, msg = Ractor.select(@inbox, timer_port)
        source == timer_port ? nil : msg
      else
        # Use timer Ractor pattern
        timer_port = Ractor::Port.new
        # Use Thread instead of Ractor to avoid accumulating Ractors
        Thread.new(timer_port, timeout) do |port, t|
          sleep(t)
          port.send(:timeout) rescue nil
        end

        source, msg = Ractor.select(@inbox, timer_port)

        if source == timer_port
          :timeout
        else
          msg
        end
      end
    end

    def drain_until_stdout(timeout: nil)
      loop do
        msg = receive_message(timeout: timeout)
        return msg if msg.nil? || msg == :timeout
        return msg if msg[0] == :stdout || msg[0] == :process_died
        @message_buffer << msg
      end
    end

    def drain_until_stderr(timeout: nil)
      loop do
        msg = receive_message(timeout: timeout)
        return msg if msg.nil? || msg == :timeout
        return msg if msg[0] == :stderr || msg[0] == :process_died
        @message_buffer << msg
      end
    end

    def handle_death(exit_code, signal)
      return if @exited

      @exited = true
      duration = Time.now - @started_at
      @result = Result.new(
        pid: @pid,
        exit_code: exit_code,
        signal: signal&.to_sym,
        duration: duration
      )

      @exit_callbacks.each { |cb| cb.call(@result) }
    end
  end
end
