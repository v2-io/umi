# Umi Glossary

Terminology for resilience engineering, drawn primarily from Michael Nygard's
*Release It! Second Edition* and adapted for Umi's domain language. Many terms
originate in mechanical engineering, naval architecture, and fault-tolerance
research.

Credit is given where terms originate from specific sources.

---

## Core Concepts

### Transaction
An abstract unit of work processed by the system. Not a database transaction—a
single transaction may encompass many database operations. "Customer places
order" is a transaction spanning multiple pages and external integrations.
Transactions are the reason the system exists.
— *Nygard, Ch. 3*

### System
The complete, interdependent set of hardware, applications, and services
required to process transactions for users. May be a single application or a
sprawling multi-tier network.
— *Nygard, Ch. 3*

### Mixed Workload
A combination of different transaction types processed by the same system.
Most production systems handle mixed workloads.
— *Nygard, Ch. 3*

### Stability
The ability of a system to keep processing transactions even when transient
impulses, persistent stresses, or component failures disrupt normal processing.
Not just "servers stay up" but "users can still get work done."
— *Nygard, Ch. 3*

### Longevity
The ability of a system to keep processing transactions for a long time. "Long"
is relative—if you deploy weekly, two-year uptime doesn't matter; if you deploy
a remote sensor, it should run for years without intervention.
— *Nygard, Ch. 3*

---

## Forces and Responses

### Impulse
A rapid shock to the system. Flash mobs, celebrity tweets, midnight batch jobs
dumping millions of messages. Impulses fracture systems in the blink of an eye.
Borrowed from mechanical engineering.
— *Nygard, Ch. 3*

### Stress
A force applied to the system over an extended period. Slow dependencies,
overloaded databases, gradual resource exhaustion. Stress produces strain.
Borrowed from mechanical engineering.
— *Nygard, Ch. 3*

### Strain
The change in shape (behavior) caused by stress. When a credit card processor
slows down, the strain might manifest as higher RAM usage on web servers or
excess I/O on database servers—distant, seemingly unrelated effects.
Borrowed from mechanical engineering.
— *Nygard, Ch. 3*

---

## Failure Terminology

### Fault
A condition that creates an incorrect internal state in software. May be a
latent bug waiting to trigger, or an unchecked condition at a boundary. The
crack waiting to propagate. Faults become errors.
— *Nygard, Ch. 3*

### Error
Visibly incorrect behavior. When your system buys ten billion dollars of
Pokemon futures, that's an error. Errors are faults made manifest. Errors
provoke failures.
— *Nygard, Ch. 3*

### Failure
An unresponsive system. When users can't get work done, the system has failed.
Failure is in the eye of the beholder—the computer may be powered on but not
responding to requests.
— *Nygard, Ch. 3*

### Chain of Failure
The sequence of events from initial fault through propagation to system
failure. Each link in the chain increases the probability of subsequent links.
Events are not independent—a slow database makes application OOM *more* likely.
— *Nygard, Ch. 3*

### Failure Mode
The combination of: the original trigger, the way the crack spreads through
the system, and the resulting damage. Every system has multiple failure modes.
Denying their inevitability robs you of power to control them.
— *Nygard, Ch. 3*

---

## Crack Dynamics

### Crack
An initial point of failure in a system. A fault that has begun to manifest.
Under stress, cracks propagate—sometimes faster than the speed of sound in
the case of metal fatigue, sometimes instantly in software.
— *James R. Chiles, "Inviting Disaster" via Nygard, Ch. 3*

### Crack Propagation
The spread of a fault from its origin point through the rest of the system.
Tight coupling accelerates propagation. Loose coupling slows or stops it.
— *Chiles via Nygard, Ch. 3*

### Crackstopper
A design element that prevents cracks from propagating. The software equivalent
of crumple zones in automobiles. Timeouts, circuit breakers, bulkheads,
supervisor boundaries—all are crackstoppers.
— *Chiles via Nygard, Ch. 3*

### Crumple Zone
An area designed to protect critical components by failing first. Auto engineers
design crumple zones to absorb impact and protect passengers. Software engineers
design safe failure modes that contain damage.
— *Nygard, Ch. 3*

