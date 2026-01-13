# WebSocket Connections as Ractor-Citizens

**Status:** Exploration
**Date:** 2025-12-30

## Context

`Umi::Proctor` wraps external processes as Ractor-citizens with:
- Bidirectional messaging (stdin/stdout as send/receive)
- Death notification (via `Ractor.monitor`)
- Isolation (process crashes become messages, not Ruby crashes)
- OTP-style tagged tuples for pattern matching

This pattern works beautifully. The question: should we apply the same pattern to
WebSocket connections?

### The Use Case: Local TUI-Like Applications

Consider an application that:
- Orchestrates multiple external processes (via Proctor)
- Presents a rich UI in a browser (local only, dozens of connections)
- Streams process output to UI panels with syntax highlighting
- Accepts commands from the UI

The natural main loop wants to `Ractor.select` across *all* message sources:

```ruby
loop do
  case Ractor.select(claude_proctor.inbox, ui_socket.inbox, health_proctor.inbox)
  in [_, [:stdout, line]]      # Process output → route to UI
  in [_, [:message, cmd]]      # UI command → dispatch
  in [_, [:closed, _]]         # Something died → handle
  end
end
```

This requires WebSocket connections to speak the same language as Proctors.

## The Problem WebSocket Libraries Solve (and Don't)

Most WebSocket libraries (Iodine, Faye, ActionCable, async-websocket) provide:
- Connection lifecycle callbacks (`on_open`, `on_message`, `on_close`)
- Send/receive primitives
- Sometimes pub/sub

What they don't provide:
- Integration with `Ractor.select` (they use callbacks, not ports)
- Tagged-tuple message protocol
- Uniform interface with other message sources
- Ractor-based isolation

### Iodine Specifically

Iodine is a C-extension HTTP/WebSocket server that runs outside the GVL:
- ~7x Puma's throughput in benchmarks
- epoll/kqueue evented I/O
- Handles thousands of concurrent connections
- Built-in pub/sub across forked workers
- WebSocket and SSE share the same callback API

For local-only use, it's arguably overbuilt but would work with zero fuss.
However, it's callback-based—you register handlers, not select on ports.

**Key limitation:** TLS/SSL is explicitly not production-ready. Fine for local.

## Proposed Abstraction: `Umi::Socket`

A wrapper that presents WebSocket connections as Ractor-citizens:

```ruby
# Server creates Socket instances for each connection
socket = Umi::Socket.new(websocket_connection, id: client_id)

# Same tagged-tuple pattern as Proctor
case socket.pop(timeout: 1.0)
in [:message, data]    # Client sent us something
in [:connected, id]    # New connection established
in [:closed, reason]   # Connection died (disconnect, error, timeout)
in nil                 # Timeout - do other work
end

# Send to client
socket << { panel: :main, html: "<span class='highlight'>...</span>" }
```

### How It Would Work

```
┌─────────────────────────────────────────────────────────────┐
│  Main Ractor                                                │
│                                                             │
│  Ractor.select(proctor.inbox, socket.inbox, ...)           │
│       ↑                            ↑                        │
│       │ [:stdout, line]            │ [:message, cmd]        │
│       │ [:closed, result]          │ [:closed, reason]      │
└───────┼────────────────────────────┼────────────────────────┘
        │                            │
┌───────┴───────┐            ┌───────┴───────┐
│ Watcher Ractor │            │ Socket Ractor │
│ (process I/O)  │            │ (WebSocket)   │
│                │            │               │
│ Thread: stdout │            │ Thread: recv  │
│ Thread: stderr │            │ Thread: send  │
│ Thread: wait   │            │               │
└───────┬────────┘            └───────┬───────┘
        │                             │
   External Process              Browser/Client
```

The Socket Ractor:
1. Owns the WebSocket connection
2. Runs receive loop in a thread, sends `[:message, data]` to inbox port
3. Accepts outgoing messages via Ractor.receive, writes to socket
4. Detects disconnection, sends `[:closed, reason]` to inbox port
5. Parent monitors via `Ractor.monitor`

### API Sketch

```ruby
module Umi
  class Socket
    # Result of a closed connection
    class CloseResult
      attr_reader :code, :reason, :clean
      def clean? = @clean
    end

    attr_reader :id, :inbox

    def initialize(ws_connection, id:)
      @id = id
      @inbox = Ractor::Port.new
      start_handler(ws_connection)
    end

    # Send data to client (JSON-encodes by default)
    def <<(data)
      send_command(:send, data)
      self
    end

    # Receive with timeout, tagged-tuple style
    def pop(timeout: 2.0)
      # Same pattern as Proctor
    end

    # Raising version
    def pop!(timeout: 120.0)
      # Same pattern as Proctor
    end

    # Close the connection
    def close(code: 1000, reason: "Normal closure")
      send_command(:close, code, reason)
    end

    def alive?
      !@closed
    end
  end
end
```

