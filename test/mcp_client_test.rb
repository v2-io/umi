#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for ROTP::MCPClient

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'rotp/mcp_client'

MOCK_SERVER = File.expand_path('fixtures/mcp/echo_server.rb', __dir__)

def test(name)
  print "#{name}... "
  begin
    yield
    puts "OK"
    true
  rescue => e
    puts "FAIL"
    puts "  #{e.class}: #{e.message}"
    puts "  #{e.backtrace.first(3).join("\n  ")}"
    false
  end
end

def assert(condition, msg = "assertion failed")
  raise msg unless condition
end

def assert_equal(expected, actual)
  raise "expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

puts "=" * 60
puts "ROTP::MCPClient Tests"
puts "Ruby #{RUBY_VERSION}"
puts "=" * 60
puts

results = []

# =============================================================================
# Basic lifecycle
# =============================================================================
puts "--- Lifecycle ---"

results << test("start and close") do
  client = ROTP::MCPClient.new("ruby", MOCK_SERVER)

  info = client.start
  assert info["name"] == "test-echo-server", "wrong server name: #{info.inspect}"
  assert client.alive?, "should be alive after start"

  result = client.close
  assert result.success?, "should exit cleanly"
  assert !client.alive?, "should not be alive after close"
end

results << test("server_info and capabilities available after start") do
  client = ROTP::MCPClient.new("ruby", MOCK_SERVER)
  client.start

  assert client.server_info["name"] == "test-echo-server"
  assert client.server_info["version"] == "1.0.0"
  assert client.server_capabilities.key?("tools")

  client.close
end

# =============================================================================
# Tool operations
# =============================================================================
puts "\n--- Tools ---"

results << test("list_tools returns tool definitions") do
  client = ROTP::MCPClient.new("ruby", MOCK_SERVER)
  client.start

  tools = client.list_tools
  assert tools.is_a?(Array), "expected array"
  assert tools.length == 4, "expected 4 tools, got #{tools.length}"

  echo_tool = tools.find { |t| t["name"] == "echo" }
  assert echo_tool, "should have echo tool"
  assert echo_tool["description"] == "Echoes back the input"

  client.close
end

results << test("call_tool with echo") do
  client = ROTP::MCPClient.new("ruby", MOCK_SERVER)
  client.start

  content = client.call_tool("echo", message: "hello world")
  assert content.is_a?(Array), "expected array content"
  assert content[0]["type"] == "text"
  assert content[0]["text"] == "hello world"

  client.close
end

results << test("call_tool with add") do
  client = ROTP::MCPClient.new("ruby", MOCK_SERVER)
  client.start

  content = client.call_tool("add", a: 2, b: 3)
  assert content[0]["text"] == "5.0", "expected 5.0, got #{content[0]["text"]}"

  client.close
end

results << test("multiple sequential calls") do
  client = ROTP::MCPClient.new("ruby", MOCK_SERVER)
  client.start

  5.times do |i|
    content = client.call_tool("echo", message: "msg#{i}")
    assert content[0]["text"] == "msg#{i}"
  end

  client.close
end

# =============================================================================
# Timeout handling
# =============================================================================
puts "\n--- Timeouts ---"

results << test("short timeout raises TimeoutError") do
  client = ROTP::MCPClient.new("ruby", MOCK_SERVER, timeout: 0.1)
  client.start

  raised = false
  begin
    # slow tool delays for 1 second, but timeout is 0.1s
    client.call_tool("slow", delay: 1)
  rescue ROTP::MCPClient::TimeoutError
    raised = true
  end

  assert raised, "expected TimeoutError"

  client.close rescue nil
end

results << test("per-request timeout override") do
  client = ROTP::MCPClient.new("ruby", MOCK_SERVER, timeout: 0.1)
  client.start

  # Default would timeout, but we override
  content = client.call("tools/call",
    { name: "slow", arguments: { delay: 0.2 } },
    timeout: 2
  )

  assert content["content"][0]["text"].include?("done")

  client.close
end

# =============================================================================
# Error handling
# =============================================================================
puts "\n--- Errors ---"

results << test("unknown method raises ServerError") do
  client = ROTP::MCPClient.new("ruby", MOCK_SERVER)
  client.start

  raised = false
  begin
    client.call("nonexistent/method")
  rescue ROTP::MCPClient::ServerError => e
    raised = true
    assert e.code == -32601, "expected -32601 error code"
    assert e.message.include?("not found")
  end

  assert raised, "expected ServerError"

  client.close
end

results << test("unknown tool raises ServerError") do
  client = ROTP::MCPClient.new("ruby", MOCK_SERVER)
  client.start

  raised = false
  begin
    client.call_tool("nonexistent_tool")
  rescue ROTP::MCPClient::ServerError => e
    raised = true
    assert e.message.include?("Unknown tool")
  end

  assert raised, "expected ServerError"

  client.close
end

results << test("server exit raises ProtocolError") do
  client = ROTP::MCPClient.new("ruby", "-e", "puts '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}'; exit 0")

  # Initialize succeeds
  client.instance_variable_set(:@started, true)
  client.instance_variable_set(:@shellac, ROTP::Shellac.new("ruby", "-e",
    'puts \'{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"x","version":"1"}}}\'; exit 0'))

  # First call works (init)
  result = client.call("initialize", {})

  # Server has exited, next call should fail
  raised = false
  begin
    client.call("tools/list")
  rescue ROTP::MCPClient::ProtocolError => e
    raised = true
    assert e.message.include?("exited")
  end

  assert raised, "expected ProtocolError"
end

# =============================================================================
# OTP-like patterns with MCP
# =============================================================================
puts "\n--- OTP-like patterns ---"

results << test("ping as heartbeat") do
  client = ROTP::MCPClient.new("ruby", MOCK_SERVER)
  client.start

  # Use ping for health checking with short timeout
  3.times do
    result = client.call("ping", {}, timeout: 1)
    assert result.is_a?(Hash), "ping should return empty object"
  end

  client.close
end

results << test("concurrent clients to same server type") do
  clients = 3.times.map { ROTP::MCPClient.new("ruby", MOCK_SERVER) }

  # Start all
  clients.each(&:start)

  # All should work independently
  clients.each_with_index do |client, i|
    content = client.call_tool("echo", message: "client#{i}")
    assert content[0]["text"] == "client#{i}"
  end

  # Close all
  clients.each(&:close)
end

results << test("rapid request/response cycle") do
  client = ROTP::MCPClient.new("ruby", MOCK_SERVER)
  client.start

  20.times do |i|
    content = client.call_tool("add", a: i, b: 1)
    expected = (i + 1).to_f.to_s
    assert content[0]["text"] == expected, "expected #{expected}, got #{content[0]["text"]}"
  end

  client.close
end

results << test("drain_stderr captures server debug output") do
  # Create a server that writes to stderr
  server_script = <<~RUBY
    $stdout.sync = true
    $stderr.sync = true
    $stderr.puts "debug: starting"
    line = gets
    $stderr.puts "debug: got request"
    puts '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"x","version":"1"}}}'
    sleep 0.1
  RUBY

  client = ROTP::MCPClient.new("ruby", "-e", server_script)
  client.start

  sleep 0.1  # Let stderr arrive

  stderr = client.drain_stderr
  assert stderr.any? { |l| l.include?("debug") }, "should capture stderr: #{stderr.inspect}"

  client.close rescue nil
end

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
passed = results.count(true)
failed = results.count(false)
puts "Results: #{passed} passed, #{failed} failed"
puts "=" * 60

exit(failed > 0 ? 1 : 0)