### Crack Amplifier
The opposite of a crackstopper—a design element that accelerates or widens
crack propagation. Tight coupling, missing timeouts, shared resource pools.
(Term derived from Nygard's discussion, not explicitly named in text.)

---

## Coupling

### Tight Coupling
Architecture where components are directly, synchronously dependent. Changes
in one component immediately affect others. Tight coupling accelerates cracks—
a problem in one layer instantly becomes a problem in callers.
— *Nygard, Ch. 3*

### Loose Coupling
Architecture where components are indirectly or asynchronously connected.
Message queues, eventual consistency, timeouts. Loose coupling acts as a shock
absorber, diminishing rather than amplifying failures.
— *Nygard, Ch. 3*

---

## Design Philosophy

### Cynical Software
Software that expects bad things to happen and is never surprised when they do.
Cynical software doesn't trust itself (internal barriers), doesn't trust other
systems (external barriers), and refuses to get "too intimate" with dependencies.
The opposite of optimistic software that assumes success.
— *Nygard, Ch. 3*

### Design for Production
The software analog of "design for manufacturability." Designing systems not
just to pass QA but to operate at low cost and high quality over their entire
production lifetime. Considers operational concerns from the start.
— *Nygard, Ch. 1*

### Feature Complete vs. Production Ready
Feature complete means all specified functionality exists. Production ready
means the system can survive contact with the real world—real users, real
failures, real time. They are not the same.
— *Nygard, Ch. 1*

### Pragmatic Architect
An architect who codes alongside the team, thinks about dynamics (deployment,
metrics, improvement), and builds systems that are "good enough for current
stresses" while knowing which parts need replacement as stresses change.
Contrast with ivory-tower architect who decrees from above.
— *Nygard, Ch. 1*

### Let It Crash
The philosophy that instead of trying to catch and recover from every possible
fault, processes should be allowed to crash and restart from a known good state.
Supervision makes this safe. Originated in Erlang/OTP.
— *Nygard, Ch. 3 (acknowledging the debate)*

---

## Testing

### Longevity Testing
Running a system under continuous load for extended periods (days, weeks) to
reveal bugs that only appear over time: memory leaks, resource exhaustion, data
growth. Development and QA environments rarely run long enough to catch these.
"If all else fails, production becomes your longevity testing environment."
— *Nygard, Ch. 3*

### Longevity Bug
A defect that only manifests after extended operation—memory leaks, data growth,
resource accumulation. Invisible in short-lived development sessions. Often
catastrophic when they finally appear in production.
— *Nygard, Ch. 3*

---

## Forensics

### Postmortem
Investigation conducted after an incident to determine root cause and prevent
recurrence. Like a murder mystery where the body disappears—servers are back up,
the failure state no longer exists, only traces remain in logs and memory.
— *Nygard, Ch. 2*

### Thread Dump
A snapshot of all threads in a running process, showing their state and call
stack. Invaluable for diagnosing hangs and deadlocks. In Java, triggered by
SIGQUIT; in Ruby, similar introspection possible via Thread.list and backtrace.
— *Nygard, Ch. 2*

### Resource Pool Exhaustion
When a bounded resource (connection pool, thread pool, file handles) is fully
consumed, usually due to leaks or blocking. All subsequent requests for the
resource block or fail. A common crack propagation mechanism.
— *Nygard, Ch. 2*

---

## Operational Concepts

### Restore Service First
The principle that during an incident, restoring service takes precedence over
investigation. Collect data for postmortem if it doesn't prolong the outage,
but get users working again first.
— *Nygard, Ch. 2*

### Reboot the World
The brute-force recovery approach of restarting every server, layer by layer.
Almost always effective, but slow. Better to identify and target the specific
culprit when possible.
— *Nygard, Ch. 2*

### Post Hoc, Ergo Propter Hoc
"You touched it last." The operations heuristic that recent changes are the
most likely cause of recent failures. Not always correct, but a good starting
point for investigation.
— *Nygard, Ch. 2*

---

## Maritime Origins (Umi Context)

The following terms predate software but inform Umi's design philosophy.
Ships were among the first complex systems engineered to survive catastrophic
failure in hostile environments far from help.

### Bulkhead
A partition that divides a ship's hull into watertight compartments. If one
compartment floods, the bulkheads prevent water from spreading to the rest
of the ship. In software: isolation boundaries that prevent failures from
cascading.
— *Naval architecture, adopted by Nygard*

### Watertight Compartment
A section of a ship that can be sealed off from adjacent sections. Damage to
one compartment doesn't sink the ship. In software: isolated execution contexts
(Ractors, processes, containers) that can fail independently.
— *Naval architecture*

---

## Antipatterns (Chapter 4)

Structural or behavioral patterns that tend to create or amplify failures.

### Integration Point
Any point where your system connects to another system: sockets, HTTP calls,
database connections, message queues, file systems, external processes. The
number-one killer of systems. Every integration point will eventually fail in
some way. Failures range from fast (connection refused) to slow (blocked
forever waiting for a response).
— *Nygard, Ch. 4*

### Chain Reaction
A failure mode in horizontally scaled systems where the death of one server
increases load on survivors, making them more likely to die. As each server
fails, the remaining servers become progressively more overloaded. Often caused
by memory leaks or load-related race conditions.
— *Nygard, Ch. 4*

### Cascading Failure
When a failure in one layer triggers failures in calling layers. A crack that
jumps the gap between systems. Database failure → application blocks → users
can't work. Requires a transmission mechanism (usually blocked threads or
aggressive retries).
— *Nygard, Ch. 4*

