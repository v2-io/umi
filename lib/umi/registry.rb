# frozen_string_literal: true

module Umi
  # Registry provides name-based lookup for Ractors with automatic cleanup.
  #
  # In Ruby 4.0, Ractor references are opaque and non-serializable. Registry
  # solves this by mapping symbolic names to Ractors, enabling:
  # - Persistent references that survive restarts (name stays, Ractor changes)
  # - Decoupled communication (sender knows name, not Ractor reference)
  # - Automatic cleanup when registered Ractors die
  #
  # ## Implementation Note
  #
  # Death detection uses per-registration monitor ports. When a Ractor dies,
  # the corresponding monitor port receives the notification, and we know
  # which registration to clean up by looking up the port in our reverse map.
  #
  # @example Basic usage
  #   registry = Umi::Registry.new
  #   registry.register(:database_pool, pool_ractor)
  #   pool = registry.lookup(:database_pool)
  #
  class Registry
    def initialize
      setup_port = Ractor::Port.new

      @ractor = Ractor.new(setup_port) do |setup|
        command_port = Ractor::Port.new
        setup << command_port

        names = {}          # name → ractor
        monitors = {}       # monitor_port → name (for reverse lookup on death)
        active_ports = []   # All monitor ports to select on

        loop do
          # Select on command port + all monitor ports
          ports_to_watch = [command_port] + active_ports
          ready, value = Ractor.select(*ports_to_watch)

          if ready == command_port
            # Handle shutdown separately (no reply_port)
            break if value.is_a?(Array) && value[0] == :shutdown

            request, reply_port = value

            case request
            in [:register, name, ractor]
              if names.key?(name)
                reply_port << [:error, :already_registered]
              else
                # Create a unique monitor port for this registration
                mon_port = Ractor::Port.new
                ractor.monitor(mon_port)

                names[name] = ractor
                monitors[mon_port] = name
                active_ports << mon_port
                reply_port << :ok
              end

            in [:lookup, name] then reply_port << names[name]

            in [:unregister, name]
              # Find and remove the monitor port for this name
              mon_port = monitors.key(name)
              if mon_port
                monitors.delete(mon_port)
                active_ports.delete(mon_port)
                begin
                  mon_port.close
                rescue StandardError
                  nil
                end
              end
              names.delete(name)
              reply_port << :ok

            in [:list] then reply_port << names.keys.dup.freeze
            end

          else
            # Death notification on one of the monitor ports
            # The value is :exited or :aborted
            name = monitors.delete(ready)
            if name
              names.delete(name)
              active_ports.delete(ready)
              begin
                ready.close
              rescue StandardError
                nil
              end
            end
          end
        end
      end

      @command_port = setup_port.receive
    end

    def register(name, ractor) = call([:register, name, ractor])

    def lookup(name) = call([:lookup, name])

    def unregister(name) = call([:unregister, name])

    def list = call([:list])

    def registered?(name) = !lookup(name).nil?

    attr_reader :ractor, :command_port

    def shutdown(timeout: 5000) = @command_port << [:shutdown, timeout]

    def alive? = @ractor.alive?

    private

    def call(request)
      reply_port = Ractor::Port.new
      @command_port << [request, reply_port]
      reply_port.receive
    end
  end
end
