# frozen_string_literal: true

require 'json'
require_relative 'shellac'

module ROTP
  # Minimal MCP (Model Context Protocol) client using Shellac.
  #
  # MCP uses JSON-RPC 2.0 over stdio. Each message is a single line of JSON.
  #
  # @example
  #   client = ROTP::MCPClient.new("npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp")
  #   client.start
  #
  #   tools = client.call("tools/list")
  #   result = client.call("tools/call", name: "read_file", arguments: {path: "/tmp/test.txt"})
  #
  #   client.close
  #
  class MCPClient
    class ProtocolError < StandardError; end
    class TimeoutError < StandardError; end
    class ServerError < StandardError
      attr_reader :code, :data
      def initialize(message, code: nil, data: nil)
        super(message)
        @code = code
        @data = data
      end
    end

    # MCP protocol version we support
    PROTOCOL_VERSION = "2024-11-05"

    # Client capabilities we advertise
    CLIENT_CAPABILITIES = {
      roots: { listChanged: true },
      sampling: {}
    }.freeze

    attr_reader :server_info, :server_capabilities

    # Create a new MCP client.
    #
    # @param cmd [String] Command to spawn the MCP server
    # @param args [Array<String>] Arguments to the command
    # @param timeout [Numeric] Default timeout for requests (seconds)
    def initialize(cmd, *args, timeout: 30)
      @cmd = cmd
      @args = args
      @default_timeout = timeout
      @shellac = nil
      @request_id = 0
      @server_info = nil
      @server_capabilities = nil
      @started = false
    end

    # Start the MCP server and perform initialization handshake.
    #
    # @return [Hash] Server info from initialization
    def start
      raise "Already started" if @started

      @shellac = Shellac.new(@cmd, *@args, stderr: :separate)
      @started = true

      # MCP initialization handshake
      response = call("initialize", {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: CLIENT_CAPABILITIES,
        clientInfo: {
          name: "rotp-mcp-client",
          version: "0.1.0"
        }
      })

      @server_info = response["serverInfo"]
      @server_capabilities = response["capabilities"]

      # Send initialized notification
      notify("notifications/initialized")

      @server_info
    end

    # Call an MCP method and wait for response.
    #
    # @param method [String] The method name (e.g., "tools/list")
    # @param params [Hash] Method parameters
    # @param timeout [Numeric] Request timeout (seconds)
    # @return [Object] The result from the response
    # @raise [ServerError] If the server returns an error
    # @raise [TimeoutError] If the request times out
    def call(method, params = {}, timeout: nil)
      raise "Not started" unless @started

      timeout ||= @default_timeout
      id = next_id

      request = {
        jsonrpc: "2.0",
        id: id,
        method: method,
        params: params
      }

      send_message(request)
      receive_response(id, timeout: timeout)
    end

    # Send a notification (no response expected).
    #
    # @param method [String] The notification method
    # @param params [Hash] Notification parameters
    def notify(method, params = nil)
      raise "Not started" unless @started

      notification = {
        jsonrpc: "2.0",
        method: method
      }
      notification[:params] = params if params

      send_message(notification)
    end

    # List available tools.
    #
    # @return [Array<Hash>] List of tool definitions
    def list_tools
      response = call("tools/list")
      response["tools"] || []
    end

    # Call a tool.
    #
    # @param name [String] Tool name
    # @param arguments [Hash] Tool arguments
    # @return [Object] Tool result
    def call_tool(name, arguments = {})
      response = call("tools/call", { name: name, arguments: arguments })
      response["content"]
    end

    # List available resources.
    #
    # @return [Array<Hash>] List of resource definitions
    def list_resources
      response = call("resources/list")
      response["resources"] || []
    end

    # Read a resource.
    #
    # @param uri [String] Resource URI
    # @return [Object] Resource content
    def read_resource(uri)
      response = call("resources/read", uri: uri)
      response["contents"]
    end

    # List available prompts.
    #
    # @return [Array<Hash>] List of prompt definitions
    def list_prompts
      response = call("prompts/list")
      response["prompts"] || []
    end

    # Get a prompt.
    #
    # @param name [String] Prompt name
    # @param arguments [Hash] Prompt arguments
    # @return [Object] Prompt content
    def get_prompt(name, arguments = {})
      call("prompts/get", name: name, arguments: arguments)
    end

    # Check if the server is alive.
    #
    # @return [Boolean]
    def alive?
      @shellac&.alive? || false
    end

    # Close the MCP connection.
    #
    # @return [Shellac::Result]
    def close
      return nil unless @shellac

      @shellac.close_stdin
      @shellac.join(timeout: 5)
    rescue Shellac::Timeout
      @shellac.stop(timeout: 2)
    end

    # Get any stderr output from the server (for debugging).
    #
    # @return [Array<String>] Lines of stderr output
    def drain_stderr
      lines = []
      loop do
        case @shellac.pop_stderr(0)
        in [:ok, line]
          lines << line
        in nil | [:closed, _]
          break
        end
      end
      lines
    end

    private

    def next_id
      @request_id += 1
    end

    def send_message(msg)
      json = JSON.dump(msg)
      @shellac.puts(json)
    end

    def receive_response(expected_id, timeout:)
      deadline = Time.now + timeout

      loop do
        remaining = deadline - Time.now
        raise TimeoutError, "Request timed out after #{timeout}s" if remaining <= 0

        case @shellac.pop_stdout(remaining)
        in [:ok, line]
          msg = parse_message(line)

          # Skip notifications (no id field)
          next unless msg.key?("id")

          # Check if this is our response
          if msg["id"] == expected_id
            if msg.key?("error")
              err = msg["error"]
              raise ServerError.new(
                err["message"] || "Unknown error",
                code: err["code"],
                data: err["data"]
              )
            end
            return msg["result"]
          end

          # Not our response - could be out-of-order (shouldn't happen in MCP)
          # For now, just continue waiting

        in nil
          raise TimeoutError, "Request timed out after #{timeout}s"

        in [:closed, result]
          status = result.success? ? "cleanly" : "with code #{result.exit_code}"
          raise ProtocolError, "Server exited #{status} while waiting for response"
        end
      end
    end

    def parse_message(line)
      # Handle encoding issues from binary garbage
      line = line.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
      JSON.parse(line.strip)
    rescue JSON::ParserError => e
      raise ProtocolError, "Invalid JSON from server: #{e.message}"
    rescue Encoding::CompatibilityError => e
      raise ProtocolError, "Invalid encoding from server: #{e.message}"
    end
  end
end
