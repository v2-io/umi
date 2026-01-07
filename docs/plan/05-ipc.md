# IPC: Inter-Process Communication for Cross-VM Ractors

This document captures findings from exploring IPC primitives available in Ruby
on POSIX systems (macOS and Linux), with focus on Unix domain sockets for
cross-VM Ractor communication.

**Goal**: Enable Ractor-like semantics across separate Ruby VMs—send messages,
receive messages, detect when the peer goes down.

---

## IPC Options in Ruby

Ruby provides access to most POSIX IPC mechanisms:

| Mechanism | Built-in? | Notes |
|-----------|-----------|-------|
| **Pipes** | Yes | `IO.pipe`, `Open3.popen3` — parent-child, unidirectional |
| **Unix Domain Sockets** | Yes | `UNIXSocket`, `UNIXServer` — bidirectional, fast |
| **Named Pipes (FIFOs)** | Yes | `File.mkfifo` — filesystem-visible pipes |
| **TCP/UDP Sockets** | Yes | `TCPSocket`, `UDPSocket` — network or loopback |
| **PTY** | Yes | `PTY.spawn` — pseudo-terminals for interactive processes |
| **Signals** | Yes | `Process.kill`, `Signal.trap` — limited bandwidth |
| **DRb** | Yes (stdlib) | Distributed Ruby RPC — not Ractor-aware, security concerns |
| **POSIX Shared Memory** | Gem/FFI | `shm_open`/`mmap` — zero-copy but complex |
| **POSIX Message Queues** | Gem/FFI | `mq_open` — kernel-managed queues |

**Our choice: Unix domain sockets** — fast (no network stack), bidirectional,
supports FD passing, supports peer credential verification.

---

## Unix Domain Socket Types

### SOCK_STREAM

Reliable, ordered byte stream (like TCP). Requires framing for message
boundaries.

```ruby
s1, s2 = UNIXSocket.pair(:STREAM)
# or
server = UNIXServer.new("/tmp/my.sock")
client = UNIXSocket.new("/tmp/my.sock")
```

**Pros**: Reliable, flow control, backpressure
**Cons**: No message boundaries — need length-prefix or self-delimiting format

### SOCK_DGRAM

Datagram mode — message boundaries preserved, no connection state.

```ruby
s1, s2 = UNIXSocket.pair(:DGRAM)
s1.send("message one", 0)
s1.send("message two", 0)
s2.recv(1000)  # => "message one" (exactly)
s2.recv(1000)  # => "message two" (exactly)
```

**Pros**: Message boundaries built-in, no framing needed
**Cons**: Default buffer ~2KB on macOS (tunable to 64KB+), no backpressure

### SOCK_SEQPACKET

Connection-oriented with message boundaries — best of both worlds.

```ruby
# Linux only!
s1, s2 = UNIXSocket.pair(:SEQPACKET)
```

**macOS**: `Errno::EPROTONOSUPPORT` — **not supported**

---

## Platform Compatibility Matrix

| Feature | macOS | Linux |
|---------|-------|-------|
| `SOCK_STREAM` | ✅ | ✅ |
| `SOCK_DGRAM` | ✅ | ✅ |
| `SOCK_SEQPACKET` | ❌ | ✅ |
| FD Passing (`SCM_RIGHTS`) | ✅ | ✅ |
| Peer Credentials | ✅ (`getpeereid`) | ✅ (`SO_PEERCRED`) |
| Abstract Namespace (`\0name`) | ❌ | ✅ |

**Implication**: Use `SOCK_STREAM` with self-delimiting format for portability.

---

## Marshal Is Self-Delimiting

Key discovery: Ruby's `Marshal.dump` produces self-delimiting output.
`Marshal.load` reads exactly one object from a stream and stops.

```ruby
stream = UNIXSocket.pair(:STREAM)
s1, s2 = stream

Marshal.dump({type: :hello}, s1)
Marshal.dump({type: :world}, s1)

Marshal.load(s2)  # => {type: :hello}
Marshal.load(s2)  # => {type: :world}
```

**No length prefix needed** when using Marshal over `SOCK_STREAM`.

---

## File Descriptor Passing

Unix domain sockets can pass open file descriptors between processes via
`SCM_RIGHTS` ancillary data. Ruby exposes this cleanly:

