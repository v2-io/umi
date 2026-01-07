# Chapter 2: The Exception That Grounded an Airline — Reflections for Umi

## The Anatomy of the Failure

A database failover. A `SQLException` thrown from `Statement.close()` in a finally block. The connection never gets closed. Forty calls later, the connection pool is exhausted. Every EJB thread blocks waiting for a connection that will never come. The kiosks block waiting for CF. The IVR blocks waiting for CF. An airline is grounded.

**The entire chain:**
```
Database failover
  → JDBC connections become invalid
    → Statement.close() throws SQLException
      → Connection.close() never called
        → Connection pool leak
          → Pool exhausted after 40 calls
            → All EJB threads block on getConnection()
              → All callers (kiosks, IVR) block waiting for responses
                → Airline grounded
                  → CEO loses vacation home
```

One uncaught exception. Hundreds of thousands of dollars.

## The Deceptive "Correct" Pattern

The code that caused the outage *looked* correct:

```java
try {
  conn = connectionPool.getConnection();
  stmt = conn.createStatement();
  // work
} finally {
  if (stmt != null) stmt.close();   // <-- can throw!
  if (conn != null) conn.close();   // <-- never reached
}
```

This pattern appeared in Java textbooks. It passed code review. It passed testing. And it contained a fatal flaw: `stmt.close()` can throw, preventing `conn.close()` from ever being called.

**The lesson for Umi:** Correct-looking code can hide fatal flaws. The cleanup path is where bugs lurk, because it's the path least exercised. The happy path is tested constantly; the cleanup path is tested rarely—only when something else has already gone wrong.

In Umi's context: what does `finally` look like in a Ractor world? When a supervised worker crashes, what cleanup runs? If that cleanup fails, what happens? The `graceful_stop` callback in `rac.md` is one such path. If `graceful_stop` raises an exception, does the worker still exit cleanly? Does the supervisor still know it died?

## Resource Exhaustion as Failure Propagation

The connection pool didn't fail. It did exactly what it was supposed to do: limit concurrent database connections and queue callers when all connections are in use. But when connections leak, that queuing becomes a deadlock.

**The pattern:**
1. A bounded resource (pool, queue, thread pool, port buffer)
2. A leak that slowly consumes it
3. Once exhausted, everything that needs the resource blocks
4. Blocked threads can't process *anything*, not just the leaking operation

For Umi, what are the bounded resources?
- Thread pools inside Ractors (for I/O, timers)
- Port message queues (unbounded by default, but memory is finite)
- Ractor count (OS limits, memory limits)
- File descriptors (Proctor spawns processes with pipes)
- Monitor registrations (is there a limit?)

**Resource exhaustion propagates.** When a pool is exhausted, every caller of that pool blocks. If callers have timeouts, they fail fast. If they don't (like RMI in this story), they block forever.

## "Bugs Will Happen. They Must Be Survived."

> "Ultimately, it's just fantasy to expect every single bug like this one to be driven out. Bugs will happen. They cannot be eliminated, so they must be survived instead."

This is the philosophical foundation of OTP and Umi. You cannot prevent all bugs. You can only contain them.

The question isn't "how do we prevent this bug?" but "how do we prevent bugs in one system from affecting everything else?"

The airline's architecture was *physically* redundant: dual servers, RAID arrays, off-site backups, Godzilla-proof disaster recovery. None of it helped, because the bug was in the software, and the software ran identically on every "redundant" server.

**Hardware redundancy doesn't protect against software bugs that replicate across all instances.**

For Umi, this means supervision isn't just about restarting crashed workers. It's about preventing a bug in one worker from affecting other workers. The bulkhead pattern. Isolation. Blast radius control.

If every worker in a supervision tree shares the same connection pool, a leak in one can block them all. If each worker has its own pool (or no pool, just direct connections), a leak affects only that worker.

## Monitoring That Lies

The monitoring showed CF as healthy throughout the outage. Why? Because monitoring hit the HTTP endpoint, which was idle. The EJB threads were 100% blocked, but HTTP threads were fine.

**The health check didn't check what mattered.**

For Umi, this raises a pointed question: what does "healthy" mean for a supervisor? For a worker?

- Is a worker healthy if it's alive but hasn't processed a message in an hour?
- Is a supervisor healthy if all its children are alive but blocked?
- Is the coordinator healthy if applications are "running" but not responding?

The planning documents mention health checks as an open question. This case study suggests health checks need to probe *actual work*, not just liveness. A worker should probably respond to a health ping *through the same code path* that handles real requests.

## The Two-Hour Delay

The failover happened at 12:30 a.m. The outage started at 2:30 a.m. Two hours.

Why the delay? Because the connection pool had 40 connections. It took time for 40 requests to each leak one connection. The system was degrading *before* it failed, but the degradation was invisible.

**Slow leaks are invisible until they're catastrophic.**

For Umi, this suggests the value of *trends*, not just thresholds. A supervisor that notices "restart rate is increasing" or "message processing latency is increasing" can act before total failure. But this is sophisticated—probably future work, not core Umi.

## Thread Dumps as Forensics

Nygard's debugging relied heavily on Java thread dumps. He could see exactly where every thread was blocked, trace the call stack, identify the resource they were waiting on.

For Umi, what's the equivalent? If a system is misbehaving, what can an operator inspect?

- Which Ractors are alive?
- What messages are queued on each port?
- Which Ractors are blocked on `Ractor.select`?
- What's the restart count for each supervised child?
- How long has each Ractor been in its current state?

Ruby 4.0 may provide some of this introspection. Umi could augment it with structured state that supervisors expose. The diagnostic snapshot pattern in `etc.md` is one approach, but that's for crash forensics. What about *live* forensics—inspecting a misbehaving but not crashed system?

## Blocked Without Timeout

The kiosks blocked forever waiting for CF because RMI calls had no timeout. The threads were "waiting for a response that would never come."

**Calls without timeouts are threads that can be permanently stolen.**

This is why `pre.md` emphasizes the timer port pattern. `Ractor.select` has no native timeout; you must build one. And if you forget to build one, you have a thread (or Ractor) that can block forever.

For Umi, the design question: should timeouts be *opt-in* or *opt-out*? Should every `call` have a default timeout that must be explicitly overridden to allow indefinite blocking? OTP's GenServer has a default timeout of 5 seconds for calls.

## The Question That Matters

> "How do we prevent bugs in one system from affecting everything else?"

This is Umi's reason for existing. Not "how do we prevent bugs" but "how do we contain them."

The answers this book will explore:
- Timeouts (don't wait forever for something that won't come)
- Circuit breakers (stop calling something that's failing)
- Bulkheads (isolate failure domains)
- Fail fast (don't limp along in a degraded state)
- Let it crash (die cleanly, restart fresh)

Umi is the infrastructure that makes these patterns possible in Ruby. Or rather—Umi is the infrastructure that makes these patterns *natural* in Ruby, the way OTP makes them natural in Erlang.