### Blocked Threads
The proximate cause of most application failures. A running process with every
thread waiting for something that will never come. Not crashed, but hung. From
the user's perspective, there's no difference. In Ractor terms: Ractors blocked
in `select` or `receive` with no timeout.
— *Nygard, Ch. 4*

### Self-Denial Attack
When a system or its extended organization (including humans) conspires against
itself. Classic example: marketing sends an email with a deep link that
bypasses CDN caching, causing traffic spike that takes down the origin servers.
Also: shared resources creating contention, rogue servers damaging peers.
— *Nygard, Ch. 4*

### Scaling Effects
When patterns that work at small scale break at large scale. Point-to-point
communication scales as O(n²). Shared resources become bottlenecks. Dev/QA
environments (1:1 ratios) don't reveal problems that appear in production
(10:1 ratios).
— *Nygard, Ch. 4*

### Unbalanced Capacities
When front-end systems can overwhelm back-end systems because their capacities
don't match. 3,000 front-end threads calling 75 back-end threads is "not in
the ballpark." Front end always has the ability to flood the back end.
— *Nygard, Ch. 4*

### Dogpile
A synchronized pulse of demand. Named after American football (ball carrier
crushed at base of pile). Occurs when: all servers boot at once, all cron jobs
fire at midnight, all caches expire simultaneously. Transient load much higher
than steady-state. Mitigated by jitter and randomized intervals.
— *Nygard, Ch. 4*

### Force Multiplier
Automation that allows small actions to have large effects. Like a lever.
Dangerous when automation's "belief" about system state differs from reality.
Can cause catastrophic changes at machine speed. Autoscalers, service discovery,
platform management all qualify.
— *Nygard, Ch. 4*

### Slow Response
Worse than no response. A slow response ties up resources in both caller and
callee. Fast failure allows the caller to proceed. Slow responses propagate
upward as gradual cascading failures. Often caused by memory leaks, garbage
collection, or resource contention.
— *Nygard, Ch. 4*

### Unbounded Result Set
When a query or API call returns far more data than expected, exhausting memory
or CPU. The application trusts the data source to return reasonable amounts.
A table that "should never have more than 1,000 rows" suddenly has ten million.
Defense: always limit query results, paginate responses.
— *Nygard, Ch. 4*

---

## Network and Protocol Concepts

### Three-Way Handshake
The TCP connection establishment protocol: SYN → SYN/ACK → ACK. Creates the
abstraction of a "connection" from discrete packets. Understanding this helps
debug network-level failures.
— *Nygard, Ch. 4*

### Listen Queue
The OS-level queue for pending TCP connections (SYN received, SYN/ACK not yet
sent). When full, new connection attempts are refused. A thread blocked in the
listen queue can wait for *minutes* until the connection times out.
— *Nygard, Ch. 4*

### Bogon
A wandering packet that arrives late, out of sequence, after the connection is
closed. TCP's TIME_WAIT state prevents bogons from being accepted as legitimate
data for a reused socket.
— *Nygard, Ch. 4*

### TIME_WAIT
TCP state after a socket is closed, before it can be reused. Defense against
bogons. Can be tuned down in controlled environments to reclaim ports faster.
— *Nygard, Ch. 4*

