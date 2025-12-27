#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple MCP server for testing.
# Implements just enough of the protocol to test the client.

require 'json'

$stdout.sync = true
$stderr.sync = true

def send_response(id, result)
  msg = { jsonrpc: "2.0", id: id, result: result }
  puts JSON.dump(msg)
end

def send_error(id, code, message)
  msg = { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
  puts JSON.dump(msg)
end

# Simple tool implementations
TOOLS = [
  {
    name: "echo",
    description: "Echoes back the input",
    inputSchema: {
      type: "object",
      properties: {
        message: { type: "string" }
      },
      required: ["message"]
    }
  },
  {
    name: "add",
    description: "Adds two numbers",
    inputSchema: {
      type: "object",
      properties: {
        a: { type: "number" },
        b: { type: "number" }
      },
      required: ["a", "b"]
    }
  },
  {
    name: "slow",
    description: "Waits then responds",
    inputSchema: {
      type: "object",
      properties: {
        delay: { type: "number" }
      }
    }
  },
  {
    name: "fail",
    description: "Always fails",
    inputSchema: { type: "object" }
  }
]

while line = gets
  begin
    msg = JSON.parse(line)
  rescue JSON::ParserError
    $stderr.puts "Invalid JSON: #{line}"
    next
  end

  id = msg["id"]
  method = msg["method"]
  params = msg["params"] || {}

  case method
  when "initialize"
    send_response(id, {
      protocolVersion: "2024-11-05",
      capabilities: {
        tools: {}
      },
      serverInfo: {
        name: "test-echo-server",
        version: "1.0.0"
      }
    })

  when "notifications/initialized"
    # Notification, no response needed

  when "tools/list"
    send_response(id, { tools: TOOLS })

  when "tools/call"
    tool_name = params["name"]
    args = params["arguments"] || {}

    case tool_name
    when "echo"
      send_response(id, {
        content: [{ type: "text", text: args["message"] }]
      })

    when "add"
      result = args["a"].to_f + args["b"].to_f
      send_response(id, {
        content: [{ type: "text", text: result.to_s }]
      })

    when "slow"
      delay = args["delay"] || 1
      sleep(delay)
      send_response(id, {
        content: [{ type: "text", text: "done after #{delay}s" }]
      })

    when "fail"
      send_response(id, {
        content: [{ type: "text", text: "error" }],
        isError: true
      })

    else
      send_error(id, -32601, "Unknown tool: #{tool_name}")
    end

  when "ping"
    send_response(id, {})

  else
    send_error(id, -32601, "Method not found: #{method}")
  end
end
