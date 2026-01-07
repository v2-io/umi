# Chapter 6: Phenomenal Cosmic Powers, Itty-Bitty Living Space — Reflections for Umi

A Black Friday retail outage. Unlike the airline case (Chapter 2), this one has a happy ending—because the team had visibility and control.

## The Failure Chain

```
Marketing runs "free home delivery" campaign
  → Every order requests delivery scheduling
    → Scheduling system has 2 of 4 servers down for maintenance
      → One more server malfunctions
        → Single remaining server (capacity: 25 concurrent) gets 90 requests
          → Scheduling server at 100% CPU, hanging
            → Order management threads (450) block waiting for scheduling
              → Front-end threads (3,000) block waiting for order management
                → Site is down, losing $1M/hour
```

**Same pattern as the airline:** Integration point fails → threads block forever → system hangs.

**Different outcome:** They could see what was happening and had the ability to intervene.

## The Unbalanced Capacities Problem

| Layer | Threads | Ratio |
|-------|---------|-------|
| Front end | 3,000 | 120:1 |
| Order management | 450 | 18:1 |
| Scheduling | 25 | 1:1 |

This is the "Unbalanced Capacities" antipattern at multiple levels. The front end can generate 120x more concurrent work than scheduling can handle. Under normal load, this is fine—most requests don't need scheduling. Under Black Friday + free delivery campaign, *every* request needs scheduling.

**For Umi:** This is about understanding workload patterns. A supervision tree might handle normal load perfectly but collapse under a changed pattern. The question isn't "can we handle average load?" but "can we handle the worst load that will actually occur?"

## Missing Timeouts (Again)

> "The waiting threads were all blocked on a resource pool, one that had no timeout. If the back end stopped responding, then the threads making the calls would never return..."

Same lesson as Chapter 2. Same antipattern. Same result.

**For Umi:** This cannot be repeated enough. Every blocking operation must have a timeout. The timer port pattern is not optional. If we provide a blocking API without a timeout, someone will use it and create exactly this failure mode.

## What Saved Them: Visibility

The team had:
- Sampling scripts that showed session counts, order counts, page latency
- Thread dumps that revealed where threads were blocked
- The ability to trace the blocking chain from front end → order management → scheduling
- Pattern recognition: "We knew, with a single glance, what was normal."

> "Nothing beats the pattern-matching power of the human brain."

**For Umi:** Supervisors should expose their internal state. What children are alive? What's the restart count? What's the queue depth on each child's port? How long has each child been processing its current message?

The point isn't automated action on these metrics (though that's possible). The point is that when something is wrong, humans can look and understand.

## What Saved Them: Control

The key capability:
- Dynamically set properties on components at runtime
- Restart individual components without restarting servers
- Set `max=0` on a resource pool to disable an integration point

> "The ability to restart components, instead of entire servers, is a key concept of recovery-oriented computing."

The solution took 5 minutes to apply. A full server restart would have taken 6 hours.

**For Umi:** This is about control knobs. Can you:
- Change a worker's concurrency limit at runtime?
- Disable an integration point without restarting?
- Adjust timeouts on the fly?
- Restart a single worker without affecting siblings?

Umi should be designed so that supervisors can adjust child configuration dynamically. Not just "restart child" but "restart child with new parameters."

## Conway's Law Saves the Day

The scheduling connection pool was a separate component because the code was written by a different team:

> "I'm not sure why the code was designed with a separate connection pool for that, probably an example of Conway's law, but it saved the day."

Because it was a separate component, it could be disabled independently. If all backend connections used a single pool, they couldn't have isolated the failing integration point.

**For Umi:** This reinforces the value of bulkheads at the component level. Separate pools for separate concerns. Separate workers for separate integration points. The granularity of isolation determines the granularity of recovery.

## Recovery-Oriented Computing

The sidebar introduces the ROC project's principles:
1. Failures are inevitable, in both hardware and software
2. *A priori* prediction of all failure modes is not possible
3. Human action is a major source of system failures

Sound familiar? This is let-it-crash philosophy from another angle. You can't prevent all failures, so you optimize for recovery.

**For Umi:** This is our core philosophy. The question isn't "how do we prevent failures?" but "how do we recover quickly when they happen?"

ROC emphasizes:
- Fine-grained restart (components, not systems)
- Undo mechanisms
- Redundancy at multiple levels
- Human-aware design (make systems easy for operators to understand and control)

## The Human Element

Several human factors contributed to the problem:
- Maintenance scheduled during Black Friday weekend
- Marketing didn't inform operations about the campaign
- On-call engineer ignored "high CPU" pages (trained to ignore false positives)

And human factors contributed to the solution:
- Experienced engineers who knew what "normal" looked like
- Creative problem-solving under pressure
- Tools that gave humans leverage

**For Umi:** We can't automate away human judgment. The goal is to give humans good information and effective controls. Umi should:
- Make the unusual visible (so humans can spot it)
- Make intervention easy (so humans can act quickly)
- Log state changes (so humans can understand what happened)

## Questions for Umi

1. **How do we expose supervisor state for human inspection?** What's the equivalent of Nygard's sampling scripts?

2. **Can we adjust child parameters at runtime?** Not just restart, but restart-with-new-config?

3. **How do we disable an integration point?** If a Proctor subprocess is hanging, can we tell the worker to stop calling it without killing the worker?

4. **What's our story for unbalanced capacities?** If one layer can generate more work than the next can handle, what happens? Backpressure? Load shedding? Both?

5. **How do we prevent false-positive alerting from training humans to ignore alerts?** The scheduling team's engineer ignored real problems because he'd been conditioned to expect false alarms.