### Firewall Connection Timeout
Firewalls maintain tables of active connections. Idle connections are dropped
after a timeout (often one hour). Neither endpoint is notified. Next attempt
to use the "connection" blocks for minutes as TCP retries before failing.
The 5 A.M. problem.
— *Nygard, Ch. 4*

### Dead Connection Detection
Database feature (e.g., Oracle) that sends periodic ping packets to clients.
Keeps firewall connection table entries alive. Also detects crashed clients.
— *Nygard, Ch. 4*

---

## Architectural Patterns (References from Chapter 4)

These patterns are introduced by name in Chapter 4 but detailed in Chapter 5.

### Horizontal Scaling
Adding capacity by adding more servers. Farms, clusters. The dominant
architectural style. Alternative: vertical scaling (bigger servers).
— *Nygard, Ch. 4*

### Shared-Nothing Architecture
Architecture where each server operates independently, without coordination or
calls to centralized services. Capacity scales linearly. The ideal for
horizontal scaling, though rarely fully achieved.
— *Nygard, Ch. 4*

### Fan-In
The number of callers to a service. High fan-in services (many callers) spread
their problems widely and deserve extra scrutiny.
— *Nygard, Ch. 4*

### Hysteresis
Deliberately asymmetric response to changes. Start machines quickly, shut them
down slowly. Prevents oscillation. A form of Governor pattern.
— *Nygard, Ch. 4*

### Jitter
Random variation added to timing intervals to prevent synchronization.
Disperses dogpiles. Added to retry intervals, timer intervals, cache TTLs.
— *Nygard, Ch. 4*

---

## User and Traffic Concepts

### Capacity
The maximum throughput a system can sustain under a given workload while
maintaining acceptable performance. When demand exceeds capacity, transactions
take too long.
— *Nygard, Ch. 4*

### Ephemeral Port
The OS-assigned port number for the client side of a TCP connection. Limited
range (typically 16K-64K ports). Can be exhausted under heavy load.
— *Nygard, Ch. 4*

### Session
An abstraction that makes HTTP applications feel stateful. Creates memory
pressure. Sessions are the Achilles' heel of web applications—each request
without a session cookie creates a new session.
— *Nygard, Ch. 4*

### Weak Reference
A reference that doesn't prevent garbage collection. When memory is low, the
garbage collector can reclaim weakly-referenced objects. Useful for caches
that should yield memory under pressure.
— *Nygard, Ch. 4*

### Screen Scraper
Automated system that extracts data from websites by requesting pages. Rapid-
fire scrapers that don't honor session cookies create massive load and memory
pressure through session creation.
— *Nygard, Ch. 4*

### Script Kiddie
Non-expert attacker using pre-written tools. Dangerous through sheer numbers
rather than sophistication. Your systems are probably being probed by them
right now.
— *Nygard, Ch. 4*

### DDoS (Distributed Denial of Service)
Attack where many computers, often a botnet, generate load on a target. Vectors
through applications (creating sessions, expensive queries) rather than just
saturating bandwidth.
— *Nygard, Ch. 4*

---

## Stability Patterns (Chapter 5)

Patterns that counter the antipatterns and create resilient systems.

### Timeout
A mechanism to stop waiting for a response that might never come. "Hope is not
a design method." Every blocking operation should have a timeout. Timeouts
provide fault isolation—a problem in another system doesn't have to become
your problem. Complements Circuit Breaker and Fail Fast.
— *Nygard, Ch. 5*

### Circuit Breaker
A component that wraps dangerous operations and can circumvent calls when the
system is unhealthy. States: Closed (normal operation), Open (failing fast),
Half-Open (testing if recovery occurred). Tracks failures; trips when threshold
exceeded; resets after timeout. Like electrical circuit breakers: fail first
to prevent bigger damage.
— *Nygard, Ch. 5*

### Bulkhead (Pattern)
Partitioning capacity to preserve partial functionality when failures occur.
Named after ship bulkheads that contain flooding. Implementations: separate
thread pools, dedicated server clusters, physical redundancy. Trade efficiency
for resilience. The question: "If this dies, what else should keep working?"
— *Nygard, Ch. 5*

### Steady State
A system that can run without human intervention for at least one release
cycle. Every mechanism that accumulates resources (data, logs, cache) must
have a corresponding mechanism to recycle them. "Fiddling" (human intervention)
introduces ohnoseconds. Avoid it through automated maintenance.
— *Nygard, Ch. 5*