```ruby
# Simple API
socket.send_io(file_or_socket)
io = socket.recv_io              # Returns IO
io = socket.recv_io(UNIXServer)  # Returns typed object!

# Low-level API (multiple FDs at once)
fds_packed = [fd1, fd2, fd3].pack("i*")
socket.sendmsg(msg, 0, nil, [Socket::SOL_SOCKET, Socket::SCM_RIGHTS, fds_packed])

msg, _, _, *controls = socket.recvmsg(scm_rights: true)
controls.each do |ctrl|
  if ctrl.cmsg_is?(:SOCKET, :RIGHTS)
    ios = ctrl.unix_rights  # Array of IO objects
  end
end
```

### What Can Be Passed

Any file descriptor:
- Regular files
- Pipes (both ends separately)
- Sockets (including connected TCP sockets!)
- PTYs
- Other Unix domain sockets
- eventfd, timerfd (Linux)

### Use Cases for Umi

**Process hand-off**: Spawn a process, pass its stdin/stdout/stderr to another VM

```ruby
# Supervisor VM spawns, worker VM owns
peer << [:take_process, { pid: pid }]
peer.send_io(child_stdin)
peer.send_io(child_stdout)
peer.send_io(child_stderr)
```

**Zero-copy large data**: Pass file handle instead of contents

```ruby
file = File.open("huge.bin", "r")
peer << [:file_handle, { size: file.size }]
peer.send_io(file)
```

**Connection migration**: Move a client socket to another VM

```ruby
peer << [:migrate_client, { client_id: id }]
peer.send_io(client_socket)
```

**Pipe stitching**: Create pipes that span VMs

```ruby
rd, wr = IO.pipe
peer << [:write_end]
peer.send_io(wr)
wr.close  # Local VM keeps read end only
```

---

## Peer Credentials

The kernel can verify the identity of the process on the other end of a Unix
domain socket. **Cannot be spoofed** — this is kernel-provided authentication.

```ruby
socket = UNIXSocket.new("/tmp/server.sock")
uid, gid = socket.getpeereid
raise "Untrusted!" unless uid == Process.uid
```

**Use case**: Zero-config authentication between trusted VMs on the same machine.

---

## Wire Protocol Design

Given the discoveries above, the Umi peer protocol is simple:

### Envelope Format

```ruby
Envelope = Data.define(:type, :fd_count, :payload)
```

### On The Wire

```
┌─────────────────────────────────────────┐
│  Marshal'd Envelope (self-delimiting)   │
│  { type:, fd_count:, payload: }         │
├─────────────────────────────────────────┤
│  [FDs via SCM_RIGHTS, if fd_count > 0]  │
└─────────────────────────────────────────┘
```

### Implementation (~10 lines)

```ruby
def send_msg(socket, type:, payload:, ios: [])
  env = Envelope.new(type:, fd_count: ios.size, payload:)
  Marshal.dump(env, socket)
  ios.each { |io| socket.send_io(io) }
end

def recv_msg(socket)
  env = Marshal.load(socket)
  fds = env.fd_count.times.map { socket.recv_io }
  [env, fds]
end
```

---

## Message Payload Constraints

Within a single VM, Ractors can share frozen objects by reference (zero-copy)
and use raw memcpy for moves. Across VMs, we must serialize.

### Option: Constrained Marshal

Only allow naturally serializable types:

```ruby
ALLOWED = [
  NilClass, TrueClass, FalseClass,
  Integer, Float, String, Symbol,
  Array, Hash, Range,
  Data,    # All Data subclasses (immutable value objects)
  Struct,  # Frozen Structs
  Time, Regexp, Set
].freeze

def validate_payload!(obj, seen = {}.compare_by_identity)
  return if seen[obj]
  seen[obj] = true

  case obj
  when *ALLOWED
    case obj
    when Array then obj.each { validate_payload!(_1, seen) }
    when Hash then obj.each { |k, v| validate_payload!(k, seen); validate_payload!(v, seen) }
    when Data, Struct then obj.members.each { validate_payload!(obj.send(_1), seen) }
    end
  else
    raise UnsafeMessageError, "#{obj.class} cannot cross VM boundary"
  end
end
```

**Rationale**:
- `Data` objects are immutable, simple, pattern-matchable — natural messages
- Prevents dangerous objects (Procs, IOs, bindings) from crossing
- Aligns with Ractor shareability semantics

---

## Advanced Patterns

### Socket as Mutex (Singleton Process)

`bind()` fails with `EADDRINUSE` if another process holds the socket:

```ruby
begin
  server = UNIXServer.new("/tmp/supervisor.sock")
  # I am the supervisor
rescue Errno::EADDRINUSE
  # Another instance running — connect to it instead
  existing = UNIXSocket.new("/tmp/supervisor.sock")
  existing.puts("takeover_request")
end
```

**Use case**: Supervisor election, single-writer patterns.

