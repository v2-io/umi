# frozen_string_literal: true

require 'open3'

module Umi
  # Proctor wraps a long-lived external process as a Ractor-citizen.
  #
  # Key properties:
  # - Bidirectional messaging (stdin/stdout as send/receive)
  # - Death notification (via Ractor.monitor)
  # - Isolation (process crashes become messages, not Ruby crashes)
  # - OTP-style tagged tuples for pattern matching
  #
  # The name: from Latin "procurator" - one who manages on behalf of another.
  # A Proctor supervises and manages an external process lifecycle.
  #
  # ## Primary API
  #
  # The API uses tagged tuples for pattern matching. Timeouts return nil
  # (not exceptions), enabling OTP-style control flow.
  #
  # - `pop(timeout)` → `[:stdout, data]`, `[:stderr, data]`, `nil`, `[:closed, result]`
  # - `pop_stdout(timeout)` → `[:ok, data]`, `nil`, `[:closed, result]`
  # - `pop_stderr(timeout)` → `[:ok, data]`, `nil`, `[:closed, result]`
  # - `pop!`, `pop_stdout!`, `pop_stderr!` → raising versions (for simple scripts)
  #
  # @example Basic usage with pattern matching
  #   sh = Umi::Proctor.new("cat")
  #   sh << "hello\n"
  #
  #   case sh.pop_stdout(2)
  #   in [:ok, line] then puts line
  #   in nil then puts "timeout"
  #   in [:closed, result] then puts "exited: #{result.exit_code}"
  #   end
  #
  #   sh.close_stdin
  #   sh.join
  #
  # @example OTP-style polling with short timeouts
  #   loop do
  #     case sh.pop_stdout(0.1)
  #     in [:ok, line]
  #       process(line)
  #     in nil
  #       do_other_work  # timeout is normal, not an error
  #     in [:closed, _]
  #       break
  #     end
  #   end
  #
  # @example Enumerable iteration
  #   sh = Umi::Proctor.new("ls", "-la")
  #   sh.each { |line| puts line }
  #
  #   # Or with Enumerable methods:
  #   sh.take(5).map(&:chomp)
  #   sh.lazy.select { |l| l.include?("rb") }.first(3)
  #
  # @example Simple script (raising API)
  #   sh = Umi::Proctor.new("cat")
  #   sh << "hello\n"
  #   puts sh.pop_stdout!  # raises Timeout or ProcessExited on failure
  #   sh.close_stdin
  #   sh.join
  #
  class Proctor
    include Enumerable

    # Raised when a receive times out
    class Timeout < StandardError; end

    # Raised when the process has already exited
    class ProcessExited < StandardError; end

    # Default timeouts (in seconds)
    DEFAULT_POP_TIMEOUT      = 2
    DEFAULT_POP_BANG_TIMEOUT = 120

    # Result of a completed process
    class Result
      attr_reader :pid, :exit_code, :signal, :duration

      def initialize(pid:, exit_code:, signal:, duration:)
        @pid       = pid
        @exit_code = exit_code
        @signal    = signal
        @duration  = duration
      end

      def success?
        @exit_code == 0
      end

      def signaled?
        !@signal.nil?
      end

      def inspect
        status = signaled? ? "signal=#{signal}" : "exit=#{exit_code}"
        "#<Umi::Proctor::Result pid=#{pid} #{status} duration=#{duration.round(3)}s>"
      end
    end

    attr_reader :pid

    # Open a Proctor, yield it, and ensure cleanup.
    #
    # @param cmd [String] The command to run
    # @param args [Array<String>] Arguments
    # @param opts [Hash] Options (see #initialize)
    # @yield [Proctor] The proctor instance
    # @return [Result] The process result
    def self.open(cmd, *, **)
      proctor = new(cmd, *, **)
      begin
        yield proctor
      ensure
        if proctor.alive?
          # Give process a moment to exit naturally, then force stop
          begin
            proctor.join(timeout: 0.5)
          rescue Timeout
            proctor.stop(timeout: 2.0)
          end
        end
      end
      proctor.result || proctor.join(timeout: 1.0)
    end

    # Create a new Proctor wrapping the given command.
    #
    # @param cmd [String] The command to run
    # @param args [Array<String>] Arguments to the command
    # @param env [Hash] Environment variables (optional)
    # @param chdir [String] Working directory (optional)
    # @param stderr [Symbol] :separate (default), :merge, or :discard
    def initialize(cmd, *args, env: {}, chdir: nil, stderr: :separate)
      @cmd         = cmd
      @args        = args
      @env         = env
      @chdir       = chdir
      @stderr_mode = stderr

      @inbox          = Ractor::Port.new
      @started_at     = Time.now
      @exited         = false
      @result         = nil
      @exit_callbacks = []
      @message_buffer = []
      @pending_death  = nil  # [exit_code, signal] if we got process_died but have buffered output

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
    alias :write :<<

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

    # Look at the next message without consuming it.
    # Returns immediately - does not block.
    #
    # @return [Array, Symbol, nil] The next message, or nil if none available
    def peek
      # Check buffer first
      return @message_buffer.first unless @message_buffer.empty?

      # Try a non-blocking receive
      begin
        msg = receive_message(timeout: 0)
        @message_buffer << msg if msg
        msg
      rescue StandardError
        nil
      end
    end

    # Is there output waiting to be read?
    #
    # @return [Boolean]
    def output?
      !peek.nil?
    end

    # =========================================================================
    # Primary API: pop / pop_stdout / pop_stderr (and ! variants)
    # =========================================================================

    # Get the next message (stdout or stderr) with timeout.
    # Returns tagged tuple for pattern matching - does not raise on timeout.
    #
    # @param timeout [Numeric, :forever] Seconds to wait (default 2)
    # @return [Array, nil] [:stdout, data], [:stderr, data], nil (timeout), or [:closed, result]
    #
    # @example
    #   case sh.pop(5)
    #   in [:stdout, line] then process_output(line)
    #   in [:stderr, line] then log_error(line)
    #   in nil then handle_timeout()
    #   in [:closed, result] then cleanup(result)
    #   end
    def pop(timeout = DEFAULT_POP_TIMEOUT)
      actual_timeout = timeout == :forever ? nil : timeout

      if @exited
        buffered = @message_buffer.find { |m| [:stdout, :stderr].include?(m[0]) }
        if buffered
          @message_buffer.delete(buffered)
          return buffered  # [:stdout, data] or [:stderr, data]
        end
        return [:closed, @result]
      end

      if @pending_death
        buffered = @message_buffer.find { |m| [:stdout, :stderr].include?(m[0]) }
        if buffered
          @message_buffer.delete(buffered)
          return buffered
        end
        exit_code, sig = @pending_death
        @pending_death = nil
        handle_death(exit_code, sig)
        return [:closed, @result]
      end

      msg = receive_any_output(timeout: actual_timeout)

      case msg
      in [:stdout, _] | [:stderr, _]
        msg
      in [:process_died, _pid, exit_code, sig]
        drain_remaining_to_buffer
        buffered = @message_buffer.find { |m| [:stdout, :stderr].include?(m[0]) }
        if buffered
          @pending_death = [exit_code, sig]
          @message_buffer.delete(buffered)
          return buffered
        end
        handle_death(exit_code, sig)
        [:closed, @result]
      in nil | :timeout
        nil
      else
        # Buffer non-output messages and retry
        @message_buffer << msg if msg
        pop(timeout)
      end
    end

    # Get the next message, raising on timeout or closed.
    #
    # @param timeout [Numeric, :forever] Seconds to wait (default 120)
    # @return [Array] [:stdout, data] or [:stderr, data]
    # @raise [Timeout] If timeout expires
    # @raise [ProcessExited] If process has exited
    def pop!(timeout = DEFAULT_POP_BANG_TIMEOUT)
      case pop(timeout)
      in [:stdout, _] | [:stderr, _] => msg
        msg
      in nil
        raise Timeout, "No data received within #{timeout}s"
      in [:closed, _]
        raise ProcessExited, "Process has exited"
      end
    end

    # Get the next stdout message with timeout.
    # Buffers stderr for later retrieval.
    #
    # @param timeout [Numeric, :forever] Seconds to wait (default 2)
    # @return [Array, nil] [:ok, data], nil (timeout), or [:closed, result]
    def pop_stdout(timeout = DEFAULT_POP_TIMEOUT)
      actual_timeout = timeout == :forever ? nil : timeout

      if @exited
        buffered = @message_buffer.find { |m| m[0] == :stdout }
        if buffered
          @message_buffer.delete(buffered)
          return [:ok, buffered[1]]
        end
        return [:closed, @result]
      end

      if @pending_death
        buffered = @message_buffer.find { |m| m[0] == :stdout }
        if buffered
          @message_buffer.delete(buffered)
          return [:ok, buffered[1]]
        end
        exit_code, sig = @pending_death
        @pending_death = nil
        handle_death(exit_code, sig)
        return [:closed, @result]
      end

      msg = drain_until_stdout(timeout: actual_timeout)

      case msg
      in [:stdout, data]
        [:ok, data]
      in [:stderr, data]
        @message_buffer << msg
        pop_stdout(timeout)
      in [:process_died, _pid, exit_code, sig]
        drain_remaining_to_buffer
        buffered_stdout = @message_buffer.find { |m| m[0] == :stdout }
        if buffered_stdout
          @pending_death = [exit_code, sig]
          @message_buffer.delete(buffered_stdout)
          return [:ok, buffered_stdout[1]]
        end
        handle_death(exit_code, sig)
        [:closed, @result]
      in nil | :timeout
        nil
      end
    end

    # Get the next stdout message, raising on timeout or closed.
    #
    # @param timeout [Numeric, :forever] Seconds to wait (default 120)
    # @return [String] The data
    # @raise [Timeout] If timeout expires
    # @raise [ProcessExited] If process has exited
    def pop_stdout!(timeout = DEFAULT_POP_BANG_TIMEOUT)
      case pop_stdout(timeout)
      in [:ok, data]
        data
      in nil
        raise Timeout, "No stdout received within #{timeout}s"
      in [:closed, _]
        raise ProcessExited, "Process has exited"
      end
    end

    # Get the next stderr message with timeout.
    # Buffers stdout for later retrieval.
    #
    # @param timeout [Numeric, :forever] Seconds to wait (default 2)
    # @return [Array, nil] [:ok, data], nil (timeout), or [:closed, result]
    def pop_stderr(timeout = DEFAULT_POP_TIMEOUT)
      actual_timeout = timeout == :forever ? nil : timeout

      if @exited
        buffered = @message_buffer.find { |m| m[0] == :stderr }
        if buffered
          @message_buffer.delete(buffered)
          return [:ok, buffered[1]]
        end
        return [:closed, @result]
      end

      if @pending_death
        buffered = @message_buffer.find { |m| m[0] == :stderr }
        if buffered
          @message_buffer.delete(buffered)
          return [:ok, buffered[1]]
        end
        exit_code, sig = @pending_death
        @pending_death = nil
        handle_death(exit_code, sig)
        return [:closed, @result]
      end

      msg = drain_until_stderr(timeout: actual_timeout)

      case msg
      in [:stderr, data]
        [:ok, data]
      in [:stdout, data]
        @message_buffer << msg
        pop_stderr(timeout)
      in [:process_died, _pid, exit_code, sig]
        drain_remaining_to_buffer
        buffered_stderr = @message_buffer.find { |m| m[0] == :stderr }
        if buffered_stderr
          @pending_death = [exit_code, sig]
          @message_buffer.delete(buffered_stderr)
          return [:ok, buffered_stderr[1]]
        end
        handle_death(exit_code, sig)
        [:closed, @result]
      in nil | :timeout
        nil
      end
    end

    # Get the next stderr message, raising on timeout or closed.
    #
    # @param timeout [Numeric, :forever] Seconds to wait (default 120)
    # @return [String] The data
    # @raise [Timeout] If timeout expires
    # @raise [ProcessExited] If process has exited
    def pop_stderr!(timeout = DEFAULT_POP_BANG_TIMEOUT)
      case pop_stderr(timeout)
      in [:ok, data]
        data
      in nil
        raise Timeout, "No stderr received within #{timeout}s"
      in [:closed, _]
        raise ProcessExited, "Process has exited"
      end
    end

    # Enumerator-compatible: get next stdout value, blocking forever.
    # Raises StopIteration when stream closes.
    #
    # @return [String] The data
    # @raise [StopIteration] When stream is closed
    def next
      case pop_stdout(:forever)
      in [:ok, data]
        data
      in [:closed, _]
        raise StopIteration, "Stream closed"
      end
    end

    # Iterate over all stdout lines until process exits.
    # Required for Enumerable.
    #
    # @yield [String] Each line from stdout
    # @return [Enumerator] If no block given
    def each
      return enum_for(:each) unless block_given?

      loop do
        case pop_stdout(:forever)
        in [:ok, data]
          yield data
        in [:closed, _]
          break
        end
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

      # Check if pop already captured the death
      if @pending_death
        exit_code, sig = @pending_death
        @pending_death = nil
        handle_death(exit_code, sig)
        begin
          @watcher << [:shutdown]
        rescue
          nil
        end
        begin
          @watcher.value
        rescue
          nil
        end
        return @result
      end

      # Drain messages until we get process_died
      loop do
        msg = receive_message(timeout: timeout)

        case msg
        in [:process_died, _pid, exit_code, sig]
          handle_death(exit_code, sig)
          @watcher << [:shutdown]  # Direct send, bypass exited check
          begin
            @watcher.value
          rescue
            nil
          end  # Wait for watcher to clean up
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
    attr_reader :result

    # Iterate over stdout lines until process exits.
    #
    # @param timeout [Float] Max time to wait for each line (default 30s)
    # @yield [String] Each line from stdout
    # @return [Result] The process result
    # @deprecated Use #each instead
    def each_line(timeout: 30.0)
      return enum_for(:each_line, timeout: timeout) unless block_given?

      loop do
        case pop_stdout(timeout)
        in [:ok, line]
          yield line
        in [:closed, _] | nil
          break
        end
      end

      @result || join(timeout: timeout)
    end

    # Iterate over all output (stdout and stderr interleaved).
    #
    # @yield [Symbol, String] [:stdout, line] or [:stderr, line]
    # @return [Result]
    def each_output(timeout: :forever)
      return enum_for(:each_output, timeout: timeout) unless block_given?

      loop do
        case pop(timeout)
        in [:stdout, line]
          yield :stdout, line
        in [:stderr, line]
          yield :stderr, line
        in [:closed, _] | nil
          break
        end
      end

      @result
    end

    def inspect
      status = @exited ? "exited" : "running pid=#{@pid}"
      "#<Umi::Proctor #{@cmd} #{status}>"
    end

    private

    def start_watcher
      cmd         = @cmd
      args        = @args
      env         = @env
      chdir       = @chdir
      stderr_mode = @stderr_mode
      inbox       = @inbox
      parent      = Ractor.current

      @watcher = Ractor.new(cmd, args, env, chdir, stderr_mode, inbox, parent) do |cmd, args, env, chdir, stderr_mode, inbox, _parent|
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
            while (line = stderr.gets)
              inbox.send([:stderr, line])
            end
          when :merge
            while (line = stderr.gets)
              inbox.send([:stdout, line])  # Send as stdout
            end
          when :discard
            stderr.read  # Consume and discard
          end
          inbox.send([:stderr_closed])
        end

        death_thread = Thread.new do
          status = wait_thr.value
          # NOTE: We intentionally don't wait for stdout/stderr threads here.
          # If we did, [:process_died] would be delayed until all output is
          # drained, causing hangs with high-output processes.
          # Instead, receive() uses drain_remaining_to_buffer() to capture
          # any stdout that arrives after process_died.
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
            begin
              stdin.close
            rescue
              nil
            end
          in [:kill, sig]
            begin
              Process.kill(sig, pid)
            rescue
              nil
            end
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
        Thread.new { sleep(0.001)
 timer_port.send(:timeout) }

        source, msg = Ractor.select(@inbox, timer_port)
        source == timer_port ? nil : msg
      else
        # Use timer Ractor pattern
        timer_port = Ractor::Port.new
        # Use Thread instead of Ractor to avoid accumulating Ractors
        Thread.new(timer_port, timeout) do |port, t|
          sleep(t)
          begin
            port.send(:timeout)
          rescue
            nil
          end
        end

        source, msg = Ractor.select(@inbox, timer_port)

        if source == timer_port
          :timeout
        else
          msg
        end
      end
    end

    # Waits for stdout or process_died, buffering other messages.
    # Must avoid infinite loop: don't re-check messages we just buffered.
    def drain_until_stdout(timeout: nil)
      # First, check buffer for existing stdout/process_died
      @message_buffer.each_with_index do |msg, idx|
        if [:stdout, :process_died].include?(msg[0])
          @message_buffer.delete_at(idx)
          return msg
        end
      end

      # Now drain from inbox directly (not via receive_message to avoid re-checking buffer)
      loop do
        msg = inbox_receive_raw(timeout: timeout)
        return msg if msg.nil? || msg == :timeout
        return msg if [:stdout, :process_died].include?(msg[0])

        @message_buffer << msg
      end
    end

    # Waits for stderr or process_died, buffering other messages.
    def drain_until_stderr(timeout: nil)
      # First, check buffer for existing stderr/process_died
      @message_buffer.each_with_index do |msg, idx|
        if [:stderr, :process_died].include?(msg[0])
          @message_buffer.delete_at(idx)
          return msg
        end
      end

      # Now drain from inbox directly
      loop do
        msg = inbox_receive_raw(timeout: timeout)
        return msg if msg.nil? || msg == :timeout
        return msg if [:stderr, :process_died].include?(msg[0])

        @message_buffer << msg
      end
    end

    # Waits for stdout, stderr, or process_died.
    def receive_any_output(timeout: nil)
      # First, check buffer for existing output/process_died
      @message_buffer.each_with_index do |msg, idx|
        if [:stdout, :stderr, :process_died].include?(msg[0])
          @message_buffer.delete_at(idx)
          return msg
        end
      end

      # Now drain from inbox directly
      loop do
        msg = inbox_receive_raw(timeout: timeout)
        return msg if msg.nil? || msg == :timeout
        return msg if [:stdout, :stderr, :process_died].include?(msg[0])

        @message_buffer << msg
      end
    end

    # Drain any remaining messages from inbox to buffer (non-blocking).
    # Used after receiving process_died to capture any output that arrived
    # between the last stdout read and the death notification.
    def drain_remaining_to_buffer
      loop do
        msg = inbox_receive_raw(timeout: 0)
        break if msg.nil?  # No more messages

        @message_buffer << msg unless msg == :timeout
      end
    end

    # Low-level inbox receive with timeout, bypassing buffer.
    # Used by drain_until_* to avoid infinite loops.
    def inbox_receive_raw(timeout: nil)
      if timeout.nil?
        @inbox.receive
      elsif timeout <= 0
        timer_port = Ractor::Port.new
        Thread.new { sleep(0.001)
 begin
                                     timer_port.send(:timeout)
                                   rescue
                                     nil
                                   end }
        source, msg = Ractor.select(@inbox, timer_port)
        source == timer_port ? nil : msg
      else
        timer_port = Ractor::Port.new
        Thread.new(timer_port, timeout) do |port, t|
          sleep(t)
          begin
            port.send(:timeout)
          rescue
            nil
          end
        end
        source, msg = Ractor.select(@inbox, timer_port)
        source == timer_port ? :timeout : msg
      end
    end

    def handle_death(exit_code, signal)
      return if @exited

      @exited  = true
      duration = Time.now - @started_at
      @result = Result.new(
        pid:       @pid,
        exit_code: exit_code,
        signal:    signal&.to_sym,
        duration:  duration
      )

      @exit_callbacks.each { |cb| cb.call(@result) }
    end
  end
end