### Fail Fast
If the system can determine in advance that an operation will fail, fail
immediately. Don't waste resources on doomed work. Check prerequisites before
starting (*mise en place*). Distinguish system failures (integration point
down) from application failures (bad input)—report them differently.
— *Nygard, Ch. 5*

### Let It Crash
The philosophy that instead of trying to recover from every error, components
should crash and restart from a known good state. Requires: limited granularity
(crash component, not system), fast replacement, supervision, and automatic
reintegration. The cleanest state is right after startup. Originated in
Erlang/OTP.
— *Nygard, Ch. 5*

### Handshaking (Pattern)
Signaling between systems that regulates communication. Allows a server to
protect itself by throttling workload. The server tells clients when it's not
ready to receive. TCP does this with flow control; application protocols
rarely do. Health checks are a crude form of handshaking.
— *Nygard, Ch. 5*

### Test Harness
A server that emulates the remote end of an integration point for testing.
Unlike mock objects, test harnesses can produce out-of-spec failures: network
errors, protocol violations, slow responses, garbage data. "A good test
harness should be devious. It should leave scars on the system under test."
— *Nygard, Ch. 5*

### Decoupling Middleware
Middleware that decouples systems in space and time. Synchronous request/reply
(RPC, HTTP) couples tightly—caller blocks until callee responds. Message
queues decouple—sender doesn't wait. Synchronous calls are "vicious
amplifiers" that facilitate cascading failures.
— *Nygard, Ch. 5*

### Shed Load
When demand exceeds capacity, refuse new work rather than slowing down until
everything fails. Model TCP's listen queue: when full, reject new connections.
"You can't out-scale the world." Use at system edges; within boundaries,
prefer back pressure.
— *Nygard, Ch. 5*

### Back Pressure
Flow control that slows producers when consumers can't keep up. When a queue
is full: drop the item, drop an older item, refuse the item, or block the
producer. Blocking propagates pressure upstream. Works best with finite
queues and asynchronous calls. Within system boundaries, prefer this over
load shedding.
— *Nygard, Ch. 5*

### Governor
A mechanism that limits the rate of dangerous actions, giving humans time to
intervene. Named after steam engine governors that prevent unsafe RPMs.
Asymmetric: fast in safe direction, slow in unsafe direction. Stateful and
time-aware. Example: limit percentage of instances that can be shut down
per time period.
— *Nygard, Ch. 5*

---

## Related Algorithms and Concepts

### Leaky Bucket Algorithm
A simple algorithm for tracking rate of events. Increment a counter on each
event; decrement periodically in the background. If counter exceeds threshold,
the rate is too high. Used for circuit breakers, restart bounding, and
governors.
— *Pattern Languages of Program Design 2, via Nygard*

### Little's Law
L = λW. The average number of items in a queue (L) equals the average arrival
rate (λ) times the average wait time (W). Implication: if queue length grows
toward infinity, response time also heads toward infinity. Queues must be
finite for response times to be finite.
— *Operations research, via Nygard*

### Mise en Place
French culinary term: "everything in its place." Gathering all ingredients
before starting to cook. In software: checking that all required resources
(connections, circuit breakers, credentials) are available before processing
a request. Foundation of Fail Fast.
— *Culinary arts, via Nygard*

### Reintegration
After a crashed component restarts, it must rejoin the system to accept work.
Automatic reintegration is essential for Let It Crash. Mechanisms: circuit
breakers auto-retry, load balancers detect health, actors rejoin pools.
— *Nygard, Ch. 5*

### Supervision Tree
Hierarchical structure of supervisors managing workers (and other supervisors).
When a worker crashes, its supervisor decides: restart it, restart siblings,
or crash itself (escalating to its supervisor). Design of the supervision
tree is integral to system design.
— *Erlang/OTP, via Nygard*

---

## Operational Concepts (Chapter 6)

### Recovery-Oriented Computing (ROC)
A research approach (Berkeley/Stanford) based on three principles: failures
are inevitable, *a priori* prediction of all failure modes is impossible, and
human action is a major source of failures. Instead of trying to prevent
failures, optimize for recovery. Emphasizes fine-grained restart, undo,
redundancy, and human-aware design.
— *ROC Project via Nygard, Ch. 6*

