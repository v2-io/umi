# Ruby 4.x Ractor Direction: Maintainer Vision

*Research compiled January 2026 from Ruby source, bug tracker, and maintainer talks.*

This document captures the Ruby core team's design philosophy for Ractors, so Umi
can build aligned abstractions rather than workarounds for planned features.

---

## Core Philosophy

From Koichi Sasada (ko1) and maintainer discussions:

> "Ractors are actor-like primitives. Supervision, request-response patterns,
> lifecycle management, and timeouts are **userland concerns**, not platform
> concerns."

This parallels Erlang's approach: the language provides cheap parallel units with
isolation guarantees, and libraries provide higher-level abstractions (supervisors,
gen_servers, etc.).

**For Umi, this is validation:** We're building exactly what the Ruby team expects
someone to build. We're not working around planned features—we're filling the
abstraction layer they intentionally left open.

---

## Gap Analysis: What's Intentional vs Planned

### 1. No Native Timeout on Ractor.select

**Status:** Intentional. Not planned.

**Evidence:**
- Ruby source (ractor.rb, ractor.c) shows no TODOs or plans for timeout support
- Feature #17363 discusses timeouts for individual operations (like `Queue.pop`),
  but not for `Ractor.select`
- `Ractor.select` is designed as a primitive blocking operation

**Blessed Pattern:** Timer thread

```ruby
timer_port = Ractor::Port.new
timer = Thread.new { sleep(timeout); timer_port << :timeout rescue nil }
begin
  ready, msg = Ractor.select(inbox, timer_port)
  return nil if ready == timer_port
  msg
ensure
  timer.kill
end
```

This treats timeout as application-level control flow, not platform infrastructure—
consistent with Ruby's actor-like philosophy.

### 2. Ractor#monitor Only Sends :exited/:aborted

**Status:** Intentional by design.

**Evidence:**
- Feature #21262 (Ractor::Port proposal) shows `monitor` is a low-level primitive
- Documentation: "similar to monitor in Erlang or Elixir"
- Design rationale: "only the ractor that created the Port can receive from it"

**Blessed Pattern:** Per-registration ports

```ruby
children.each do |child|
  monitor_port = Ractor::Port.new
  child.monitor(monitor_port)
  @monitors[monitor_port] = child  # Reverse lookup
end
```

The Ruby source shows this pattern built into `Ractor.select` itself (ractor.rb
lines 311-341):

```ruby
monitors = {} # Ractor::Port => Ractor
ports = ports.map do |arg|
  case arg
  when Ractor
    port = Ractor::Port.new
    monitors[port] = arg  # Track which ractor = which port
    arg.monitor port
```

Generic signals + per-registration ports maintain isolation guarantees.

### 3. No Lifecycle Callbacks (init/terminate)

**Status:** Intentionally left to userland.

**Evidence:**
- Feature #17100 shows no provisions for hooks in core design
- Documentation emphasizes `Ractor.new` (creation) and `Ractor#value` (completion)
- Ko1's philosophy treats Ractors like Erlang processes—no built-in lifecycle hooks

**Blessed Pattern:** Implement in supervision layer

OTP separates concerns (process ≠ supervisor). Ruby prefers composition over
built-in features. Ractors throw exceptions that propagate via `Ractor#value`,
which supervision can catch.

The Ruby team intentionally kept Ractors minimal, delegating lifecycle management
to libraries like Umi.

### 4. Procs Can't Cross Ractor Boundaries

**Status:** Fundamental design constraint.

**Evidence:**
- Features #21557, #21550, #19326 document extensively
- Ko1: "a fundamental conflict" between capturing outer variables and isolation
- Issue #17543: "Ractor isolation broken by `self` in shareable proc"

**Why It Can't Change:**

Allowing procs to capture variables would break isolation. A proc capturing a
mutable variable would violate "only one ractor accesses an object" invariant.

**History:**
- Ruby 3.0-3.x: `Ractor.make_shareable()` with awkward self-handling
- Ruby 4.0: `Ractor.shareable_proc` and `Ractor.shareable_lambda` improve
  ergonomics, but still no variable capture

**Blessed Pattern:** Pass data via arguments

