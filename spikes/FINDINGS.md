# Spike Findings: Ruby 4.0 Ractors for Proctor

**Date:** 2025-12-26
**Ruby Version:** 4.0.0

## Executive Summary

All critical unknowns have been resolved. We CAN build Proctor with Ruby 4.0 Ractors.

## Key Discoveries

### 1. Death Detection: `Ractor.monitor(port)`

Ruby 4.0 added `Ractor#monitor(port)` which sends `:exited` or `:aborted` to the
specified port when the Ractor terminates. This is the liveness detection primitive
we needed.

```ruby
watcher = Ractor.new { ... }
watcher.monitor(main.default_port)

# When watcher exits normally:
Ractor.receive  # => :exited

# When watcher crashes:
Ractor.receive  # => :aborted
```

### 2. Process Spawning Works Inside Ractors

We can spawn processes directly inside a Ractor using `Open3.popen3`:

```ruby
watcher = Ractor.new do
  stdin, stdout, stderr, wait_thr = Open3.popen3("cat")
  pid = wait_thr.pid
  # Full control over the process
end
```

No need to spawn outside and pass file descriptors.

### 3. Threads Inside Ractors for Async I/O

Threads work inside Ractors and are essential for handling blocking I/O:

```ruby
Ractor.new(parent) do |parent|
  stdin, stdout, stderr, wait_thr = Open3.popen3("cat")

  # Thread reads stdout, sends to parent
  Thread.new do
    while line = stdout.gets
      parent << [:stdout, line]
    end
  end

  # Ractor main loop handles commands
  loop do
    cmd = Ractor.receive
    case cmd
    in [:stdin, data] then stdin.write(data)
    in [:shutdown] then break
    end
  end
end
```

### 4. Port Ownership Rules

- Only the **creator** of a `Ractor::Port` can call `receive` on it
- Any Ractor can `send` to any Port
- Ports are shareable (`Ractor.shareable?(port)` => true)

Pattern: Parent creates port, passes to child, child sends to it, parent receives.

### 5. IO Move Semantics

IO objects are NOT shareable but CAN be moved:

```ruby
port.send(io_object, move: true)
# After this, accessing io_object raises Ractor::MovedError
```

However, since we spawn inside the Ractor, we don't need to move IO.

### 6. Ruby 4.0 API Changes

- `Ractor#value` replaces `Ractor#take`
- `Ractor::Port` is the primary communication mechanism
- `Ractor#default_port` provides each Ractor's built-in port
- `Ractor.receive` receives from the current Ractor's default port
- `Ractor.select(port1, port2, ...)` for multiplexed waiting

## The Proctor Architecture

Based on spike findings, here's the proven architecture:

```
┌─────────────────────────────────────────────────────────────┐
│                        Parent                                │
│  - Creates watcher Ractor                                    │
│  - Calls watcher.monitor(own_port)                          │
│  - Sends commands: [:stdin, data], [:close_stdin], [:kill]  │
│  - Receives: [:stdout, line], [:process_died, pid, code]    │
│  - Also receives :exited/:aborted when watcher terminates   │
└─────────────────────────────────┬───────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────┐
│                   Watcher Ractor                             │
│                                                              │
│  Spawns process with Open3.popen3                           │
│  ├── stdout_reader Thread → parent << [:stdout, line]       │
│  ├── stderr_reader Thread → parent << [:stderr, line]       │
│  ├── death_monitor Thread → parent << [:process_died, ...]  │
│  └── Command loop: Ractor.receive → handle commands         │
│                                                              │
└─────────────────────────────────┬───────────────────────────┘
                                  │
                                  ▼
                        ┌─────────────────┐
                        │   OS Process    │
                        │   (the command) │
                        └─────────────────┘
```

## What Didn't Work

1. **Passing IO via Ractor.new args for bidirectional use** - hangs in some cases
2. **Receiving from a Port you didn't create** - raises error
3. **Sharing mutable objects without move** - objects are moved, not shared

## Implications for Proctor

1. **Simple architecture**: Watcher Ractor owns everything
2. **No FD passing needed**: Spawn inside the Ractor
3. **Death detection solved**: Use `Ractor.monitor`
4. **Async I/O solved**: Use threads inside the Ractor
5. **Clean API possible**: Parent just sends commands and receives events

## Next Steps

1. Implement `Umi::Proctor` class based on this architecture
2. Add timeout support using `Ractor.select` with timeout parameter
3. Add graceful shutdown with escalating signals
4. Add block form with automatic cleanup