### Dynamic Reconfiguration
The ability to change component parameters at runtime without restarting
servers. In the retail case study, setting a resource pool's `max=0` disabled
an integration point in minutes; a full restart would have taken hours. Key
capability for recovery-oriented computing.
— *Nygard, Ch. 6*

### Lagging Indicator
A metric that can only be measured after an event completes. Response time
is a lagging indicator: you can only measure completed requests. If requests
are hanging, you don't see their response time until they finish (or time
out). Worst-case response time is invisible until the worst cases complete.
— *Nygard, Ch. 6*

### Conway's Law
"Organizations which design systems...are constrained to produce designs
which are copies of the communication structures of these organizations."
In the retail case, different teams wrote different connection pools—an
accident that enabled fine-grained isolation and recovery. Sometimes
organizational structure creates useful bulkheads.
— *Melvin Conway, 1967, via Nygard*

---

## Infrastructure Concepts (Chapter 7)

### Design for Production
Thinking about production issues as first-class concerns from the start.
Includes: production network topology, logging and monitoring, runtime
control, security, and treating operators as users. The opposite of
"throw it over the wall to ops."
— *Nygard, Ch. 7*

### Multihoming
A server with multiple network interface controllers (NICs), each connected
to a different network. Common in data centers for separating production
traffic, backup traffic, and administrative access. Applications must be
explicitly configured for which interfaces to bind to.
— *Nygard, Ch. 7*

### Ephemeral Identity
The property of machines (VMs, containers) where identity is short-lived
and not guaranteed to persist. IP addresses change on restart, machine IDs
disappear, hostnames are temporary. Applications must not assume stable
identity. Configuration must be externalized.
— *Nygard, Ch. 7*

### Volunteer Pattern
Design principle where workers join pools and pull work, rather than having
a controller assign work to specific machines. New VMs register with load
balancers; workers compete for queue messages. Essential for elastic scaling
and ephemeral identity.
— *Nygard, Ch. 7*

### Oversubscription
When the total resources allocated to VMs exceed the physical host's actual
capacity. A host with 16 cores running VMs that total 32 allocated cores is
200% subscribed. Results in contention and unpredictable performance when
all VMs are active simultaneously.
— *Nygard, Ch. 7*

### The 12-Factor App
A methodology for building cloud-native, scalable, deployable applications.
Twelve factors covering: codebase, dependencies, config, backing services,
build/release/run, processes, port binding, concurrency, disposability,
dev/prod parity, logs, and admin processes. Key factors for Umi: config
in environment, stateless processes, disposability (fast startup, graceful
shutdown), logs as event streams.
— *Heroku engineers, via Nygard*

### Disposability
The ninth factor of 12-factor apps. "Maximize robustness with fast startup
and graceful shutdown." Processes should start quickly (seconds, not minutes),
shut down gracefully on SIGTERM, and be robust against sudden death. Essential
for elastic scaling and recovery.
— *12-factor app, via Nygard*

### Control Plane
Software that manages the ensemble of instances, containers, networks, and
configurations. Schedules work, allocates resources, manages networking.
Examples: Kubernetes, Mesos, Docker Swarm. In Umi context: supervisors and
coordinators form an internal control plane for Ractors.
— *Nygard, Ch. 7*

### Host Operating System vs Guest Operating System
In virtualization: the host OS runs on physical hardware and provides
virtualization features; guest OSes run inside virtual machines. The host
manages the guests. Guest performance depends on host resource allocation.
— *Nygard, Ch. 7*

---

## Terms To Be Added

*(Placeholder for terms from subsequent chapters: instance lifecycle,
deployment, versioning, adaptation, chaos engineering, etc.)*

---

## Notes on Usage

These terms form Umi's domain language. When writing documentation, code
comments, or discussing design, prefer these precise terms over vague
alternatives:

| Instead of... | Use... |
|---------------|--------|
| "bug" | fault, error (be specific) |
| "crash" | failure (if system unresponsive) |
| "things went wrong" | crack propagation, chain of failure |
| "it spread" | the crack propagated, failure cascaded |
| "safety measure" | crackstopper, bulkhead |
| "breaking change" | impulse (if sudden), stress (if gradual) |
| "running a long time" | longevity |
| "it can handle failures" | stable, fault-tolerant, resilient (be specific) |

The goal is precision. "Failure" means something specific. "Error" means
something different. Using terms precisely enables precise thinking.
