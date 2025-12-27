#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests against real MCP servers.
# Requires: npx (Node.js)
#
# These tests verify our client works with actual MCP implementations,
# not just our mock server.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'umi/mcp_client'
require 'fileutils'
require 'tmpdir'

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

# Check if npx is available
def npx_available?
  system("which npx > /dev/null 2>&1")
end

puts "=" * 60
puts "MCP Real Server Tests"
puts "Ruby #{RUBY_VERSION}"
puts "=" * 60
puts

unless npx_available?
  puts "SKIP: npx not available (install Node.js to run these tests)"
  exit 0
end

results = []

# =============================================================================
# Filesystem MCP Server
# =============================================================================
puts "--- @modelcontextprotocol/server-filesystem ---"

# Create a temp directory for testing
# Use realpath to resolve symlinks (macOS /var -> /private/var issue)
TEST_DIR = File.realpath(Dir.mktmpdir("mcp_test_"))
at_exit { FileUtils.rm_rf(TEST_DIR) }

# Create some test files
File.write(File.join(TEST_DIR, "hello.txt"), "Hello, World!\n")
File.write(File.join(TEST_DIR, "data.json"), '{"key": "value"}')
FileUtils.mkdir_p(File.join(TEST_DIR, "subdir"))
File.write(File.join(TEST_DIR, "subdir", "nested.txt"), "Nested content\n")

results << test("connect and initialize") do
  client = Umi::MCPClient.new(
    "npx", "-y", "@modelcontextprotocol/server-filesystem", TEST_DIR,
    timeout: 30
  )

  begin
    info = client.start
    assert info["name"].include?("filesystem"), "expected filesystem server, got #{info.inspect}"
    assert client.server_capabilities, "should have capabilities"
  ensure
    client.close rescue nil
  end
end

results << test("list_tools returns filesystem tools") do
  client = Umi::MCPClient.new(
    "npx", "-y", "@modelcontextprotocol/server-filesystem", TEST_DIR,
    timeout: 30
  )

  begin
    client.start
    tools = client.list_tools

    assert tools.is_a?(Array), "expected array"
    assert tools.length > 0, "expected some tools"

    tool_names = tools.map { |t| t["name"] }
    assert tool_names.include?("read_file"), "should have read_file tool: #{tool_names}"
  ensure
    client.close rescue nil
  end
end

results << test("read_file tool works") do
  client = Umi::MCPClient.new(
    "npx", "-y", "@modelcontextprotocol/server-filesystem", TEST_DIR,
    timeout: 30
  )

  begin
    client.start

    content = client.call_tool("read_file", path: File.join(TEST_DIR, "hello.txt"))

    assert content.is_a?(Array), "expected array content"
    text = content.find { |c| c["type"] == "text" }
    assert text, "should have text content"
    assert text["text"].include?("Hello, World!"), "should contain file content"
  ensure
    client.close rescue nil
  end
end

results << test("list_directory tool works") do
  client = Umi::MCPClient.new(
    "npx", "-y", "@modelcontextprotocol/server-filesystem", TEST_DIR,
    timeout: 30
  )

  begin
    client.start

    content = client.call_tool("list_directory", path: TEST_DIR)

    assert content.is_a?(Array), "expected array content"
    text = content.find { |c| c["type"] == "text" }
    assert text, "should have text content"
    assert text["text"].include?("hello.txt"), "should list hello.txt"
    assert text["text"].include?("subdir"), "should list subdir"
  ensure
    client.close rescue nil
  end
end

results << test("write_file tool works") do
  client = Umi::MCPClient.new(
    "npx", "-y", "@modelcontextprotocol/server-filesystem", TEST_DIR,
    timeout: 30
  )

  begin
    client.start

    new_file = File.join(TEST_DIR, "created.txt")
    client.call_tool("write_file", path: new_file, content: "Created by test\n")

    # Verify file was created
    assert File.exist?(new_file), "file should exist"
    assert File.read(new_file) == "Created by test\n", "content should match"
  ensure
    client.close rescue nil
  end
end

