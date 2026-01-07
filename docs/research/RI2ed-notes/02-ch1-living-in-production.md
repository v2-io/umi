# Chapter 1: Living in Production — Reflections for Umi

## The Core Insight

Nygard's central claim: **"Software delivers its value in production. Everything before production is prelude."**

This reframes what "done" means. Feature complete is not production ready. Passing tests is not surviving reality. The gap between QA and production is where systems die.

## "Design for Manufacturability" → "Design for Production"

Nygard draws an analogy to manufacturing: designs that look beautiful in CAD fail on the factory floor. Software that passes tests fails under real load, real users, real time.

For Umi, this suggests a question: **What is "design for production" for a resilience library?**

An application designed for production handles timeouts, circuit breakers, graceful degradation. But Umi is infrastructure—it's what *enables* applications to be production-ready. The meta-question becomes: what does it mean for resilience infrastructure itself to be production-ready?

Some thoughts:

1. **Umi must be more stable than the things it supervises.** If a supervisor crashes as often as its children, you've gained nothing. The "boring root principle" addresses this, but it's worth asking: is Umi's design *actually* boring enough? Every clever abstraction is a potential failure point.

2. **Umi must be observable.** If an application using Umi has a stability problem, operators need to understand whether the problem is in the application or in Umi itself. This means Umi needs to expose its internal state—what's supervised, what's restarted, what's blocked—in ways operators can inspect.

3. **Umi must degrade gracefully under its own edge cases.** What happens if a Ractor monitor never fires? What if port sends start blocking? What if the timer thread pool gets exhausted? The planning documents don't deeply address Umi's own failure modes.

## "Systems Should Not..."

Nygard lists what systems should *not* do: crash, hang, lose data, violate privacy, lose money, destroy your company, kill your customers.

This is the negative space of requirements. Functional requirements say what the system does. Non-functional requirements say what it must not do, or must always do regardless of circumstances.

