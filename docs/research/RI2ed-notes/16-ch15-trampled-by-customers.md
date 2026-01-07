# Chapter 15: Case Study: Trampled by Your Own Customers — Reflections for Umi

Another war story. Launch day: 250,000 sessions in 30 minutes, then crash. Despite three months of load testing. What went wrong?

## The Testing Gap

> "First, we tested the application the way it was meant to be used."

The load tests used polite scripts that:
- Followed links from one page to the next
- Used cookies properly
- Waited between requests
- Behaved like real users

The real world sent:
- Search engine crawlers (no cookies, new session per request)
- Shopbots and scrapers (high volume, evasive)
- Old URLs from cached search results (404s that still created sessions)
- "Random weird stuff" (unexplained behavior patterns)

**The insight:** Testing the happy path tells you nothing about hostile traffic.

**For Umi:** Load testing workers should include noise:
- Messages with missing fields
- Messages at overwhelming rates
- Messages from "callers" that never acknowledge responses
- Invalid message formats
- Rapid connect/disconnect patterns

The stress tests we did for Proctor are this philosophy in action. But we should apply it to all Umi components.

## Sessions as Resource Consumption

> "Sessions are the Achilles' heel of every application server. Each session consumes resources, mainly RAM."

With session replication enabled, each session also consumed CPU and bandwidth. Under hostile traffic, sessions accumulated faster than they expired.

**For Umi:** What are Umi's "sessions"?

| HTTP Sessions | Umi Equivalent |
|---------------|----------------|
| Session object in RAM | Worker state |
| Session replication | Checkpointing (future) |
| Session timeout | Worker idle timeout (if any) |
| Session ID in cookie | Registry name |

Workers can accumulate state. If workers are created per-request, they accumulate like sessions. If workers are long-lived, their internal state can grow.

**Key question:** What happens when Umi creates workers faster than they complete? Same failure mode as session accumulation.

## Safety Devices Missing

> "The application developers did not build in the kind of safety devices that would cut off bad situations."

When things went wrong:
- Threads piled into the danger zone
- No circuit breakers
- No load shedding
- No graceful degradation

Like a foggy freeway pileup—new requests crashed into stuck ones.

**For Umi:** This is why stability patterns matter:
- **Circuit breakers**: Stop calling failing integration points
- **Load shedding**: Reject new work when overwhelmed
- **Bounded queues**: Don't let message backlog grow unbounded
- **Timeouts**: Don't let workers block forever

The planning documents emphasize these patterns. This case study shows what happens without them.

## Noise and Chaos

> "Noise and chaos might only bleed away some amount of your capacity, but it might also bring your system down."

The "tester walks into a bar" joke:
> "Orders a beer. Orders 0 beers. Orders 99999 beers. Orders a lizard. Orders -1 beers. Orders a sfdeljknesv."

Good testers don't follow the happy path. Good load testing includes chaos.

**For Umi testing:**
- Send messages at impossible rates
- Send messages with garbage content
- Send messages to workers that don't exist
- Send messages without waiting for responses
- Start and stop workers during processing
- Kill external processes mid-communication (Proctor)

## Conway's Law Applied

> "Organizations which design systems are constrained to produce designs whose structure are copies of the communication structures of these organizations."

The system reflected the organization:
- Five hundred integration points across fifteen applications
- Each team designed for QA topology, not production
- Configuration scattered across thousands of files
- Nobody owned the "production configuration" question

**For Umi:** Conway's law applies at the code level too. If the supervision tree doesn't match the team structure, maintenance becomes difficult. If workers are organized by technical concern rather than business domain, they'll communicate awkwardly.

## Nothing More Permanent Than Temporary Fixes

> "Nothing is as permanent as a temporary fix. Most of these remained in place for multiple years."

The emergency responses:
- CDN gateway page with throttling
- Static home page
- IP blocking
- Session failover disabled
- Rolling restarts

All intended as temporary. All lasted years. One lasted a decade.

**For Umi:** Temporary workarounds become permanent architecture. If Umi's design includes "we'll fix this later" compromises, they should be very carefully chosen—they'll probably ship.

This is why `sup.md` spends so much time on restart bounding. It would be easy to say "we'll add that later." But if we ship without it, the workaround (manual intervention? reduced restart attempts?) becomes permanent.

## The CDN as Safety Layer

The CDN implemented emergency load shedding:
1. Check cookies—reject non-compliant browsers
2. Throttle percentage—reject some percentage of new sessions
3. IP blocking—reject known bad actors

This gave operators manual control during crisis.

**For Umi:** Where is the equivalent? Options:
- Supervisor-level throttling (reject some messages)
- Worker-level load shedding (worker returns "busy")
- Health check failure (worker marks itself unhealthy)
- Coordinator-level emergency stop

The CDN was external to the application—it could protect even when the application was overwhelmed. For Umi, the coordinator might play this role, but it's part of the same process.

## The 1000 Database Transaction Home Page

> "It also required more than 1,000 database transactions to build the page... The drop-down menus with nice rollover effects required traversal of eighty-odd categories."

Personalization that wasn't used. Complexity that wasn't needed. Every request paid the cost.

**For Umi:** Efficiency matters. If a worker does 1000 operations to handle one message, it can't handle many messages. The planning documents emphasize lightweight workers—fast startup, fast processing.

But this is also about measuring. Without knowing the home page cost 1000 transactions, they couldn't optimize it. Umi's transparency features (from Chapter 8) should make costs visible.

## Questions for Umi

1. **Hostile traffic testing**: How do we test Umi under noise and chaos? A "chaos monkey" for Ractors?

2. **Session/worker accumulation**: What prevents worker creation from running away? Pool limits? Coordinator throttling?

3. **Emergency controls**: What emergency stop mechanisms should Umi provide? Can an operator throttle the entire system?

4. **Visibility of cost**: How do workers report their processing cost? Messages handled? Time spent? Resources consumed?

5. **Conway's law alignment**: How should supervision tree structure align with team structure?

## The Emotional Resonance

Like Chapter 12, this chapter has emotional weight:

> "After years of work, the day of launch finally arrived."

> "The forgotten friends, and the divorces were going to fade away after we launched."

And then it crashed.

> "The worst part is that no amount of those losses was necessary."

Umi exists to prevent this. Systems that survive their own success. Systems that degrade gracefully under load. Systems that don't require emergency heroics.

The goal isn't just technical correctness. It's preventing human suffering—the suffering of developers who worked years on something that crashed, the suffering of operators who scrambled to fix it, the suffering of customers who couldn't buy what they wanted.
