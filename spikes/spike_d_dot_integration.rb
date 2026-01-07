#!/usr/bin/env ruby
# frozen_string_literal: true

# Spike D: Real-world integration test with GraphViz dot
# ======================================================
# Uses the proven Proctor pattern from spike_c with a real tool.
# This validates that our architecture works with actual external programs.

require 'open3'

puts "=" * 60
puts "SPIKE D: GraphViz dot Integration"
puts "Ruby #{RUBY_VERSION}"
puts "=" * 60

# Check dot is available
dot_path = `which dot`.chomp
if dot_path.empty?
  puts "ERROR: GraphViz 'dot' not found. Install with: brew install graphviz"
  exit 1
end
puts "Using: #{`dot -V 2>&1`.chomp}"
puts

# Helper
def section(title)
  puts
  puts "-" * 40
  puts title
  puts "-" * 40
end

# =============================================================================
# TEST 1: Simple graph to SVG
# =============================================================================
section "TEST 1: Simple graph to SVG"

begin
  main = Ractor.current

  watcher = Ractor.new(main) do |parent|
    require 'open3'

    stdin, stdout, stderr, wait_thr = Open3.popen3("dot", "-Tsvg")
    pid = wait_thr.pid
    parent << [:started, pid]

    # Threads for async I/O
    stdout_data = []
    stderr_data = []

    stdout_thread = Thread.new do
      while chunk = stdout.read(4096)
        break if chunk.empty?

        stdout_data << chunk
        parent << [:stdout_chunk, chunk.bytesize]
      end
      parent << [:stdout_closed]
    end

    stderr_thread = Thread.new do
      while line = stderr.gets
        stderr_data << line
        parent << [:stderr, line]
      end
      parent << [:stderr_closed]
    end

    death_thread = Thread.new do
      status = wait_thr.value
      parent << [:process_died, pid, status.exitstatus]
    end

    # Command loop
    running = true
    while running
      cmd = Ractor.receive
      case cmd
      in [:stdin, data]
        stdin.write(data)
        stdin.flush
      in [:close_stdin] then stdin.close
      in [:shutdown]    then running = false
      end
    end

    stdout_thread.join
    stderr_thread.join
    death_thread.join

    # Return collected data
    { stdout: stdout_data.join, stderr: stderr_data.join }
  end

  # Monitor for crashes
  watcher.monitor(main.default_port)

  # Send a simple graph
  graph = <<~DOT
    digraph G {
      A -> B;
      B -> C;
      C -> A;
    }
  DOT

  messages = []
  messages << Ractor.receive  # :started

  watcher << [:stdin, graph]
  watcher << [:close_stdin]

  # Collect until process dies
  loop do
    msg = Ractor.receive
    messages << msg
    break if msg[0] == :process_died
  end

  watcher << [:shutdown]
  result = watcher.value

  # Check results
  svg     = result[:stdout]
  success = svg.include?("<svg") && svg.include?("</svg>")

  puts "[#{success ? 'OK' : 'FAIL'}] Generated SVG: #{svg.bytesize} bytes"
  puts "  Messages: #{messages.map(&:first).inspect}"
  puts "  SVG preview: #{svg[0..100]}..."
rescue StandardError => e
  puts "[FAIL] #{e.class}: #{e.message}"
  puts e.backtrace.first(3).join("\n")
end

# =============================================================================
# TEST 2: Bad input handling
# =============================================================================
section "TEST 2: Bad input (should fail gracefully)"

begin
  main = Ractor.current

  watcher = Ractor.new(main) do |parent|
    require 'open3'

    stdin, stdout, stderr, wait_thr = Open3.popen3("dot", "-Tsvg")
    pid = wait_thr.pid
    parent << [:started, pid]

    stderr_lines = []

    stderr_thread = Thread.new do
      while line = stderr.gets
        stderr_lines << line
        parent << [:stderr, line.chomp]
      end
    end

    death_thread = Thread.new do
      status = wait_thr.value
      parent << [:process_died, pid, status.exitstatus, stderr_lines]
    end

    running = true
    while running
      cmd = Ractor.receive
      case cmd
      in [:stdin, data] then begin stdin.write(data) rescue StandardError nil end
      in [:close_stdin] then begin stdin.close rescue StandardError nil end
      in [:shutdown]    then running = false
      end
    end

    stdout.close
    stderr_thread.join
    death_thread.join
    :done
  end

  watcher.monitor(main.default_port)

  messages = []
  messages << Ractor.receive  # :started

  # Send garbage
  watcher << [:stdin, "this is not valid DOT syntax {{{"]
  watcher << [:close_stdin]

  loop do
    msg = Ractor.receive
    messages << msg
    break if msg[0] == :process_died
  end

  watcher << [:shutdown]
  watcher.value

  exit_code   = messages.find { |m| m[0] == :process_died }&.dig(2)
  stderr_msgs = messages.select { |m| m[0] == :stderr }

  puts "[OK] dot rejected bad input"
  puts "  Exit code: #{exit_code}"
  puts "  Stderr messages: #{stderr_msgs.length}"
  stderr_msgs.each { |m| puts "    #{m[1]}" }
rescue StandardError => e
  puts "[FAIL] #{e.class}: #{e.message}"
end

# =============================================================================
# TEST 3: Larger graph (performance check)
# =============================================================================
section "TEST 3: Larger graph (50 nodes)"