### Server Integration

The server (Iodine, Falcon, etc.) would hand off connections:

```ruby
# With Iodine
class WebSocketHandler
  def on_open(client)
    socket = Umi::Socket.new(client, id: SecureRandom.uuid)
    SocketRegistry.register(socket)
  end
end

# Main loop selects across all sockets
loop do
  inboxes = [main_proctor.inbox] + SocketRegistry.all.map(&:inbox)

  case Ractor.select(*inboxes)
  in [socket_inbox, [:message, data]]
    socket = SocketRegistry.find_by_inbox(socket_inbox)
    handle_command(socket, data)
  in [proctor_inbox, [:stdout, line]]
    broadcast_to_panels(line)
  # ...
  end
end
```

## Comparison: Proctor vs Socket

| Aspect | Proctor | Socket |
|--------|---------|--------|
| Wraps | External process | WebSocket connection |
| Bidirectional | stdin/stdout | send/receive frames |
| Death detection | Process exit | Connection close |
| Death causes | Exit code, signal | Close code, network error |
| Streams | stdout, stderr (separate) | Single message stream |
| Lifetime | Controlled (we spawn it) | External (client connects) |
| Identity | PID | Client ID (assigned) |
| Reconnection | Our choice | Client's choice |

### Key Differences

1. **Lifetime control:** We spawn processes; clients connect to us
2. **Reconnection:** A Proctor can restart a process; a Socket can't force reconnection
3. **Multiplicity:** One process per Proctor; potentially many Sockets per client (if they open multiple)
4. **Backpressure:** Process stdout can be slow-consumed; WebSocket needs explicit flow control

## Open Questions

### 1. Registry and Identity

Proctors are created explicitly. Sockets appear when clients connect. Need:
- A registry to track active sockets
- Identity assignment (UUID? Token-based? User-provided?)
- Lifecycle hooks (on_connect, on_disconnect at registry level)

### 2. Reconnection Semantics

When a client reconnects, is it:
- A new Socket (new identity)?
- Resumed session (same identity, state preserved)?

For TUI-like local apps, probably new Socket is fine. For stateful apps, need
session tokens and state restoration.

### 3. Backpressure

If we send faster than the client can receive:
- Buffer until memory exhaustion?
- Drop oldest messages?
- Block sender?
- Signal backpressure to sender?

Proctor doesn't have this problem—we control consumption rate. With Sockets,
the client controls receive rate.

### 4. Broadcast

Common pattern: send same message to many sockets. Options:
- Loop and send individually
- Pub/sub layer (Iodine has this built-in)
- Explicit broadcast primitive in registry

### 5. Server Choice

Options for the underlying WebSocket server:

| Server | Pros | Cons |
|--------|------|------|
| Iodine | Fast, built-in pub/sub, fork-aware | C extension, TLS issues |
| Falcon + async-websocket | Async-native, fiber-friendly | More moving parts |
| Faye::WebSocket + Thin | Simple, well-documented | Older, less performant |
| Raw socket | Maximum control | Maximum work |

For local-only TUI apps, any of these work. Iodine is probably simplest.

## Relationship to Anima UI

This abstraction would sit beneath a DSL-driven UI layer:

```
┌─ Anima DSL ──────────────────────────────────────────┐
│  screen do                                           │
│    panel :logs, source: :claude, highlight: :ruby   │
│  end                                                 │
├──────────────────────────────────────────────────────┤
│  Panel routing, syntax highlighting, layout          │
├──────────────────────────────────────────────────────┤
│  Umi::Socket (WebSocket ↔ Ractor)                   │
│  Umi::Proctor (Process ↔ Ractor)                    │
├──────────────────────────────────────────────────────┤
│  Ractor.select main loop                             │
└──────────────────────────────────────────────────────┘
```

The DSL generates:
1. HTML layout (CSS Grid, panel containers)
2. Backend wiring (which Proctor → which panel → which Socket)
3. Frontend JS (WebSocket client, message routing, scroll management)

Umi::Socket makes the middle layer clean—all message sources look the same.

## Next Steps

1. **Spike:** Wrap Iodine WebSocket in minimal Ractor adapter, verify `Ractor.select` works
2. **API refinement:** Iterate on pop/push semantics based on real usage
3. **Registry design:** How sockets are tracked, lifecycle hooks
4. **Integration test:** Proctor + Socket in same select loop

## References

- [Iodine GitHub](https://github.com/boazsegev/iodine)
- [Proctor implementation](../lib/umi/proctor.rb)
- [Ruby 4.0 Ractor documentation](https://docs.ruby-lang.org/en/master/Ractor.html)
- Nygard, Michael T. *Release It!* — Stability patterns that inform this design