For Umi, the "should not" list might be:
- Should not lose supervision (a child dies unnoticed)
- Should not cascade (one failure takes down unrelated components)
- Should not deadlock (waiting forever for something that won't come)
- Should not leak (resources, Ractors, file handles, ports)
- Should not lie (report healthy when unhealthy, or vice versa)

The planning documents address the first two well. The third is addressed via timeouts. The fourth and fifth are less explicit. **Resource cleanup and accurate health reporting deserve more attention.**

## Early Decisions Crystallize

> "The earliest decisions you make can be the hardest ones to reverse later. These early decisions about the system boundary and decomposition into subsystems get crystallized into the team structure, funding allocation, program management structure..."

Umi is in that early phase now. The decisions being made in these planning documents—the Port model, the coordinator/application/supervisor layering, the relationship between Proctor and supervision—will become load-bearing structure.

This is why the review concerns matter. A decision like "supervisors identify dead children by iterating and checking `alive?`" might seem like an implementation detail, but if it becomes the pattern everywhere, it's hard to change later. The dead Ractor identification problem isn't just a bug—it's a crystallizing design choice.

## The Pragmatic Architect

Nygard contrasts ivory-tower architects (who decree from above) with pragmatic architects (who code alongside the team and think about dynamics).

The pragmatic architect asks:
- "How can we do a deployment without rebooting the world?"
- "What metrics do we need to collect?"
- "What part of the system needs improvement the most?"

For Umi, the pragmatic questions might be:
- How does a running Umi system get upgraded without dropping supervised processes?
- What does a supervisor's internal state look like when something is going wrong?
- What's the simplest thing that could possibly work for the next layer, and is it actually simple or just familiar?

The last question is particularly important. OTP patterns are *familiar* to people who know Erlang, but are they *simple* for Ruby? The planning documents are careful about this ("the goal is not to make Ruby act like Erlang"), but the pull toward mimicry is strong. Every pattern borrowed from OTP should be interrogated: is this the simplest solution for Ruby, or just the most familiar solution from Erlang?

## "Good Enough for the Current Stresses"

> "Each component is good enough for the current stresses—and the architect knows which ones need to be replaced depending on how the stress factors change over time."

This is a profound reframe. Not "perfect and complete" but "adequate and evolvable."

Umi's planning documents aim for comprehensiveness—coordinator, applications, supervisors, workers, registry, checkpointing. But what's the minimal viable Umi? What's "good enough for current stresses"?

Right now, Proctor exists. It wraps external processes. The current stress is: how do we supervise Proctors? Maybe the answer isn't a full supervision tree—maybe it's a simple monitor loop that restarts Proctors when they die. Build that, learn from it, then decide what's next.

The danger of comprehensive planning is that it delays contact with reality. Nygard advocates "early delivery and incremental improvements" because "production is the only place to learn how the software will respond to real-world stimuli."

## Questions This Chapter Raises for Umi

1. What are Umi's own failure modes, and how does it degrade when they occur?

2. How observable is Umi's internal state to operators who need to debug production issues?

3. What's the minimal viable supervision that could be built and tested in production?

4. Which early decisions in the planning documents are at risk of crystallizing prematurely?

5. What would "five nines" mean for a resilience library? (Perhaps: five nines of the library not *causing* failures, even if applications fail.)

---

## Additional Reflections (from discussion)

### The Proctor Story: Stress Testing as Truth-Finding

During the Proctor proof-of-concept, we put it through extensive stress testing, fuzz testing, and edge case hunting. For what amounts to "open3 using Ractors," the amount of testing required to build confidence was enormous. At one point, thousands upon thousands of tests ran just to isolate a single heisenbug that had appeared only once. We only stopped when we literally could not figure out any other way to force failure modes. (See `KNOWN_ISSUES.md` for the last bugs we could manufacture.)

Then something interesting happened. An agent session was asked to build an MCP client on top of Proctor. In under 50k tokens, they had a working implementation. When asked about confidence in its stability, they expressed deep skepticism—an instinctive expectation that "in the real world" it would immediately fall apart. This intuition comes from years of experience with `system()`, `popen()`, `Open3`—where reality always finds a way to close stdin unexpectedly, get into weird states, raise the wrong error, capture the wrong thing.

The agent was invited to build stress tests and verify. They found *one* bug—in their own JSON handling—and zero Proctor bugs. A 3-line fix, and they had a provably production-quality MCP client. More robust before supervision than anything they could have imagined.

**The lesson:** When the substrate is solid, what builds on it can be solid quickly. When the substrate is fragile, everything above it is fragile regardless of effort.

### The Untractability of "Release It" Thinking in Most Languages

The patterns in this book often prove untractable when teaching them to engineers in languages other than Erlang or Elixir. They accept the concepts intellectually, but the implementation reality is so overwhelming that it looks like pie-in-the-sky indulgence rather than a reliability imperative.

The beautiful thing about OTP-style thinking is that the language and runtime make it a *natural affordance*. Failure modes that would otherwise be exceptions become different return results. Isolation is structural, not incidental. You're encouraged to think about failure modes up front—essentially the philosophy this book describes—but the language makes it feel safe and quick to work through your expected "rare" modes (instead of failure modes) and do the right thing.

### Ruby's Surprising Robustness

There's something about Ruby—not fully understood—that often results in surprisingly reliable code. In a recent project, after many thousands of lines of RBS type annotations, static analysis caught only two or three bugs. This isn't a knock on static analysis; rather, it revealed that if we wanted to break the code, we were going to have to work *hard* to break it.

It's not just syntax or VM stability, though those contribute. There's a clean mental model, abstractions that encourage domain-centric development, and expressive declarative code. Ruby lacks a certain fragility common in peer scripting languages. Whatever the cause, Umi gets to leverage it.

### Default Affordances: Long-Lived vs. Short-Lived

Ruby and most languages have a default *affordance* of being short-lived, objective-oriented programs. You *can* daemonize, restart on death, add inner loops—but even then you're forced to be careful about steady-state memory leaks and accumulating cruft.

Erlang was the first language where the default affordance was a long-lived program. That was just... the default. It took effort to figure out how to even *stop* a script or VM. If you didn't kill it properly, the heartbeat would restart it. Before `escript`, it was strange to internalize: the natural state is that you write things that run effectively forever, and it's *difficult* to use the language for one-off tasks.

This is an underlying tension Umi must navigate—a unique intersection of opportunities:

1. **Long-lived by default** — Thinking in terms of "apps that run forever" instead of "scripts we force to stay alive."

2. **Failure modes up front** — Thinking "let's do the right thing with obvious failure modes now" instead of hoping we reach the finish line on the happy path.

3. **Adversarial testing** — Thinking "can we figure out *any* way to break this and uncover a bug however subtle" instead of coding only for success.

4. **Ruby's expressiveness preserved** — Allowing Ruby's beautiful concern-hiding, isolation of responsibilities, and DSL capabilities to make coding the happy path enjoyable and the resulting code understandable. (Elixir did *not* deliver this despite its surface-level Ruby-esque syntax.)

5. **Sequential thinking through concurrency** — The irony of actor concurrency: by making processes light, inexpensive, isolated, and share-nothing, your *communication* decisions become explicit decisions just like failure-mode decisions. The actual code ends up feeling contained, deterministic, and sequential—even though it's concurrent.

This last point is subtle but crucial. The goal isn't to make concurrency feel concurrent. The goal is to make concurrency *disappear* into sequential-feeling code, with the boundaries (communication, failure) explicit and local.