### Hot Reload (Zero-Downtime Restart)

Pass the listening socket to a new process version:

```ruby
# Old process
ctrl_socket.send_io(listening_server)
listening_server.close
# Old process exits gracefully

# New process
new_server = ctrl_socket.recv_io(UNIXServer)
# Continue accepting connections — no dropped requests
```

**Use case**: Zero-downtime Umi upgrades.

### DGRAM for Fire-and-Forget

For logging, metrics, or events where message loss is acceptable:

```ruby
# No connection overhead, message boundaries free
# But: 2KB default limit, no backpressure
metrics_socket = UNIXSocket.new("/tmp/metrics.sock", :DGRAM)
metrics_socket.send(Marshal.dump(event), 0)
```

Buffer size is tunable:

```ruby
socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 65536)
```

---

## Umi::Peer Architecture Sketch

Building on `Umi::Proctor` patterns (Watcher Ractor + I/O threads):

```
┌─────────────────────────────────────────────────────────────┐
│                         Umi::Peer                           │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Watcher Ractor                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐   │  │
│  │  │ Unix Socket │  │ Read Thread │  │ Write Thread │   │  │
│  │  │  (owned)    │  │ (recv_io)   │  │ (send_io)    │   │  │
│  │  └─────────────┘  └─────────────┘  └──────────────┘   │  │
│  └───────────────────────────────────────────────────────┘  │
│                           │                                 │
│                           ▼                                 │
│                      User's Port                            │
│                 (messages + received IOs)                   │
└─────────────────────────────────────────────────────────────┘
```

### API (echoing Proctor)

```ruby
# Server
Umi::Peer.listen("/tmp/vm1.sock") do |peer|
  peer << [:hello, { name: "vm1" }]
  msg, fds = peer.receive(timeout: 5.0)
end

# Client
peer = Umi::Peer.connect("/tmp/vm2.sock")
peer.monitor(my_port)  # Get notified if connection dies
peer << [:request, { id: 1 }]
peer.send_io(some_file)
```

### Liveness Detection

Three mechanisms, layered:

1. **Socket close** — Immediate detection when peer crashes/disconnects
2. **Ping/pong heartbeat** — Detect hung peers (configurable interval)
3. **Monitor registration** — Explicit "tell me when this peer dies"

```ruby
# When socket closes or heartbeat times out:
monitored_ports.each do |port|
  port << [:down, { peer: peer_id, reason: :connection_lost }]
end
```

---

## Comparison: Within-VM vs Cross-VM

| Aspect | Within-VM Ractor | Cross-VM Peer |
|--------|------------------|---------------|
| Shareability check | `O(1)` flag or `O(n)` traverse | Must serialize everything |
| Shareable objects | Reference (zero-copy) | Serialize once, cache? |
| Move semantics | memcpy + tombstone | Serialize + local tombstone |
| Object identity | Preserved | Meaningless across VMs |
| GC coordination | Shared GC | Independent GCs |
| Failure detection | `Ractor#monitor` | Socket close + heartbeat |
| Addressing | Port object reference | VM:Port naming scheme |

---

## Open Questions

1. **Payload validation strictness** — How strict should we be? Allow arbitrary
   Marshal (convenient but dangerous) or constrain to Data/Struct/primitives
   (safe but limiting)?

2. **Naming/addressing** — How do we address remote Ractors? Options:
   - `"vm_name:ractor_name"` strings
   - `RemotePort` objects that encapsulate address
   - Registry-based lookup with discovery

3. **Reconnection semantics** — What happens when a peer disconnects and
   reconnects? Same peer identity? Message replay? Clean slate?

4. **Backpressure** — How do we handle slow consumers? Buffer limits? Blocking
   sends? Drop policy?

5. **DGRAM vs STREAM** — Should we use DGRAM for small messages (no framing
   needed) and STREAM for large/FD-carrying messages? Or keep it simple with
   STREAM-only?

6. **Cluster topology** — Peer-to-peer mesh? Hub-and-spoke? Hybrid? Each has
   different failure mode characteristics.

---

## References

- [pre.md](./pre.md) — Ruby 4.0 primitives (Ractor internals)
- [rac.md](./rac.md) — Workers and Proctors (existing patterns to build on)
- [sup.md](./sup.md) — Supervision (liveness detection patterns)
- `lib/umi/proctor.rb` — Existing Watcher Ractor + I/O thread pattern
- `tmp/ruby/ractor.c` — Ractor implementation (shareability, move, copy)
- `tmp/ruby/ractor_sync.c` — Port and message basket implementation