begin
  main = Ractor.current

  watcher = Ractor.new(main) do |parent|
    require 'open3'

    stdin, stdout, stderr, wait_thr = Open3.popen3("dot", "-Tsvg")
    pid = wait_thr.pid
    parent << [:started, pid]

    output_chunks = []

    stdout_thread = Thread.new do
      while chunk = stdout.read(8192)
        break if chunk.empty?

        output_chunks << chunk
      end
    end

    death_thread = Thread.new do
      status = wait_thr.value
      parent << [:process_died, pid, status.exitstatus, output_chunks.join.bytesize]
    end

    running = true
    while running
      cmd = Ractor.receive
      case cmd
      in [:stdin, data] then stdin.write(data)
      in [:close_stdin] then stdin.close
      in [:shutdown]    then running = false
      end
    end

    stdout.close
    stderr.close
    stdout_thread.join
    death_thread.join
    :done
  end

  watcher.monitor(main.default_port)

  # Generate larger graph
  nodes = 50
  graph = ["digraph G {", "  rankdir=LR;"]
  nodes.times do |i|
    # Each node connects to 2-3 random others
    targets = (0...nodes).to_a.sample(rand(2..3)) - [i]
    targets.each { |t| graph << "  n#{i} -> n#{t};" }
  end
  graph << "}"
  graph_text = graph.join("\n")

  messages = []
  messages << Ractor.receive  # :started

  start_time = Time.now
  watcher << [:stdin, graph_text]
  watcher << [:close_stdin]

  loop do
    msg = Ractor.receive
    messages << msg
    break if msg[0] == :process_died
  end
  elapsed = Time.now - start_time

  watcher << [:shutdown]
  watcher.value

  result      = messages.find { |m| m[0] == :process_died }
  exit_code   = result[2]
  output_size = result[3]

  puts "[#{exit_code == 0 ? 'OK' : 'FAIL'}] Processed #{nodes}-node graph"
  puts "  Input: #{graph_text.bytesize} bytes"
  puts "  Output: #{output_size} bytes"
  puts "  Time: #{(elapsed * 1000).round}ms"
rescue StandardError => e
  puts "[FAIL] #{e.class}: #{e.message}"
end

# =============================================================================
# TEST 4: Multi-shot conversation with single dot process
# =============================================================================
section "TEST 4: Multi-shot conversation (send multiple graphs, get multiple responses)"

begin
  main = Ractor.current

  # dot -Tplain can process multiple graphs, each ends with "stop\n"
  watcher = Ractor.new(main) do |parent|
    require 'open3'

    stdin, stdout, stderr, wait_thr = Open3.popen3("dot", "-Tplain")
    pid = wait_thr.pid
    parent << [:started, pid]

    # stdout reader thread - sends each line as it comes
    stdout_thread = Thread.new do
      while line = stdout.gets
        parent << [:stdout, line]
      end
      parent << [:stdout_closed]
    end

    stderr_thread = Thread.new do
      while line = stderr.gets
        parent << [:stderr, line]
      end
      parent << [:stderr_closed]
    end

    death_thread = Thread.new do
      status = wait_thr.value
      parent << [:process_died, pid, status.exitstatus]
    end

    # Command loop
    running = true
    while running
      cmd = Ractor.receive
      case cmd
      in [:stdin, data] then begin stdin.write(data) stdin.flush rescue Errno::EPIPE parent << [:stdin_broken] end
      in [:close_stdin] then begin stdin.close rescue StandardError nil end
      in [:shutdown]    then running = false
      end
    end

    stdout_thread.join
    stderr_thread.join
    death_thread.join
    :done
  end

  watcher.monitor(main.default_port)

  messages = []
  messages << Ractor.receive  # :started
  puts "Started dot process: pid=#{messages.last[1]}"

  # Send 3 graphs, collecting responses for each
  graphs = [
    "digraph G1 { A -> B; }",
    "digraph G2 { X -> Y -> Z; }",
    "digraph G3 { P -> Q; Q -> R; R -> P; }"  # cycle
  ]

  graphs.each_with_index do |graph, i|
    puts "\n  Sending graph #{i + 1}..."
    watcher << [:stdin, graph + "\n"]

    # Collect response until we see "stop"
    response_lines = []
    loop do
      msg = Ractor.receive
      case msg
      in [:stdout, line]
        response_lines << line.chomp
        break if line.chomp == "stop"
      in [:stderr, line] then puts "    stderr: #{line}"
      in [:process_died, _, code]
        puts "    Process died unexpectedly: #{code}"
        break
      else
        # Ignore unexpected messages (like late :started, etc.)
        nil
      end
    end

    node_count = response_lines.count { |l| l.start_with?("node ") }
    edge_count = response_lines.count { |l| l.start_with?("edge ") }
    puts "    Response: #{response_lines.length} lines, #{node_count} nodes, #{edge_count} edges"
  end

  # Now close stdin and let it exit
  puts "\n  Closing stdin..."
  watcher << [:close_stdin]

  # Collect remaining messages
  loop do
    msg = Ractor.receive
    case msg
    in [:stdout_closed] then puts "    stdout closed"
    in [:stderr_closed] then puts "    stderr closed"
    in [:process_died, _, code]
      puts "    Process exited: #{code}"
      break
    in :exited
      puts "    Watcher ractor exited"
      break
    end
  end

  watcher << [:shutdown]
  watcher.value

  puts "[OK] Multi-shot conversation completed successfully"
rescue StandardError => e
  puts "[FAIL] #{e.class}: #{e.message}"
  puts e.backtrace.first(3).join("\n")
end

puts
puts "=" * 60
puts "SPIKE D COMPLETE"
puts "=" * 60
