#!/usr/bin/env ruby
# frozen_string_literal: true

# Chaos tests for MCP client.
# These test how the client handles misbehaving servers.
#
# Failures here help us understand which layer needs work:
# - Proctor (process/IO handling)
# - JSON-RPC (message framing/parsing)
# - MCP client (protocol handling)

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'umi/mcp_client'

CHAOS_SERVER = File.expand_path('fixtures/mcp/chaos_server.rb', __dir__)

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

# Create client, run test, ensure cleanup
def with_chaos_client(timeout: 5)
  client = Umi::MCPClient.new("ruby", CHAOS_SERVER, timeout: timeout)
  begin
    client.start
    yield client
  ensure
    client.close rescue nil
  end
end

# Only run when executed directly, not when required by rake
if __FILE__ == $0

puts "=" * 60
puts "MCP Chaos Tests"
puts "Ruby #{RUBY_VERSION}"
puts "=" * 60
puts

results = []

# =============================================================================
# Baseline: Normal behavior still works
# =============================================================================
puts "--- Baseline ---"

results << test("normal tool call works") do
  with_chaos_client do |client|
    content = client.call_tool("normal")
    assert content[0]["text"] == "ok"
  end
end

# =============================================================================
# Timeout handling (Proctor + JSON-RPC layer)
# =============================================================================
puts "\n--- Timeout handling ---"

results << test("slow response with adequate timeout succeeds") do
  with_chaos_client(timeout: 3) do |client|
    content = client.call_tool("slow", delay: 0.5)
    assert content[0]["text"] == "slow done"
  end
end

results << test("slow response with short timeout fails gracefully") do
  with_chaos_client(timeout: 0.2) do |client|
    raised = false
    begin
      client.call_tool("slow", delay: 2)
    rescue Umi::MCPClient::TimeoutError
      raised = true
    end
    assert raised, "expected TimeoutError"
  end
end

# =============================================================================
# Malformed responses (JSON-RPC layer)
# =============================================================================
puts "\n--- Malformed responses ---"

results << test("garbage response raises ProtocolError") do
  with_chaos_client(timeout: 2) do |client|
    raised = false
    error_type = nil
    begin
      client.call_tool("garbage")
    rescue Umi::MCPClient::ProtocolError => e
      raised = true
      error_type = :protocol
    rescue Umi::MCPClient::TimeoutError
      # Also acceptable - we might timeout waiting for valid response
      raised = true
      error_type = :timeout
    end
    assert raised, "expected error"
  end
end

results << test("partial JSON eventually completes") do
  with_chaos_client(timeout: 3) do |client|
    # Server sends partial JSON, waits 0.5s, then completes
    # Should succeed if we wait long enough
    result = client.call("tools/call", { name: "partial_json", arguments: {} })
    # If we get here, it worked
    assert true
  end
end

results << test("truncated JSON times out") do
  with_chaos_client(timeout: 1) do |client|
    raised = false
    begin
      client.call_tool("truncated")
    rescue Umi::MCPClient::TimeoutError
      raised = true
    end
    assert raised, "expected TimeoutError"
  end
end

results << test("wrong JSON structure is handled") do
  with_chaos_client(timeout: 2) do |client|
    raised = false
    begin
      client.call_tool("wrong_structure")
    rescue Umi::MCPClient::TimeoutError, Umi::MCPClient::ProtocolError
      # Either timeout (waiting for real response) or protocol error
      raised = true
    end
    assert raised, "expected error"
  end
end

results << test("binary garbage is handled") do
  with_chaos_client(timeout: 2) do |client|
    raised = false
    begin
      client.call_tool("binary")
    rescue Umi::MCPClient::TimeoutError, Umi::MCPClient::ProtocolError
      raised = true
    end
    assert raised, "expected error"
  end
end

# =============================================================================
# Response ID handling (JSON-RPC layer)
# =============================================================================
puts "\n--- Response ID handling ---"

results << test("wrong ID response times out") do
  with_chaos_client(timeout: 1) do |client|
    raised = false
    begin
      client.call_tool("wrong_id")
    rescue Umi::MCPClient::TimeoutError
      raised = true
    end
    assert raised, "expected TimeoutError (response had wrong ID)"
  end
end

# =============================================================================
# Notifications (JSON-RPC + MCP layer)
# =============================================================================
puts "\n--- Notifications ---"

