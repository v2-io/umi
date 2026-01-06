# OTP Initialization: A Deep Analysis

This document analyzes how BEAM/OTP handles system initialization, based on a
close reading of `erts/preloaded/src/init.erl`. The goal is to extract
principled patterns that can inform Umi's design, separating what's essential
from what's BEAM-specific.

---

## Table of Contents

1. [What init Does (and Doesn't Do)](#what-init-does-and-doesnt-do)
2. [The Boot Script Pattern](#the-boot-script-pattern)
3. [The Pre-Supervision Layer](#the-pre-supervision-layer)
4. [Signal Handling Architecture](#signal-handling-architecture)
5. [External Supervision (Heart)](#external-supervision-heart)
6. [Shutdown Coordination](#shutdown-coordination)
7. [Implications for Umi](#implications-for-umi)

---

## What init Does (and Doesn't Do)

The `init` process is the **first Erlang process** created when the BEAM VM
starts. It's a "preloaded" module—compiled directly into the VM binary because
nothing else exists yet to load code.

### The Entry Point

```erlang
boot(BootArgs) ->
    register(init, self()),          %% Global name: any process can find us
    process_flag(trap_exit, true),   %% We must survive child deaths
    {Start, Flags, Args} = parse_boot_args(BootArgs),
    boot(Start, Flags, Args).
```

Three critical things happen immediately:

1. **Registration**: init registers itself globally so any process can send it
   messages (`init ! {stop, Reason}`)
2. **Trap exits**: init must not die when children die—it coordinates their
   deaths
3. **Parse arguments**: Command-line arguments are parsed into structured data

### Two Distinct Phases

init has two operating modes with different behavior:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  BOOTSTRAP PHASE (boot_loop/2)                                              │
│                                                                             │
│  - Interprets boot script commands                                          │
│  - Tracks modules loaded during boot                                        │
│  - Reports progress for introspection                                       │
│  - Starts kernel processes, links to them                                   │
│  - Handles {loaded, ...}, {progress, ...}, {started, ...} messages          │
│                                                                             │
│  Transitions to steady state when boot process exits normally               │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  STEADY-STATE PHASE (loop/1)                                                │
│                                                                             │
│  - Much simpler message handling                                            │
│  - Monitors kernel processes (death = halt node)                            │
│  - Responds to queries (get_arguments, get_status)                          │
│  - Handles shutdown requests (stop, restart, reboot)                        │
│                                                                             │
│  Remains in this phase until shutdown                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

From init.erl:

```erlang
boot_loop(BootPid, State) ->
    receive
        {BootPid, loaded, NewlyLoaded} ->
            Loaded = NewlyLoaded ++ State#state.loaded,
            boot_loop(BootPid, State#state{loaded = Loaded});
        {BootPid, progress, started} ->
            notify(State#state.subscribed),
            boot_loop(BootPid, State#state{status = {InS, started}});
        {'EXIT', BootPid, normal} ->
            %% Boot complete—transition to steady state
            loop(State#state{status = {started, PS}});
        {'EXIT', BootPid, Reason} ->
            crash("Runtime terminating during boot", [Reason]);
        ...
    end.

loop(State) ->
    receive
        {'EXIT', Pid, Reason} ->
            terminate(Pid, Kernel, Reason),  %% May halt node!
            loop(State);
        {stop, Reason} ->
            stop(Reason, State);
        ...
    end.
```

**The principle**: The coordinator is simpler in steady state than during
bootstrap. Bootstrap requires tracking transient state (loaded modules,
progress) that's irrelevant once running.

### What init Delegates

init is remarkably minimal. It delegates almost everything:

| Responsibility | Delegated To | Why |
|----------------|--------------|-----|
| Module loading | `erl_prim_loader` | Separate process, can fail independently |
| Boot script interpretation | spawned `do_boot` process | Keeps init's loop simple |
| Code management | `code_server` (after boot) | Complex, can be restarted |
| File I/O | `file_server_2` | Slow, can block, can fail |
| Signal handling | `erl_signal_server` | Configurable, can have multiple handlers |
| Logging | `logger` | Complex, shouldn't block coordinator |
| Application lifecycle | `application_controller` | Significant complexity |

**The principle**: The coordinator's only verbs should be receive, send, spawn,
and monitor. Everything else is delegated to something that CAN fail and be
restarted.

### init's State is Minimal

```erlang
-record(state, {
    flags = [],           %% Command-line flags (immutable after parse)
    args = [],            %% Plain arguments (immutable)
    start = [],           %% Things to start via -s/-run (consumed during boot)
    kernel = [],          %% [{Name, Pid}] of kernel processes
    bootpid,              %% PID of boot process (only during bootstrap)
    status,               %% {internal_status, provided_status}
    script_id = [],       %% Boot script identity
    loaded = [],          %% Modules loaded during boot (cleared after)
    subscribed = []       %% Processes waiting for {init, started}
}).
```

Most fields are either immutable after parsing or temporary during bootstrap.
In steady state, init only really cares about:
- `kernel`: Who to halt for if they die
- `status`: Current system state
- `flags`: For queries like `get_argument/1`

---

## The Boot Script Pattern

### Boot Script as Data, Not Code

The boot script (`.boot` file) is a binary containing Erlang terms—pure data:

```erlang
{script,
 {"OTP  APN 181 01","OTP-27.0"},   %% Script identity
 [
   {progress, preloaded},
   {preLoaded, [erlang, erl_prim_loader, init, ...]},
   {path, ["$ROOT/lib/kernel/ebin", "$ROOT/lib/stdlib/ebin"]},
   {primLoad, [error_handler, application, ...]},
   {kernel_load_completed},
   {progress, kernel_load_completed},
   {kernelProcess, heart, {heart, start, []}},
   {kernelProcess, logger, {logger_server, start_link, []}},
   {kernelProcess, code_server, {code, start_link, []}},
   {progress, code_server},
   {apply, {application, start_boot, [kernel, permanent]}},
   {apply, {application, start_boot, [stdlib, permanent]}},
   {progress, started}
 ]}.
```

init interprets this via pattern matching:

```erlang
eval_script([{progress, Info} | T], Es) ->
    init ! {self(), progress, Info},
    eval_script(T, Es);

eval_script([{primLoad, Mods} | T], Es) when is_list(Mods) ->
    load_modules(Mods, Init),
    eval_script(T, Es);

eval_script([{kernelProcess, Server, {Mod, Fun, Args}} | T], Es) ->
    start_in_kernel(Server, Mod, Fun, Args, Init),
    eval_script(T, Es);

eval_script([{apply, {Mod, Fun, Args}} | T], Es) ->
    apply(Mod, Fun, Args),
    eval_script(T, Es);
```

**The principle**: The coordinator is an interpreter of declarative boot data.
This means:
- Boot order is introspectable (just read the script)
- Boot is deterministic (same script = same order)
- Boot can be modified without changing coordinator code
- Boot scripts can be generated, validated, transmitted

### Boot Script Commands from First Principles

| Command | Purpose | Why It's Needed |
|---------|---------|-----------------|
| `{progress, Info}` | Status reporting | Introspection, debugging, health checks |
| `{path, Paths}` | Code loading paths | Must find code before loading it |
| `{primLoad, Mods}` | Load modules | Code must exist before it runs |
| `{kernelProcess, Name, MFA}` | Start critical process | Pre-supervision infrastructure |
| `{apply, MFA}` | Call function | Start applications, run setup |
| `{kernel_load_completed}` | Phase transition | Switch from eager to lazy loading |

### What a Ruby/Umi Boot Script Might Need

Ruby doesn't need module loading (handled by `require`), but needs:

```ruby
# Conceptual boot script structure
{
  progress: :initializing,

  # Pre-supervision layer: halt on death
  kernel_ractors: [
    { name: :registry, start: -> { Umi::Registry.start_link } },
    { name: :logger,   start: -> { Umi::Logger.start_link } },
  ],

  progress: :kernel_started,

  # Applications: supervised, restart on death
  applications: [
    { name: :database,  depends_on: [],          config: {...} },
    { name: :web_server, depends_on: [:database], config: {...} },
  ],

  progress: :started
}
```

**Key differences from BEAM**:
- No module loading commands (Ruby handles this)
- Explicit dependency declarations (BEAM does this in .app files)
- Configuration inline (BEAM separates into sys.config)

---

## The Pre-Supervision Layer

### Kernel Processes vs Supervised Processes

init.erl reveals something the OTP documentation often glosses over: there are
**two kinds of critical processes** with different failure semantics.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  init                                                                       │
│                                                                             │
│  KERNEL PROCESSES (linked to init, halt on death)                           │
│  ├── erl_prim_loader   ← Code loading primitive                             │
│  ├── heart             ← External watchdog                                  │
│  ├── logger            ← Logging (must survive for error reporting)         │
│  └── code_server       ← Code management                                    │
│                                                                             │
│  APPLICATIONS (supervised, restart on death)                                │
│  └── application_controller                                                 │
│        ├── kernel_master                                                    │
│        │     └── kernel_sup (supervisor tree)                               │
│        ├── stdlib_master                                                    │
│        └── [your apps]                                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

When a kernel process dies:

```erlang
terminate(Pid, Kernel, Reason) ->
    case kernel_pid(Pid, Kernel) of
        {ok, Name} ->
            sleep(500),  %% Let error messages flush
            crash("Kernel pid terminated", [Name, Reason]);  %% HALT!
        _ ->
            false  %% Not a kernel pid, ignore
    end.

crash(String, List) ->
    halt(halt_string(String, List)).  %% Node is dead
```

No restart attempts. No escalation. Just halt.

### Why Some Things Can't Be Supervised

Supervision requires infrastructure:
- A supervisor process to do the monitoring
- A registry to find the supervisor
- Logging to report what happened
- Potentially file I/O to persist state

But what supervises the supervisor? What logs the logger's death? These
"kernel processes" exist in a layer **below** the supervision infrastructure.
They must work before supervision exists.

**The principle**: There's a bootstrap layer of processes that provide the
primitives supervision needs. These processes cannot themselves be supervised
in the normal way. Their failure semantics must be: **halt and let something
external restart**.

### The Kernel Process Contract

Kernel processes in BEAM have a special contract:

```erlang
%% A kernel pid must handle the special case message
%% {'EXIT', Parent, Reason} and terminate upon it!
shutdown_kernel_pid(Pid, BootPid, Timer, State) ->
    Pid ! {'EXIT', BootPid, shutdown},
    shutdown_loop(Pid, Timer, State, []).
```

They must:
1. Be linked to init (init traps exits, monitors them)
2. Handle `{'EXIT', init, shutdown}` for graceful shutdown
3. Be simple enough to rarely fail
4. Have no dependencies on supervised processes

### For Umi: The Pre-Supervision Layer

Umi likely needs these "kernel Ractors":

| Name | Purpose | Why Pre-Supervision |
|------|---------|---------------------|
| Registry | Name → Ractor lookup | Supervisors need to find children by name |
| Logger | Error reporting | Must log supervisor failures |
| SignalHandler | OS signal dispatch | Must work before apps exist |

These should:
- Be started before any supervision tree
- Be linked to the coordinator (death = halt)
- Be extremely simple and robust
- Have no external dependencies

---

## Signal Handling Architecture

### init Does NOT Handle Signals Directly

A common misconception: init handles SIGTERM, SIGINT, etc. It doesn't. The
architecture delegates signal handling:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   OS Signal (SIGTERM, SIGINT, SIGHUP, etc.)                                 │
│                │                                                            │
│                ▼                                                            │
│   ┌────────────────────────────────────────────────────────────────────┐    │
│   │  BEAM VM (C code in erts/emulator/)                                │    │
│   │                                                                    │    │
│   │  - Registers signal handlers at startup                           │    │
│   │  - Converts signals to messages                                   │    │
│   │  - Cannot delegate this (C-level requirement)                     │    │
│   └────────────────────────────────────────────────────────────────────┘    │
│                │                                                            │
│                │ sends message to registered handler                        │
│                ▼                                                            │
│   ┌────────────────────────────────────────────────────────────────────┐    │
│   │  erl_signal_server (gen_event, part of kernel_sup)                 │    │
│   │                                                                    │    │
│   │  - Receives signal notifications from VM                          │    │
│   │  - Dispatches to registered handlers                              │    │
│   │  - Handlers are configurable at runtime                           │    │
│   │  - Default handlers call init:stop/0 or init:reboot/0             │    │
│   └────────────────────────────────────────────────────────────────────┘    │
│                │                                                            │
│                │ handler calls init:stop() which sends message              │
│                ▼                                                            │
│   ┌────────────────────────────────────────────────────────────────────┐    │
│   │  init                                                              │    │
│   │                                                                    │    │
│   │  - Receives {stop, Reason} message                                │    │
│   │  - Coordinates shutdown                                           │    │
│   │  - Has no idea this came from a signal                           │    │
│   └────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

From `kernel.erl`, `erl_signal_server` is supervised:

```erlang
{erl_signal_server, {gen_event, start_link, [{local, erl_signal_server}]},
 permanent, 2000, worker, dynamic}
```

**The principle**: Signal handling is just message passing. The coordinator
doesn't need to know about signals—it receives `{stop, Reason}` messages and
acts on them. Where those messages come from (signals, API calls, timeouts) is
someone else's concern.

### Standard Signal Semantics

| Signal | Default Behavior | Why |
|--------|------------------|-----|
| SIGTERM | Graceful shutdown (`init:stop()`) | Standard "please stop" |
| SIGINT | Graceful shutdown (or force if repeated) | Ctrl-C handling |
| SIGHUP | Configurable (often reload config) | Traditional "hangup" |
| SIGUSR1/2 | Application-defined | Custom hooks |

### For Umi: Signal Handling Pattern

The coordinator (main Ractor) creates a signal port and sets up trap handlers
that send TO that port. Signal handlers are async interrupts—they run when
a signal arrives, deposit a message, and the coordinator's event loop picks
it up on the next iteration.

```ruby
module Umi
  class Coordinator
    def initialize
      # Coordinator creates its own signal port (only it can receive)
      @signal_port = Ractor::Port.new
      setup_signal_handlers
    end

    def setup_signal_handlers
      # These run as async interrupts, send messages to our port
      Signal.trap("TERM") { @signal_port << [:shutdown, :sigterm] rescue nil }
      Signal.trap("INT")  { @signal_port << [:shutdown, :sigint] rescue nil }
      Signal.trap("HUP")  { @signal_port << [:reload_config] rescue nil }
    end

    def run
      loop do
        # Select on signal port + any other work ports
        ready, value = Ractor.select(@signal_port, *other_ports)

        case [ready, value]
        in [@signal_port, [:shutdown, reason]]
          initiate_shutdown(reason)
          break
        in [@signal_port, [:reload_config]]
          reload_configuration
        in [port, message]
          handle_message(port, message)
        end
      end
    end
  end
end
```

**Key insight**: The coordinator IS the main Ractor. Signal handlers are just
async callbacks that deposit messages into a port—the coordinator receives them
like any other message. This keeps shutdown testable (send messages directly)
and the coordinator simple (no signal-specific code paths).

**Note**: Use `rescue nil` in signal handlers because signals can arrive during
shutdown when the port may be closed.

### Signal Handler Reentrancy and Safety

Ruby signal handlers have specific reentrancy characteristics that are important
to understand:

1. **Not truly reentrant**: Ruby doesn't allow handlers to interrupt each other
   mid-execution. Handlers run at "safe points" between bytecode instructions.

2. **BUT handlers CAN run while locks are held**: A "safe point" is NOT the same
   as "outside all synchronized blocks." If you hold a mutex and a signal arrives
   at a bytecode boundary, the handler will run while your mutex is still locked.

3. **`port <<` is signal-safe**: Tested under stress (1000 concurrent main sends
   + 1000 signal sends), no messages lost, no deadlocks. The Ractor::Port send
   operation has no internal locking that could cause issues.

4. **Signals may coalesce**: Under rapid signaling, the OS may coalesce multiple
   instances of the same signal. Don't rely on receiving exactly N signals for
   N kills. Design for "at least one" semantics.

**Best practice for signal handlers**:
```ruby
Signal.trap("TERM") { @signal_port << [:shutdown, :sigterm] rescue nil }
```

Keep handlers minimal—just send a message. The `rescue nil` handles edge cases
during shutdown. All complex logic belongs in the coordinator's event loop, not
in the handler.

See `spikes/spike_j_signal_handler_reentrancy.rb` for detailed tests.

### Coordinator Placement: Main Ractor vs Child Ractor

A key architectural decision: should the coordinator BE the main Ractor, or run
as a child Ractor with main handling only signal relay?

**Three viable patterns** (all tested in `spikes/spike_k_signal_coordinator_options.rb`):

#### Option A: Coordinator IS Main Ractor

```ruby
# Main Ractor runs coordinator directly
module Umi
  class Coordinator
    def boot
      @signal_port = Ractor::Port.new
      Signal.trap("TERM") { @signal_port << [:shutdown] rescue nil }

      # Coordinator loop runs in main
      loop do
        ready, val = Ractor.select(@signal_port, @monitor_port)
        # ...
      end
    end
  end
end
```

#### Option B: Child Coordinator, Queue Relay

```ruby
# Main relays via Thread::Queue (documented signal-safe)
signal_queue = Thread::Queue.new
Signal.trap("TERM") { signal_queue << [:shutdown] }

setup_port = Ractor::Port.new
coordinator = Ractor.new(setup_port) do |setup|
  inbox = Ractor::Port.new
  setup << inbox  # Send inbox to main
  # ... coordinator loop
end

coord_inbox = setup_port.receive
Thread.new { loop { coord_inbox << signal_queue.pop } }  # Relay
```

#### Option C: Child Coordinator, Direct Port Send

```ruby
# Signal handler sends directly to child's port
setup_port = Ractor::Port.new
coordinator = Ractor.new(setup_port) do |setup|
  inbox = Ractor::Port.new
  setup << inbox
  # ... coordinator loop on inbox
end

coord_inbox = setup_port.receive
Signal.trap("TERM") { coord_inbox << [:shutdown] rescue nil }
```

#### Comparison

| Aspect | A: Main | B: Queue Relay | C: Direct Port |
|--------|---------|----------------|----------------|
| Complexity | Lowest | Medium | Low |
| Signal safety | Trivial | Documented | Tested |
| Relay overhead | None | Thread + Queue | None |
| Coordinator isolation | None | Full | Full |
| Global var access | Yes | No | No |

**Key insight**: Option C works because `Ractor::Port#send` (`port <<`) is
signal-safe in practice (tested under stress with 1000+ signals, no losses).
However, it's not in Ruby's documented signal-safe list, while `Thread::Queue#push`
is explicitly documented as safe.

**Recommendation**: Use Option A (coordinator IS main) unless you have specific
reasons to isolate the coordinator. Option C is a clean alternative if isolation
is needed.

### Signal Semantics: What Each Signal Does

With coordinator as main Ractor, all signal traps deposit messages to the
coordinator's signal port. The coordinator decides what action to take.

#### Signal Ownership

| Signal | Owner | Action |
|--------|-------|--------|
| SIGTERM | Coordinator | Initiate graceful shutdown |
| SIGINT | Coordinator | Same as SIGTERM (configurable) |
| SIGHUP | Coordinator | Reload config, notify apps |
| SIGUSR1 | Broadcast | Apps decide (e.g., dump state) |
| SIGUSR2 | Broadcast | Apps decide (e.g., rotate logs) |
| SIGPIPE | Ignored | Standard server behavior |
| SIGKILL | N/A | Can't trap, process dies |
| SIGCHLD | N/A | Proctor handles via watcher thread |

#### Handler Setup

```ruby
def setup_signal_handlers
  # === Coordinator-handled (direct action) ===
  Signal.trap("TERM") { @signal_port << [:shutdown, :sigterm] rescue nil }
  Signal.trap("INT")  { @signal_port << [:shutdown, :sigint] rescue nil }
  Signal.trap("HUP")  { @signal_port << [:reload_config] rescue nil }

  # === Broadcast to applications ===
  Signal.trap("USR1") { @signal_port << [:signal, :usr1] rescue nil }
  Signal.trap("USR2") { @signal_port << [:signal, :usr2] rescue nil }

  # === Ignored ===
  Signal.trap("PIPE", "IGNORE")
end
```

#### Message Handling

**Bootstrap phase**: Coordinator is actively starting things, not in select loop.
Signals that arrive during bootstrap are queued in the port automatically. The
coordinator can check for pending signals between major bootstrap steps:

```ruby
def boot(config)
  setup_signal_handlers

  start_kernel_ractors
  check_for_shutdown  # Non-blocking check, abort if SIGTERM received

  start_applications
  check_for_shutdown

  steady_state_loop
end

def check_for_shutdown
  # Non-blocking receive from signal port
  loop do
    result = try_receive(@signal_port, timeout: 0)
    break if result.nil?

    case result
    in [:shutdown, reason]
      abort_boot(reason)  # Clean up partially-started system
    in [:reload_config] | [:signal, _]
      # Ignore during boot
    end
  end
end
```

**Steady-state phase**: Coordinator is in select loop, handles messages as they
arrive:

```ruby
def steady_state_loop
  loop do
    ready, value = Ractor.select(@signal_port, @monitor_port)

    case [ready, value]
    # --- Coordinator handles directly ---
    in [@signal_port, [:shutdown, reason]]
      initiate_shutdown(reason)
      break

    in [@signal_port, [:reload_config]]
      @config = reload_configuration
      broadcast_to_apps([:config_reloaded, @config])

    # --- Broadcast to applications ---
    in [@signal_port, [:signal, sig]]
      broadcast_to_apps([:signal, sig])

    # --- Kernel death = system death ---
    in [@monitor_port, [:exited, ractor, reason]]
      crash("Kernel Ractor died", ractor, reason) if kernel_ractor?(ractor)
    end
  end
end

def broadcast_to_apps(message)
  @applications.each do |app|
    app.inbox << message rescue nil  # Don't crash if app already dead
  end
end
```

#### What Applications Receive

Applications don't call `Signal.trap`. They receive messages from coordinator:

```ruby
# In application's event loop
case inbox.receive
in [:config_reloaded, new_config]
  update_config(new_config)

in [:signal, :usr1]
  dump_debug_state

in [:signal, :usr2]
  rotate_logs

in [:shutdown, timeout]
  # Coordinator is shutting down, clean up within timeout
  graceful_stop(timeout)
end
```

#### Open Design Questions

1. **Signal registration**: Should apps be able to register interest in specific
   signals rather than receiving all broadcasts? (Like BEAM's gen_event model)

2. **Signal priority**: Should shutdown signals preempt other processing, or
   wait in queue like any other message?

3. **Repeated SIGINT**: Common pattern is first SIGINT = graceful, second =
   force. Should coordinator track this?

---

## External Supervision (Heart)

### The Meta-Problem: What If the Coordinator Dies?

init coordinates everything, but what coordinates init? If init dies (or the
VM crashes, or the machine reboots), something external must restart it.

BEAM's answer is `heart`—a separate OS process that watches the Erlang node.

### How Heart Works

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   ┌──────────────────┐          heartbeat          ┌───────────────────┐   │
│   │  BEAM VM         │ ─────────────────────────── │  heart            │   │
│   │                  │          (periodic)         │  (separate OS     │   │
│   │  - Sends         │                             │   process)        │   │
│   │    heartbeats    │                             │                   │   │
│   │    via port      │                             │  - Watches for    │   │
│   │                  │                             │    heartbeats     │   │
│   │                  │                             │  - If timeout:    │   │
│   │                  │                             │    restart BEAM   │   │
│   └──────────────────┘                             └───────────────────┘   │
│                                                                             │
│   If BEAM crashes, hangs, or exits unexpectedly:                            │
│   heart notices (no heartbeat) and runs restart command                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Heart in init.erl

Heart is treated specially during shutdown:

```erlang
%% On intentional stop: shut down heart first so it doesn't restart us
do_stop(stop, State) ->
    stop_heart(State),
    halt();

%% On reboot: just halt, let heart restart us
do_stop(reboot, _) ->
    halt();

stop_heart(State) ->
    case get_heart(State#state.kernel) of
        false -> ok;
        Pid ->
            %% Tell heart to stop before we halt
            shutdown_kernel_pid(Pid, BootPid, self(), State)
    end.
```

The distinction:
- `init:stop/0` → Stop heart, then halt (stay dead)
- `init:reboot/0` → Just halt (heart restarts us)

### Modern Equivalents

Heart was designed for embedded systems where BEAM runs standalone. Modern
deployments often use:

| System | How It Works |
|--------|--------------|
| systemd | `Restart=always`, health checks via socket or dbus |
| Kubernetes | Liveness probes, automatic pod restart |
| Docker | `--restart=always`, health checks |
| Supervisor (Python) | Process monitoring and restart |

**The principle**: The coordinator cannot supervise itself. Something external
must watch it and restart on failure. This is the boundary of "let it crash"—
at the outermost layer, you need an immortal watcher.

### For Umi: External Supervision Options

1. **Heart-style**: Separate Ruby process that monitors the main process
2. **Systemd**: Let the OS handle it (simpler for most deployments)
3. **Container orchestrator**: Kubernetes, Docker Compose, etc.

The Umi coordinator should support clean shutdown semantics:
- Exit 0 for intentional stop (don't restart)
- Exit non-zero for crash (do restart)
- Respond to health checks

---

## Shutdown Coordination

### Three Ways to Stop

init.erl distinguishes three shutdown modes:

```erlang
%% restart: Re-run boot in same OS process
do_stop({restart, Mode}, #state{start=Start, flags=Flags0, args=Args}) ->
    Flags = update_flag(mode, Flags0, atom_to_binary(Mode)),
    do_restart(Start, Flags, Args);
do_stop(restart, #state{start=Start, flags=Flags, args=Args}) ->
    do_restart(Start, Flags, Args);

%% reboot: Exit VM, let something external restart
do_stop(reboot, _) ->
    halt();

%% stop: Exit VM, stay dead
do_stop(stop, State) ->
    stop_heart(State),
    halt();
do_stop({stop, Status}, State) ->
    stop_heart(State),
    halt(Status).
```

| Mode | OS Process | Erlang Runtime | When to Use |
|------|------------|----------------|-------------|
| `restart` | Stays running | Re-bootstraps | Hot config reload, mode change |
| `reboot` | Exits | Restarts (via heart/systemd) | Clean restart, upgrade |
| `stop` | Exits | Stays dead | Intentional shutdown |

### The Shutdown Sequence

When stopping, init performs careful teardown:

```erlang
stop(Reason, State) ->
    BootPid = State#state.bootpid,
    State1 = State#state{status = {stopping, Progress}},
    clear_system(should_unload(Reason), BootPid, State1),
    do_stop(Reason, State1).

clear_system(Unload, BootPid, State) ->
    Heart = get_heart(State#state.kernel),
    Logger = get_logger(State#state.kernel),

    shutdown_pids(Heart, Logger, BootPid, State),  %% 1. Graceful shutdown
    Unload andalso unload(Heart),                   %% 2. Unload code (if restarting)
    exit(Logger, kill),                             %% 3. Kill logger last
    Unload andalso do_unload([logger_server]).
```

The order is deliberate:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  SHUTDOWN SEQUENCE                                                          │
│                                                                             │
│  1. Set status to {stopping, _}                                             │
│     - Queries will see system is shutting down                              │
│                                                                             │
│  2. Notify global_name_server                                               │
│     - Prevents spurious "lost connection" messages during shutdown          │
│                                                                             │
│  3. Shutdown kernel processes (except heart, logger)                        │
│     - Send {'EXIT', init, shutdown} to each                                 │
│     - Wait for exit (with timeout)                                          │
│     - Each gets a chance to clean up                                        │
│                                                                             │
│  4. Kill all remaining processes                                            │
│     - Anything still alive gets killed                                      │
│     - Ensures nothing survives                                              │
│                                                                             │
│  5. Kill all ports                                                          │
│     - Close external connections                                            │
│                                                                             │
│  6. Unload code (if restarting)                                             │
│     - Clean slate for restart                                               │
│                                                                             │
│  7. Kill logger                                                             │
│     - Last to die (needed for error reporting)                              │
│                                                                             │
│  8. halt()                                                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Shutdown Timeout

Graceful shutdown can hang. init handles this:

```erlang
shutdown_timer(Flags) ->
    case get_flag(shutdown_time, Flags, infinity) of
        infinity -> self();
        Time ->
            Pid = spawn(fun() -> timer(T) end),
            ...
    end.

shutdown_loop(Pid, Timer, State, Exits) ->
    receive
        {'EXIT', Pid, _} ->
            ok;  %% Clean exit
        {Timer, timeout} ->
            erlang:display({init, shutdown_timeout}),
            throw(timeout);  %% Force continue
        ...
    end.
```

The `-shutdown_time` flag sets a deadline. If processes don't exit gracefully
in time, they get killed.

### For Umi: Shutdown Semantics

```ruby
module Umi
  class Coordinator
    def shutdown(reason)
      @status = :stopping

      # 1. Stop applications in reverse dependency order
      @applications.reverse.each do |app|
        shutdown_application(app, timeout: @shutdown_timeout)
      end

      # 2. Stop kernel ractors (except logger)
      @kernel_ractors.reject { |r| r.name == :logger }.each do |ractor|
        shutdown_kernel_ractor(ractor)
      end

      # 3. Force-kill anything remaining
      kill_remaining_ractors

      # 4. Stop logger last
      shutdown_kernel_ractor(@logger)

      # 5. Exit with appropriate code
      case reason
      in :stop then exit(0)
      in :crash then exit(1)
      in :reboot then exit(0)  # Let external supervisor restart
      end
    end
  end
end
```

---

## Implications for Umi

### What We Can Adopt Directly

1. **Two-phase coordinator**: Bootstrap mode (complex) → steady-state mode (simple)
2. **Boot script as data**: Declarative specification of what to start
3. **Pre-supervision layer**: Kernel Ractors that halt on death
4. **Signal → message**: Convert signals to messages, keep coordinator simple
5. **Ordered shutdown**: Reverse dependency order, timeout, force-kill
6. **External supervision**: Rely on systemd/k8s for coordinator restarts

### What Needs Ruby-Specific Adaptation

1. **No module loading**: Ruby handles `require` differently
2. **No hot code reload**: Ruby doesn't support this (restart instead)
3. **Ractor limitations**: References aren't serializable (registry is essential)
4. **Thread model**: Ruby has GVL considerations BEAM doesn't

### Open Questions for Umi

1. **Boot script format**: Ruby DSL? YAML? Pure Ruby data structures?

2. **Kernel Ractor set**: What's the minimal pre-supervision layer?
   - Registry (almost certainly)
   - Logger (probably)
   - SignalHandler (maybe separate, maybe just Signal.trap at startup)

3. **Application structure**: How do we define "application" in Ruby terms?
   - Gem with specific structure?
   - Module with specific interface?
   - Configuration file?

4. **Restart semantics**: Can we support `restart` (re-bootstrap same process)?
   - Ruby doesn't cleanly support unloading code
   - Might need to always `reboot` (exit and let external restart)

5. **Health checks**: How does external supervision know we're healthy?
   - HTTP endpoint?
   - File touch?
   - Socket response?

### A Possible Umi Boot Sequence

```ruby
# lib/umi/coordinator.rb
#
# The coordinator IS the main Ractor. It creates ports it can receive on,
# sets up signal handlers, and runs the main event loop.

module Umi
  class Coordinator
    def boot(config)
      # Phase 0: Set up signal handling (before anything else)
      @signal_port = Ractor::Port.new
      @monitor_port = Ractor::Port.new
      setup_signal_handlers

      # Phase 1: Parse configuration
      @config = parse_config(config)
      @status = :starting

      # Phase 2: Start kernel Ractors (halt on death)
      @kernel = {}
      @kernel[:registry] = start_kernel_ractor(Umi::Registry)
      @kernel[:logger] = start_kernel_ractor(Umi::Logger)
      report_progress(:kernel_started)

      # Phase 3: Start applications in dependency order
      @applications = []
      sorted_apps(@config[:applications]).each do |app_spec|
        app = start_application(app_spec)
        @applications << app
        report_progress(:"#{app.name}_started")
      end

      # Phase 4: Transition to steady state
      @status = :running
      report_progress(:started)
      steady_state_loop
    end

    private

    def setup_signal_handlers
      Signal.trap("TERM") { @signal_port << [:shutdown, :sigterm] rescue nil }
      Signal.trap("INT")  { @signal_port << [:shutdown, :sigint] rescue nil }
      Signal.trap("HUP")  { @signal_port << [:reload_config] rescue nil }
    end

    def start_kernel_ractor(mod)
      ractor = mod.start_link
      # Monitor: death notification comes to @monitor_port
      ractor.monitor(@monitor_port)
      @kernel[ractor] = mod
      ractor
    end

    def steady_state_loop
      loop do
        ready, value = Ractor.select(@signal_port, @monitor_port)

        case [ready, value]
        in [@monitor_port, :exited | :aborted]
          # A kernel Ractor died—find which one and halt
          dead = @kernel.keys.find { |r| !r.alive? }
          crash("Kernel Ractor terminated: #{@kernel[dead]}", value)
        in [@signal_port, [:shutdown, reason]]
          shutdown(reason)
          break
        in [@signal_port, [:reload_config]]
          reload_configuration
        end
      end
    end
  end
end
```

---

## Ruby Box: Namespace Isolation for the Coordinator

Ruby 4.0 introduces an experimental feature called **Ruby Box** (`RUBY_BOX=1`) that
provides namespace isolation within a single process. This is orthogonal to Ractor's
memory isolation and offers an interesting parallel to BEAM's root box concept.

### What Ruby Box Provides

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  RUBY BOX HIERARCHY                                                         │
│                                                                             │
│  Root Box (Ruby bootstrap)                                                  │
│    │                                                                        │
│    ├── Main Box (user's main program, copied from root)                    │
│    │                                                                        │
│    ├── User Box 1 (Ruby::Box.new, copied from root)                        │
│    │     └── Isolated: monkey patches, globals, constants                  │
│    │                                                                        │
│    └── User Box 2 (Ruby::Box.new, copied from root)                        │
│          └── Isolated: monkey patches, globals, constants                  │
│                                                                             │
│  Each box sees the same built-in classes (String, Array, etc.)             │
│  but monkey patches in one box don't affect others.                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

Key capabilities:
- **Monkey patch isolation**: `String#blank?` defined in one box doesn't exist in others
- **Global variable isolation**: `$VERBOSE = nil` in one box doesn't affect others
- **Constant isolation**: `VERSION = "1.0"` in one box doesn't conflict with others
- **Copy-on-write**: Boxes are efficiently copied from root

### Box + Ractor: Complementary Isolation

Ractors and Boxes provide orthogonal isolation:

| Concern | Ractor | Box |
|---------|--------|-----|
| Memory isolation | Yes (share-nothing) | No |
| Parallel execution | Yes | No |
| Namespace isolation | No | Yes |
| Monkey-patch containment | No | Yes |
| Global variable isolation | Partial (main only) | Yes |

**Together they provide defense in depth**: Applications can't corrupt each other's
memory (Ractor) OR class definitions (Box).

### Spike Results: Box + Ractor Work Together

Testing confirmed (see `spikes/spike_f_box_ractor.rb`):

1. **Both mechanisms function together** without conflicts
2. **Ractor inherits creator's Box context** - `Ruby::Box.current` returns same box inside Ractor
3. **For true isolation, create Box INSIDE Ractor**:
   ```ruby
   app_ractor = Ractor.new(coordinator_port) do |coord|
     app_box = Ruby::Box.new        # Isolated namespace
     app_box.require('my_app')      # App's patches contained here

     supervisor = app_box::MyApp::Supervisor.new
     supervisor.run(coord)
   end
   ```
4. **Coordinator protection works** - App's monkey patches to `Ractor::Port` don't affect coordinator
5. **Box is shareable** - Can pass Box references across Ractor boundaries
6. **Classes/Modules from Box are shareable** - Can pass references to Box-defined classes

### The Coordinator Protection Pattern

This pattern protects the coordinator from application monkey patches:

```ruby
# Coordinator runs in main Ractor, main Box
# Applications each get their own Box inside their own Ractor

module Umi
  class Coordinator
    def start_application(app_spec)
      Ractor.new(app_spec, @inbox) do |spec, coord_port|
        # Create isolated box for this application
        app_box = Ruby::Box.new
        app_box.require(spec[:entry_point])

        # App's monkey patches stay in app_box
        # Even if app does: class Ractor::Port; def send(*) = nil; end
        # ...coordinator's Ractor::Port is unaffected

        supervisor = app_box.const_get(spec[:supervisor]).new
        supervisor.start(coord_port)
      end
    end
  end
end
```

This mirrors BEAM's architecture where:
- **Root box** ≈ **init + kernel**: Protected bootstrap layer
- **User boxes** ≈ **applications**: Isolated, can crash without affecting root

### Caveats and Limitations

Ruby Box is experimental (Ruby 4.0):

- Requires `RUBY_BOX=1` environment variable at startup
- Some gems may not work (e.g., `active_support/core_ext`)
- Performance penalty for `rb_funcall()` with Box enabled
- Native extensions may have issues

**Ractor limitations still apply** when using Box + Ractor:
- No global variables in non-main Ractors
- No class/module instance variables in non-main Ractors
- Procs can't cross Ractor boundaries (use `Ractor.shareable_proc`)

### Recommendation for Umi

Consider Ruby Box as a **defense-in-depth enhancement** rather than a core requirement:

1. **Without Box**: Ractors provide memory isolation. Applications can still
   monkey-patch shared classes, but each runs in its own Ractor so effects are
   limited.

2. **With Box**: Full isolation. Applications can't affect coordinator's
   primitives even through monkey patches. This is the "belt and suspenders"
   approach.

For production systems where application code is untrusted or poorly-behaved,
Box + Ractor provides the strongest isolation Ruby 4.0 can offer.

---

## References

- `erts/preloaded/src/init.erl` - The init process source (tmp/otp/)
- `lib/kernel/src/kernel.erl` - Kernel supervisor tree (tmp/otp/)
- [Ruby Ractor Documentation](./ruby-ractor.md) - Ruby 4.0 Ractor API
- [Ruby Box Documentation](./ruby-box.md) - Ruby 4.0 Box feature
- [OTP Principles: Language-Agnostic Analysis](./otp-principles-abstract.md)
- [BEAM/OTP Process Architecture](./beam-otp-analysis.md)
- `spikes/spike_f_box_ractor.rb` - Box + Ractor interaction experiments
