# REG: Registry

Name lookup with automatic cleanup. **Essential for Ruby**, not just convenient.

**Principle**: Decouple "who I want to talk to" from "what address they're at."

---

## Why Registry is Essential (Not Optional)

In BEAM, process identifiers (PIDs) are serializable first-class values. In
Ruby 4.0, Ractor references are **opaque and non-serializable**.

```
BEAM: Registry is CONVENIENT
      PIDs work fine in state, names are just nicer

Ruby: Registry is ESSENTIAL
      Ractor refs cannot be serialized
      Names are the ONLY way to persist references to other Ractors
```

If worker state includes "reply to this Ractor" or "my children are these
Ractors," you **must** store names, not references:

```ruby
# Cannot checkpoint this:
state = { reply_to: some_ractor }  # NOT serializable

# Can checkpoint this:
state = { reply_to: :user_session_42 }  # Serializable name

# On restore:
reply_ractor = Registry.lookup(:user_session_42)
```

This also means that after a crash, the **name** survives even if the physical
Ractor is replaced by a new one—which is exactly the behavior you want.

---

## Core Operations

```ruby
module Umi
  class Registry
    # Register name → address mapping
    # Fails if name already taken
    register(name, ractor) → :ok | [:error, :already_registered]

    # Look up by name
    # Returns nil if not found (not an error—absence is normal)
    lookup(name) → ractor | nil

    # Remove registration (rare—usually auto-cleaned on death)
    unregister(name) → :ok

    # List all registrations (debugging, introspection)
    list() → [{name, ractor}]

    # Query: is this name registered?
    registered?(name) → bool
  end
end
```

---

## Auto-Unregister on Death

The critical feature: when a registered Ractor dies, its registration is
automatically removed. Without this, lookups return corpses.

**Key properties:**
- Names are unique within a scope
- Auto-unregister on death (via monitoring)
- Lookup is fast—this is on the hot path for every inter-Ractor call by name

Implementation requires the registry to monitor all registered Ractors:

```ruby
def register(name, ractor)
  return [:error, :already_registered] if @names[name]

  # Monitor the ractor—when it dies, we'll be notified
  ractor.monitor(@death_port)

  @names[name] = ractor
  @ractors[ractor] = name
  :ok
end

# In the registry's event loop:
case @death_port.receive
in [:exited, ractor, _reason]
  name = @ractors.delete(ractor)
  @names.delete(name) if name
end
```

---

## Scoping Options

| Scope | Meaning | Use Case |
|-------|---------|----------|
| Global | One namespace for entire system | Simple systems |
| Per-application | Names scoped to app | Avoid collisions |
| Hierarchical | Names scoped to subtree | `app.service.worker` style |

For Umi v1, global scope is probably sufficient. Hierarchical naming can layer
on top later.

---

## Name Formats

What can be a name?

```ruby
# Atoms (most common, fast lookup)
:database_pool
:user_session_42

# Tuples (compound keys)
[:session, user_id]
[:connection, host, port]

# Strings (if needed for dynamic names)
"worker_#{uuid}"
```

**Recommendation**: Support atoms and frozen strings initially. Compound keys
(tuples/arrays) are useful for DynamicSupervisor patterns but can wait.

---

## Registration Patterns

### Named Singleton

```ruby
# One database pool for the system
Registry.register(:database_pool, pool_ractor)

# Callers find it by name
pool = Registry.lookup(:database_pool)
pool.inbox << [:query, "SELECT ..."]
```

### Named Instance

```ruby
# One session per user
Registry.register(:"session_#{user_id}", session_ractor)

# Find specific session
session = Registry.lookup(:"session_#{user_id}")
```

### Via Supervisor

The supervisor registers the child as part of starting it:

```ruby
# In child spec
{ id: :database, name: :database_pool, start: -> { ... } }

# Supervisor does:
ractor = start_child(spec)
Registry.register(spec[:name], ractor) if spec[:name]
```

---

## Registry as Kernel Ractor

Registry is pre-supervision infrastructure. It must exist before supervisors
can find their children by name.

**Placement**: Registry is a kernel Ractor (see [ini.md](./ini.md)). Its death
halts the system—there's no point continuing if you can't find anything.

**Simplicity requirement**: Because it's kernel-level, the registry must be
extremely simple and robust. No fancy features that could crash.

---

## Thread Safety

The registry is a single Ractor with a command port. All operations are
serialized through message passing—no locks needed.

```ruby
def lookup(name)
  reply_port = Ractor::Port.new
  @command_port << [:lookup, name, reply_port]
  reply_port.receive
end
```

This is naturally thread-safe because Ractor message passing is the
synchronization mechanism.

---

## Registry + DynamicSupervisor Pattern

Dynamic processes (per-user sessions, per-room game state) need both supervision
and discovery. Registry and DynamicSupervisor work together:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  REGISTRY + DYNAMIC SUPERVISOR = Named Dynamic Processes                    │
│                                                                             │
│  1. DynamicSupervisor starts the process                                   │
│  2. Process registers itself with Registry on init                         │
│  3. Callers find process via Registry, not by holding ractor reference     │
│  4. Process death auto-unregisters from Registry                           │
│  5. If restarted, new ractor re-registers with same name                   │
│                                                                             │
│  Benefits:                                                                  │
│    - Restart gets new ractor, but same name                                │
│    - Callers don't need to track ractor references                         │
│    - Can query "all processes matching pattern"                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Example: User Sessions

```ruby
# Starting a session (in request handler)
def start_session(user_id)
  spec = {
    id: user_id,
    start: -> { UserSession.start_link(user_id) },
    restart: :transient
  }
  SessionSupervisor.start_child(spec)
end

# Inside UserSession.start_link
def self.start_link(user_id)
  Ractor.new(user_id) do |uid|
    # Register ourselves—callers find us by name
    Registry.register(:"session_#{uid}", Ractor.current)

    session = new(uid)
    session.run
  end
end

# Finding a session (anywhere in the system)
def find_session(user_id)
  Registry.lookup(:"session_#{user_id}")
end
```

### Compound Keys

For more complex lookups, use compound keys:

```ruby
# Register with compound key
Registry.register([:session, user_id], ractor)
Registry.register([:session, user_id, :device, device_id], ractor)

# Lookup
Registry.lookup([:session, user_id])
```

This enables queries like "all sessions for user X" if the registry supports
prefix matching (future enhancement).

---

## Process Groups (Future)

Registry gives you 1:1 (name → ractor). Sometimes you need 1:N (name → [ractors]):

```ruby
# All workers in a pool
Groups.members(:worker_pool) → [ractor1, ractor2, ractor3]

# Broadcast to all
Groups.broadcast(:worker_pool, message)

# Send to one (round-robin or random)
Groups.notify(:worker_pool, message)
```

This is a separate abstraction that builds on top of basic registry. See
[etc.md](./etc.md) for future enhancements.

---

## Open Questions

1. **Name collision handling**: Error? Replace? Version number?

2. **Lookup semantics**: Block until registered? Return nil immediately?

3. **Compound keys**: Support `[:session, user_id]` from the start?

4. **Introspection**: What queries beyond `list()` are needed?

---

## References

- [strategic-checkpointing.md](../strategic-checkpointing.md) - Why names matter for state
- [ini.md](./ini.md) - Registry as kernel Ractor
- [sup.md](./sup.md) - Supervisor + Registry patterns, DynamicSupervisor detail
- [rac.md](./rac.md) - Worker patterns (use registry for discovery)
- [etc.md](./etc.md) - Process groups (future)