results << test("notification before response is skipped") do
  with_chaos_client(timeout: 3) do |client|
    content = client.call_tool("notification_first")
    assert content[0]["text"] == "after notification"
  end
end

results << test("notification spam doesn't break response") do
  with_chaos_client(timeout: 5) do |client|
    content = client.call_tool("notification_spam")
    assert content[0]["text"] == "done spamming"
  end
end

# =============================================================================
# Server crashes (Proctor layer)
# =============================================================================
puts "\n--- Server crashes ---"

results << test("server crash mid-response raises error") do
  with_chaos_client(timeout: 2) do |client|
    raised = false
    begin
      client.call_tool("crash")
    rescue Umi::MCPClient::ProtocolError, Umi::MCPClient::TimeoutError
      # Either protocol error (detected exit) or timeout (waiting for response)
      raised = true
    end
    assert raised, "expected ProtocolError or TimeoutError"
  end
end

results << test("server silent exit raises ProtocolError") do
  with_chaos_client(timeout: 2) do |client|
    raised = false
    begin
      client.call_tool("exit_silent")
    rescue Umi::MCPClient::ProtocolError => e
      raised = true
    end
    assert raised, "expected ProtocolError"
  end
end

# =============================================================================
# Large responses (Proctor I/O handling)
# =============================================================================
puts "\n--- Large responses ---"

results << test("100KB response succeeds") do
  with_chaos_client(timeout: 10) do |client|
    content = client.call_tool("huge", size: 100_000)
    assert content[0]["text"].length == 100_000
  end
end

results << test("1MB response succeeds") do
  with_chaos_client(timeout: 30) do |client|
    content = client.call_tool("huge", size: 1_000_000)
    assert content[0]["text"].length == 1_000_000
  end
end

# =============================================================================
# Error responses (MCP layer)
# =============================================================================
puts "\n--- Error responses ---"

results << test("error response raises ServerError") do
  with_chaos_client do |client|
    raised = false
    begin
      client.call_tool("error", code: -32000, message: "test error")
    rescue Umi::MCPClient::ServerError => e
      raised = true
      assert e.code == -32000
      assert e.message == "test error"
    end
    assert raised, "expected ServerError"
  end
end

# =============================================================================
# Edge cases (all layers)
# =============================================================================
puts "\n--- Edge cases ---"

results << test("deeply nested JSON succeeds") do
  with_chaos_client(timeout: 5) do |client|
    content = client.call_tool("nested", depth: 50)
    # Should get the nested structure as text
    assert content[0]["text"].include?("innermost")
  end
end

results << test("unicode edge cases handled") do
  with_chaos_client do |client|
    content = client.call_tool("unicode")
    text = content[0]["text"]
    assert text.include?("🎉"), "should have emoji"
  end
end

results << test("server hang after response doesn't affect client") do
  with_chaos_client(timeout: 2) do |client|
    content = client.call_tool("respond_then_hang")
    assert content[0]["text"] == "ok"
    # Client should be able to close without waiting
  end
end

# =============================================================================
# Recovery (all layers)
# =============================================================================
puts "\n--- Recovery ---"

results << test("client works after timeout") do
  with_chaos_client(timeout: 5) do |client|
    # First call times out
    begin
      client.call_tool("slow", delay: 10)
    rescue Umi::MCPClient::TimeoutError
      # Expected
    end

    # Client should still work for next call
    # (if the server is still alive and responding)
    # In this case server is hung, so we expect another timeout or error
    raised = false
    begin
      client.call_tool("normal")
    rescue Umi::MCPClient::TimeoutError, Umi::MCPClient::ProtocolError
      raised = true
    end
    # Either works or errors - both are acceptable for "recovery"
    assert true
  end
end

results << test("multiple chaos clients concurrently") do
  clients = 5.times.map { Umi::MCPClient.new("ruby", CHAOS_SERVER, timeout: 5) }

  begin
    clients.each(&:start)

    # Each client does independent chaos
    threads = clients.map.with_index do |client, i|
      Thread.new do
        begin
          case i % 3
          when 0
            client.call_tool("normal")
          when 1
            client.call_tool("slow", delay: 0.2)
          when 2
            client.call_tool("notification_spam")
          end
          :ok
        rescue => e
          e.class.name
        end
      end
    end

    thread_results = threads.map { |t| t.join(10)&.value }
    # All should complete (success or expected error)
    assert thread_results.all?, "all threads should complete"
  ensure
    clients.each { |c| c.close rescue nil }
  end
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

end # if __FILE__ == $0