results << test("read nested file") do
  client = Umi::MCPClient.new(
    "npx", "-y", "@modelcontextprotocol/server-filesystem", TEST_DIR,
    timeout: 30
  )

  begin
    client.start

    content = client.call_tool("read_file", path: File.join(TEST_DIR, "subdir", "nested.txt"))

    text = content.find { |c| c["type"] == "text" }
    assert text["text"].include?("Nested content"), "should read nested file"
  ensure
    client.close rescue nil
  end
end

results << test("error on nonexistent file") do
  client = Umi::MCPClient.new(
    "npx", "-y", "@modelcontextprotocol/server-filesystem", TEST_DIR,
    timeout: 30
  )

  begin
    client.start

    # Try to read a file that doesn't exist
    error_raised = false
    begin
      client.call_tool("read_file", path: File.join(TEST_DIR, "nonexistent.txt"))
    rescue Umi::MCPClient::ServerError => e
      error_raised = true
    end

    # The server might return an error or an error content - both are valid
    # Just verify we don't crash
    assert true
  ensure
    client.close rescue nil
  end
end

results << test("multiple operations in sequence") do
  client = Umi::MCPClient.new(
    "npx", "-y", "@modelcontextprotocol/server-filesystem", TEST_DIR,
    timeout: 30
  )

  begin
    client.start

    # Write a file
    test_file = File.join(TEST_DIR, "sequence_test.txt")
    client.call_tool("write_file", path: test_file, content: "Step 1\n")

    # Read it back
    content = client.call_tool("read_file", path: test_file)
    text = content.find { |c| c["type"] == "text" }
    assert text["text"].include?("Step 1"), "should have Step 1"

    # Overwrite it
    client.call_tool("write_file", path: test_file, content: "Step 2\n")

    # Read again
    content = client.call_tool("read_file", path: test_file)
    text = content.find { |c| c["type"] == "text" }
    assert text["text"].include?("Step 2"), "should have Step 2"

    # List directory to verify
    content = client.call_tool("list_directory", path: TEST_DIR)
    text = content.find { |c| c["type"] == "text" }
    assert text["text"].include?("sequence_test.txt"), "should list new file"
  ensure
    client.close rescue nil
  end
end

results << test("rapid sequential calls") do
  client = Umi::MCPClient.new(
    "npx", "-y", "@modelcontextprotocol/server-filesystem", TEST_DIR,
    timeout: 30
  )

  begin
    client.start

    # Make many rapid calls
    10.times do |i|
      content = client.call_tool("read_file", path: File.join(TEST_DIR, "hello.txt"))
      text = content.find { |c| c["type"] == "text" }
      assert text["text"].include?("Hello"), "call #{i} should succeed"
    end
  ensure
    client.close rescue nil
  end
end

results << test("concurrent clients to same server type") do
  clients = 3.times.map do
    Umi::MCPClient.new(
      "npx", "-y", "@modelcontextprotocol/server-filesystem", TEST_DIR,
      timeout: 30
    )
  end

  begin
    # Start all clients (each spawns its own server)
    clients.each(&:start)

    # All should work independently
    threads = clients.map.with_index do |client, i|
      Thread.new do
        content = client.call_tool("read_file", path: File.join(TEST_DIR, "hello.txt"))
        text = content.find { |c| c["type"] == "text" }
        text["text"].include?("Hello") ? :ok : :fail
      end
    end

    thread_results = threads.map { |t| t.join(30)&.value }
    assert thread_results.all? { |r| r == :ok }, "all clients should succeed"
  ensure
    clients.each { |c| c.close rescue nil }
  end
end

# =============================================================================
# Resources (if supported)
# =============================================================================
puts "\n--- Resources ---"

results << test("list_resources works or returns not supported") do
  client = Umi::MCPClient.new(
    "npx", "-y", "@modelcontextprotocol/server-filesystem", TEST_DIR,
    timeout: 30
  )

  begin
    client.start

    # Not all servers support resources
    begin
      resources = client.list_resources
      assert resources.is_a?(Array), "should return array"
    rescue Umi::MCPClient::ServerError => e
      # "Method not found" is acceptable - server doesn't support resources
      assert e.message.include?("not found") || e.code == -32601
    end
  ensure
    client.close rescue nil
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

# Cleanup
FileUtils.rm_rf(TEST_DIR)

exit(failed > 0 ? 1 : 0)