```ruby
# WRONG - will fail
start_fn = -> { Worker.start_link }
Ractor.new(start_fn) { |fn| fn.call }

# CORRECT - data passed as arguments
Ractor.new(worker_class, args) { |klass, a| klass.start_link(a) }

# Also correct - shareable_proc for the block itself
start_fn = Ractor.shareable_proc { Worker.start_link }
```

### 5. Request-Response Requires Manual Port Creation

**Status:** `Ractor::Port` is the designed solution. No higher-level primitive planned.

**Evidence:**
- Feature #21262 addresses request-response as a design goal
- Ko1's article "Ractor::Port - Revamping the Ractor API" explains ports are
  designed specifically for request-response scenarios
- Design explicitly supports "reply_to" port passing

**Blessed Pattern:** Create reply port, pass in message

```ruby
reply_port = Ractor::Port.new
worker << {request: data, reply_to: reply_port}
response = reply_port.receive
```

The documentation (ractor.md lines 620-663) shows a worker pool example doing
exactly this. There are no plans for a built-in `call/reply` primitive—the Port
API is the abstraction layer.

---

## What the Ruby Team IS Working On

### Primary Focus: Ractor-Local GC

Ko1's most recent work at RubyKaigi 2025 focuses on **Ractor-local garbage
collection**:

- Each Ractor can perform GC independently on non-shareable objects
- Global GC for shareable objects still requires pausing all Ractors
- Should significantly improve multi-Ractor performance

This is a **performance enhancement**, not an API change.

### Secondary Enhancements

From RubyKaigi 2024 "Ractor Enhancements" talk:

- `Ractor#interrupt_exec` for interrupting long-running operations
- `Ractor.require(feature)` for loading features in child Ractors
- Better C extension support (ongoing work)

---

## Implications for Umi

### We're On the Right Track

| Umi Component | Alignment |
|---------------|-----------|
| Timer thread pattern | Blessed approach |
| Per-child monitor ports | Matches internal Ruby patterns |
| Worker lifecycle hooks | Fills intentional userland gap |
| Supervisor restart logic | Exactly what Ruby team expects libraries to provide |
| Registry name-based lookup | Solves real gap (identity survives death) |

### Design Confidence

The Ractor primitives are stable. Ko1's focus is performance (GC), not API changes.
We can build on these foundations without fear of upstream changes invalidating
our approach.

### What We Should NOT Do

- Don't expect native timeout—embrace timer threads
- Don't expect richer monitor messages—use per-registration ports
- Don't fight proc isolation—pass data through arguments
- Don't wait for built-in supervision—that's our job

---

## Sources

### Ruby Bug Tracker
- [Feature #17100: Ractor proposal](https://bugs.ruby-lang.org/issues/17100)
- [Feature #17363: Timeouts](https://bugs.ruby-lang.org/issues/17363)
- [Feature #21262: Ractor::Port proposal](https://bugs.ruby-lang.org/issues/21262)
- [Feature #21557: shareable_proc improvements](https://bugs.ruby-lang.org/issues/21557)
- [Feature #19326: Better Proc-to-Ractor API](https://bugs.ruby-lang.org/issues/19326)
- [Issue #17543: Isolation broken by self in shareable proc](https://bugs.ruby-lang.org/issues/17543)

### Conference Talks
- [RubyKaigi 2024: Ractor Enhancements](https://rubykaigi.org/2024/presentations/ko1.html)
- [RubyKaigi 2025: Toward Ractor local GC](https://rubykaigi.org/2025/presentations/ko1.html)

### Articles
- [Ruby 4.0.0 Released](https://www.ruby-lang.org/en/news/2025/12/25/ruby-4-0-0-released/)
- [Ko1: Reading Ruby 4.0 NEWS](https://dev.to/ko1/reading-ruby-40-news-with-pros-3mln)
- [Ko1: Ractor::Port - Revamping the Ractor API](https://dev.to/ko1/ractorport-revamping-the-ractor-api-98)

### Documentation
- [Ruby Ractor Documentation](https://docs.ruby-lang.org/en/master/Ractor.html)

---

*Last updated: January 2026*
