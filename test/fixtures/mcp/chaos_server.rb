#!/usr/bin/env ruby
# frozen_string_literal: true

# Chaotic MCP server for stress testing.
# Exhibits various misbehaviors based on input.

require 'json'

$stdout.sync = true
$stderr.sync = true

BEHAVIORS = {
  # Normal responses
  "normal" => -> (id, params) {
    send_response(id, { content: [{ type: "text", text: "ok" }] })
  },

  # Slow responses
  "slow" => -> (id, params) {
    delay = params["delay"] || 1
    sleep(delay)
    send_response(id, { content: [{ type: "text", text: "slow done" }] })
  },

  # Malformed JSON responses
  "garbage" => -> (id, params) {
    puts "not json at all {{{{"
  },

  "partial_json" => -> (id, params) {
    print '{"jsonrpc":"2.0","id":' # No newline, incomplete
    $stdout.flush
    sleep 0.5
    puts "#{id},\"result\":{}}"  # Complete it after delay
  },

  "truncated" => -> (id, params) {
    print '{"jsonrpc":"2.0","id":' # Never completed
    $stdout.flush
    # Just hang
    sleep 10
  },

  # Multiple responses on one line (invalid but possible)
  "double_response" => -> (id, params) {
    puts '{"jsonrpc":"2.0","id":' + id.to_s + ',"result":{}}{"jsonrpc":"2.0","id":999,"result":{}}'
  },

  # Response with wrong ID
  "wrong_id" => -> (id, params) {
    send_response(id + 1000, { content: [{ type: "text", text: "wrong id" }] })
  },

  # Send notification before response
  "notification_first" => -> (id, params) {
    puts JSON.dump({ jsonrpc: "2.0", method: "notifications/message", params: { level: "info", data: "surprise!" } })
    send_response(id, { content: [{ type: "text", text: "after notification" }] })
  },

  # Spam notifications
  "notification_spam" => -> (id, params) {
    10.times do |i|
      puts JSON.dump({ jsonrpc: "2.0", method: "notifications/progress", params: { progress: i * 10 } })
    end
    send_response(id, { content: [{ type: "text", text: "done spamming" }] })
  },

  # Exit mid-response
  "crash" => -> (id, params) {
    print '{"jsonrpc":"2.0",'
    $stdout.flush
    exit! 1
  },

  # Exit cleanly without response
  "exit_silent" => -> (id, params) {
    exit 0
  },

  # Huge response
  "huge" => -> (id, params) {
    size = params["size"] || 100_000
    text = "x" * size
    send_response(id, { content: [{ type: "text", text: text }] })
  },

  # Binary garbage in response
  "binary" => -> (id, params) {
    $stdout.write "\x00\x01\x02\xFF\xFE\n"
    $stdout.flush
  },

  # Valid JSON but wrong structure
  "wrong_structure" => -> (id, params) {
    puts JSON.dump({ not: "jsonrpc", at: "all" })
  },

  # Error response
  "error" => -> (id, params) {
    code = params["code"] || -32000
    send_error(id, code, params["message"] || "Intentional error")
  },

  # Very nested JSON
  "nested" => -> (id, params) {
    depth = params["depth"] || 100
    result = "innermost"
    depth.times { result = { nested: result } }
    send_response(id, { content: [{ type: "text", text: JSON.dump(result) }] })
  },

  # Response with unicode edge cases
  "unicode" => -> (id, params) {
    text = "emoji: 🎉 null: \u0000 newline: \n tab: \t"
    send_response(id, { content: [{ type: "text", text: text }] })
  },

  # Immediate response then hang
  "respond_then_hang" => -> (id, params) {
    send_response(id, { content: [{ type: "text", text: "ok" }] })
    sleep 100  # Hang after responding
  },
}

def send_response(id, result)
  msg = { jsonrpc: "2.0", id: id, result: result }
  puts JSON.dump(msg)
end

def send_error(id, code, message)
  msg = { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
  puts JSON.dump(msg)
end

# Handle initialization normally
initialized = false

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
      capabilities: { tools: {} },
      serverInfo: { name: "chaos-server", version: "1.0.0" }
    })

  when "notifications/initialized"
    initialized = true

  when "tools/list"
    tools = BEHAVIORS.keys.map do |name|
      {
        name: name,
        description: "Chaos behavior: #{name}",
        inputSchema: { type: "object" }
      }
    end
    send_response(id, { tools: tools })

  when "tools/call"
    tool_name = params["name"]
    tool_args = params["arguments"] || {}

    if BEHAVIORS.key?(tool_name)
      BEHAVIORS[tool_name].call(id, tool_args)
    else
      send_error(id, -32601, "Unknown tool: #{tool_name}")
    end

  when "ping"
    send_response(id, {})

  else
    send_error(id, -32601, "Method not found: #{method}")
  end
end
