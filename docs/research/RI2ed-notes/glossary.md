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

## Instance Concepts (Chapter 8)

### Transparency
The quality that allows operators, developers, and sponsors to understand a
system's historical trends, present conditions, instantaneous state, and
future projections. Debugging a transparent system is easier; transparent
systems mature faster. "A system without transparency cannot survive long
in production." Transparency arises from deliberate design—"adding
transparency" late is ineffective.
— *Nygard, Ch. 8*

### White-Box Monitoring
Internal instrumentation that reports what the system knows about itself.
Metrics libraries, agents, internal probes. More specific data than
black-box, but more tightly coupled to the implementation.
— *Nygard, Ch. 8*

### Black-Box Monitoring
External observation without internal knowledge. Log scraping, HTTP probes,
synthetic transactions. More loosely coupled than white-box monitoring.
Both approaches are needed for complete visibility.
— *Nygard, Ch. 8*

### Health Check
An endpoint or mechanism that reports an instance's ability to do work.
More than "is it running?"—should include: identity, version, whether
accepting work, connection pool status, circuit breaker state, time since
last successful request. Enables load balancer decisions, "go live"
detection, and graceful degradation.
— *Nygard, Ch. 8*

### Instance (Nygard's Definition)
One installation of an executable, operating as part of a load-balanced
array. Distinct from service (collection of processes), process (OS-level),
and executable (artifact). Precision in terminology prevents confusion when
discussing deployments and operations.
— *Nygard, Ch. 8*

### Immutable Infrastructure
Infrastructure that doesn't change after deployment. Need a change? Build
a new image, deploy it, retire the old. This is "let it crash" at the
infrastructure level. The cleanest state is right after startup.
— *Nygard, Ch. 8*

### Voodoo Operations
Operational rituals based on coincidental correlation rather than causation.
Named after a story where operators performed weekly database failovers for
six months because an ambiguous log message ("reset encrypted channel")
appeared to correlate with database warnings. The warning was unrelated.
Clear log messages prevent voodoo operations.
— *Nygard, Ch. 8*

### Exoskeleton (Monitoring)
The principle that monitoring policy (thresholds, alerts) should be external
to instances. Instances emit data; decisions about what constitutes "bad"
are made outside. This separation allows policy changes without code changes.
— *Nygard, Ch. 8*

---

## Interconnect Concepts (Chapter 9)

### Interconnect Layer
The mechanisms that knit instances together into a cohesive system: traffic
management, load balancing, service discovery. "This is where we can really
create high availability."
— *Nygard, Ch. 9*

### Virtual IP (VIP)
An IP address not strictly tied to a physical interface. Used by load
balancers to multiplex services onto fewer interfaces, and by cluster
software to migrate addresses between nodes during failover. The term is
overloaded—can mean "service address" or "migrating address."
— *Nygard, Ch. 9*

### Pool (Load Balancer)
A group of instances that can handle the same type of request. VIPs map
to pools. The pool defines load-balancing algorithm, health checks,
stickiness, and what to do when no members are available.
— *Nygard, Ch. 9*

### Service Discovery
Two parts: (1) instances announcing themselves to receive load (dynamic
pool membership), (2) callers looking up addresses for services. Service
discovery is itself a service that can fail—clients should cache results.
"It's best not to roll your own."
— *Nygard, Ch. 9*

### Going Nonlinear
A feedback loop where high load causes slower processing, which reduces
available capacity, which increases queue depth, which makes everything
even slower. The system degrades faster than linearly with load. "Every
failing system starts with a queue backing up somewhere."
— *Nygard, Ch. 9*

### Residence Time
The total time a request spends in a service: queue time plus processing
time. "Many people go wrong by measuring just their own processing time."
The queue is serial; processing is parallel—queuing time ultimately
dominates.
— *Nygard, Ch. 9*

### Listen Queue Purge
Self-aware behavior during overload: a tight loop that accepts connections
and immediately returns a canned rejection (e.g., "503 Try Again").
Clears backlog quickly instead of letting clients timeout.
— *Nygard, Ch. 9*

### Stickiness (Session Affinity)
Directing repeated requests to the same instance. Helps with stateful
services but can cause uneven load distribution. Typically implemented
via cookies or source IP hashing.
— *Nygard, Ch. 9*

### Content-Based Routing
Using something in the request (URL, headers) to route to different pools.
Search requests to one pool, sign-ups to another. The service can process
workload more efficiently when partitioned by type.
— *Nygard, Ch. 9*

### Global Server Load Balancing (GSLB)
Using specialized DNS servers at multiple geographic locations to route
clients to the nearest healthy pool. Combines DNS (for global routing)
with local load balancers (for instance selection).
— *Nygard, Ch. 9*

### CAP Theorem (in discovery context)
Distributed systems must choose two of three: Consistency, Availability,
Partition tolerance. ZooKeeper is CP (refuses queries during partition),
Consul is AP (returns possibly stale data). Matters for distributed
service discovery.
— *Nygard, Ch. 9*

### Migratory Virtual IP
An IP address that can be moved from one NIC to another as needed. Used
in active/passive database clusters. When the active node fails, the
standby node takes over the IP address. Clients connect to the VIP, not
to individual nodes. Any mid-connection failover causes errors that
applications must handle.
— *Nygard, Ch. 9*

---

## Control Plane Concepts (Chapter 10)

### Control Plane
All the software and services that run in the background to make production
load successful. If production user data passes through it, it's production
software. If its main job is to manage other software, it's the control
plane. Provides scheduling, resource allocation, lifecycle management.
— *Nygard, Ch. 10*

### Mechanical Advantage
The multiplier on human effort that simple machines (levers, pulleys)
provide. In software: automation that allows small actions to have large
effects. Works for good or ill—high leverage allows beneficial changes
(deploy to 10,000 machines) but also amplifies errors catastrophically.
— *Nygard, Ch. 10*

### System Failure vs Human Error
A framing principle: when administrative tools amplify a minor mistake
into enormous consequences, that's "the system failing humans," not
"humans failing the system." Design should limit the consequences of
mistakes, not just try to prevent mistakes.
— *Nygard, Ch. 10 (from AWS S3 postmortem analysis)*

### Platform (Control Plane)
The data center equivalent of an operating system. Abstracts underlying
infrastructure, presents a friendlier programming model, manages resources,
schedules tasks across multiple computers. Examples: Kubernetes, Mesos,
CloudFoundry.
— *Nygard, Ch. 10*

### Real-User Monitoring (RUM)
Measuring user experience directly through instrumentation in clients
(mobile apps, web apps) rather than deducing it from server-side metrics.
The best way to tell if users are receiving a good experience.
— *Nygard, Ch. 10*

### Push vs Pull Deployment
Push: central server reaches out via SSH to run scripts on targets.
Pull: machines know their roles and fetch configuration from a service.
Pull works better with elastic scaling and ephemeral identities.
— *Nygard, Ch. 10*

### Canary Deployment
Deploying new builds to a small subset of instances first, monitoring
their behavior before rolling out to the full population. If canary
instances behave oddly, the build is not deployed further. Every stage
of deployment is an opportunity to reject a bad build.
— *Nygard, Ch. 10*

### Command Queue
A shared message queue or pub/sub bus that instances listen to for
administrative commands. Scales better than individual API calls but
can easily create dogpiles. Use jitter and waves to spread out responses.
— *Nygard, Ch. 10*

### Nominal Range
For a metric, the range of values considered normal and acceptable.
Often defined as "mean value for this time period plus or minus two
standard deviations." Outside nominal triggers alerts.
— *Nygard, Ch. 10*

---

## Security Concepts (Chapter 11)

### Pie Crust Defense
A naive security model where authentication only happens at system boundaries,
with services inside the "pie" trusting each other freely. "Boundaries are
much less clear today, so we need to think about authentication everywhere."
Internal services should validate callers too.
— *Nygard, Ch. 11*

### Attack Surface
The sum of all IP addresses, ports, and protocols reachable to attackers.
Reducing attack surface means removing unnecessary services, splitting
admin interfaces to internal-only networks, and eliminating default accounts.
— *Nygard, Ch. 11*

### Principle of Least Privilege
A process should have the lowest level of privilege needed to accomplish
its task. Never run as root/administrator. Each application should have
its own user. Containers help but must still be secured internally.
— *Nygard, Ch. 11*

### Password Vaulting
Keeping passwords in encrypted storage, reducing the security problem to
securing one encryption key rather than multiple text files. Tools like
HashiCorp Vault and AWS KMS. Important: expunge keys from memory after use.
— *Nygard, Ch. 11*

### Session Hijacking
An attacker gains control of a user's session by obtaining the session ID.
Can happen via URL exposure, network sniffing, or XSS. Defense: long
random session IDs, HTTPS everywhere, HttpOnly cookies, fresh ID on
authentication.
— *Nygard, Ch. 11*

### Direct Object Access
A broken access control where URLs include database IDs, allowing attackers
to probe for other resources. Defense: randomized identifiers, session-scoped
mappings, and always check authorization on every request.
— *Nygard, Ch. 11*

### Injection (Security)
Attack on a parser/interpreter using crafted input. SQL injection, XML
external entity (XXE), format string attacks. Defense: parameterized
queries, hardened parsers, never concatenate strings to build structured
data.
— *Nygard, Ch. 11*

---

## Deployment Concepts (Chapters 12-13)

### Deployment Army
Antipattern where large numbers of people are required for deployments.
Causes include: manual procedures, rigid playbooks, environment drift,
poor tooling. Costs: direct (labor), indirect (batched changes increase
risk), human (disrupted lives, wasted potential).
— *Nygard, Ch. 12*

### Build Pipeline (Build Funnel)
Automated sequence from code commit to production deployment. Each stage
looks for reasons to reject the build. Tests failed? Reject. Lint
complains? Reject. Integration tests fail? Reject. Goal: ensure bad
builds never reach production.
— *Nygard, Ch. 13*

### Convergence (Deployment)
Deployment approach where tools examine current machine state and make a
plan to match desired state. Works for long-lived machines ("pets").
Opposite of immutable infrastructure.
— *Nygard, Ch. 13*

### Immutable Infrastructure (Deployment)
Deployment approach where machines are never modified after creation.
Changes create new machines from a known base image. Works for ephemeral
machines ("cattle"). The unit of packaging is a whole VM or container image.
— *Nygard, Ch. 13*

### Drain Time
How long it takes for in-flight work to complete after a machine stops
accepting new requests. For stateless services: seconds. For sticky
sessions: timeout plus maximum duration. Blocked threads block the drain—
another reason timeouts are essential.
— *Nygard, Ch. 13*

### Expansion / Contraction (Schema)
Schema changes split into two phases. Expansion (before rollout): add
tables, columns, views—things safe for old code. Contraction (after
rollout): drop old structures, add constraints—things old code couldn't
handle. Enables zero-downtime schema migrations.
— *Nygard, Ch. 13*

### Shim (Deployment)
Code that bridges old and new versions during rollout. Database triggers
that sync old and new tables. Translation code that converts old formats.
Temporary—removed in cleanup phase.
— *Nygard, Ch. 13*

### Trickle Then Batch
Migration strategy: conditionally migrate records when touched during
normal operation. After most are converted through use, run batch
migration on the remainder. Amortizes migration cost across requests,
eliminates downtime for migration.
— *Nygard, Ch. 13*

### Microscopic/Macroscopic Time
Deployment operates at two scales. Microscopic: individual machine
(drain, apply, restart, warm up). Macroscopic: entire rollout (prepare,
roll batches, cleanup). Plan for both.
— *Nygard, Ch. 13*

---

## Versioning Concepts (Chapter 14)

### Postel's Robustness Principle
"Be conservative in what you do, be liberal in what you accept from others."
Foundation of protocol compatibility. Accept more than required, return
more than promised. Never reject what was previously accepted, never omit
what was previously returned.
— *Nygard, Ch. 14 (citing RFC 761)*

### Breaking Change (API)
Any unilateral break from a prior agreement: rejecting previously valid
syntax, requiring new parameters, removing data from responses, increasing
authorization requirements. Even "fixing" lax validation is a breaking
change if callers depend on the leniency.
— *Nygard, Ch. 14*

### Contract Test
Test that verifies conformance to a specification, owned by the consumer.
"Inbound" tests exercise your API; "outbound" tests exercise dependencies.
Each side tests against the contract independently, rather than testing
the end-to-end loop.
— *Nygard, Ch. 14*

### Implementation as Specification
Once a service is live, its actual behavior becomes the de facto
specification. If documentation says "pass URL" but implementation
accepts any string, adding URL validation later is a breaking change.
Validate strictly from day one.
— *Nygard, Ch. 14*

### Covariant/Contravariant (Versioning)
From type theory: requests are covariant (can accept more over time),
responses are contravariant (can return more over time). This creates
asymmetry in what changes are safe.
— *Nygard, Ch. 14*

---

## Case Study Concepts (Chapter 15: Trampled by Your Own Customers)

### Testing Gap
The difference between how systems are tested and how they're actually used.
Load tests use "polite scripts" that follow links, use cookies properly, and
wait between requests. Real traffic includes scrapers, bots, old cached URLs,
and "random weird stuff." Testing the happy path tells you nothing about
hostile traffic.
— *Nygard, Ch. 15*

### Polite Scripts
Load test scripts that behave like ideal users: follow navigation paths, use
cookies properly, wait appropriate intervals. The problem: real users and
bots don't behave politely. Scrapers fire requests as fast as possible,
search engines don't maintain sessions, cached deep links bypass entry pages.
— *Nygard, Ch. 15*

### Hostile Traffic
Traffic that doesn't follow expected patterns: search engine crawlers (no
cookies, new session per request), shopbots and scrapers (high volume,
evasive), old URLs from cached search results (404s that still create
sessions), "random weird stuff." Systems must survive hostile traffic, not
just polite test scripts.
— *Nygard, Ch. 15*

### Session Accumulation
When sessions are created faster than they expire. Each session consumes
resources (RAM, CPU for replication, bandwidth). Under hostile traffic
(bots creating new sessions per request), sessions pile up until resources
are exhausted. "Sessions are the Achilles' heel of every application server."
— *Nygard, Ch. 15*

### Safety Devices (Missing)
The absence of protective mechanisms that would cut off bad situations.
When things go wrong: threads pile into the danger zone, no circuit
breakers, no load shedding, no graceful degradation. "Like a foggy freeway
pileup—new requests crashed into stuck ones."
— *Nygard, Ch. 15*

### Noise and Chaos (Testing)
Deliberately introducing abnormal inputs during testing. "Noise and chaos
might only bleed away some amount of your capacity, but it might also bring
your system down." The "tester walks into a bar" approach: order a beer,
order 0 beers, order 99999 beers, order a lizard, order -1 beers, order
"sfdeljknesv."
— *Nygard, Ch. 15*

### Tester Walks Into a Bar
A testing philosophy joke: "A tester walks into a bar. Orders a beer. Orders
0 beers. Orders 99999 beers. Orders a lizard. Orders -1 beers. Orders a
sfdeljknesv." Good testers don't follow the happy path. Good load testing
includes chaos. Tests should include: messages with missing fields, messages
at overwhelming rates, invalid formats, rapid connect/disconnect.
— *Nygard, Ch. 15*

### Nothing More Permanent Than Temporary Fixes
Emergency workarounds tend to become permanent. "Most of these remained in
place for multiple years." One fix lasted a decade. If your design includes
"we'll fix this later" compromises, they'll probably ship. Choose temporary
fixes very carefully—they'll likely become permanent architecture.
— *Nygard, Ch. 15*

### CDN as Safety Layer
Using a CDN (Content Delivery Network) as an emergency load-shedding
mechanism external to the application. Can implement: cookie checking (reject
non-compliant browsers), throttle percentage (reject some percentage of new
sessions), IP blocking (reject known bad actors). Provides manual operator
control during crisis. Works even when the application is overwhelmed.
— *Nygard, Ch. 15*

### Throttle Percentage
An emergency control that rejects a configurable percentage of new sessions.
"Reject 50% of new sessions" reduces load by half. A crude but effective
emergency measure. Part of the CDN safety layer approach.
— *Nygard, Ch. 15*

### IP Blocking
Emergency measure to reject traffic from known bad actors by IP address.
Part of the CDN safety layer. Can be dynamically updated during incidents.
Effective against concentrated attack sources but limited against distributed
attacks.
— *Nygard, Ch. 15*

### 1000 Database Transaction Home Page
Anti-pattern where a seemingly simple page requires enormous backend work.
"More than 1,000 database transactions to build the page... drop-down menus
with nice rollover effects required traversal of eighty-odd categories."
Personalization nobody used, complexity nobody needed, cost paid on every
request. Measuring makes costs visible.
— *Nygard, Ch. 15*

---

## Adaptation Concepts (Chapter 16)

### OODA Loop
Observe → Orient → Decide → Act. Military decision cycle adapted to business.
The time to complete this cycle is the key constraint on adaptability. Faster
loops mean competitive advantage—you force others to react to you. For Umi:
transparency enables Observe, supervision trees enable Act.
— *John Boyd, via Nygard, Ch. 16*

### Thrashing
Changing direction without waiting for feedback. Like pilot-induced oscillation—
when control inputs are faster than system response, violent swings result.
In software: restarting faster than the system can recover, changing config
faster than workers can adapt. The leaky bucket algorithm prevents thrashing.
— *Nygard, Ch. 16*

### Service Extinction
"The most important part of evolution is extinction." Build small services.
Let them compete. Kill the losers. Requires services small enough to delete
without breaking the system. For Umi: design supervision trees so subtrees
are deletable.
— *Nygard, Ch. 16*

### Two-Pizza Team
Amazon's rule: a team should be small enough to feed with two pizzas. The
real principle is reducing external dependencies—small teams that can deploy
independently without coordinating with other teams. "If you ever need to
update both provider and caller simultaneously, they're too tightly coupled."
— *Nygard, Ch. 16*

### Evolutionary Architecture
Architecture that "supports incremental, guided change as a first principle
across multiple dimensions." Key insight: layered architecture couples
horizontally (all controllers must change together); component-based couples
vertically (components change independently). Prefer component-based.
— *Nygard, Ch. 16*

### Modular Operators
Six operators from Baldwin and Clark's *Design Rules* for evolving systems:
- **Splitting**: Break module into submodules
- **Substituting**: Replace one module with another (same interface)
- **Augmenting**: Add a new module
- **Excluding**: Remove a module without affecting others
- **Inversion**: Extract common functionality to a higher level
- **Porting**: Reuse a module from a different system
Every boundary is an opportunity to apply these operators.
— *Baldwin & Clark, via Nygard, Ch. 16*

### Loose Clustering
A cluster where "the loss of an individual instance is no more significant
than the fall of a single tree in a forest." Requirements: no differentiated
roles (or roles present in multiple instances), independent startup order,
no static knowledge of cluster members. Workers discover colleagues at
runtime, aren't configured with colleague identities.
— *Nygard, Ch. 16*

### Explicit Context
"Implicit dependencies limit you to working with just one service provider."
An opaque ID (like "item_id: 12345") requires implicit knowledge of where to
look it up. A URL carries its own context—you can resolve it without external
knowledge. Pass URLs, not IDs that require hardcoded addresses.
— *Nygard, Ch. 16*

### URL Dualism
URLs as both identifiers and locators. They identify a resource (stable name)
and locate it (how to access). For internal services, explicit context is
more important than the specific form—the principle is self-sufficiency of
references.
— *Nygard, Ch. 16*

### Concept Leakage
"There's no such thing as a natural data model, there are only choices we
make." When internal concepts leak into external interfaces, downstream
systems must change when internals change. Example: adding "price point"
concept internally forces all downstream systems to understand it.
— *Nygard, Ch. 16*

### Event Sourcing
Information architecture where "the event itself is primary." Events are
preserved as a journal; current state is derived (just a cache). More
powerful than state-first (can replay history, reconstruct any past state)
but more complex. Consider for debugging and audit trails.
— *Nygard, Ch. 16*

### No Coordinated Deployments
Warning sign for tight coupling: "If you ever find that you need to update
both the provider and caller of a service interface at the same time, it's
a warning sign that those services are strongly coupled." Each worker type
should be deployable independently. If you must restart multiple worker
types atomically, they're too coupled.
— *Nygard, Ch. 16*

### Utilization Fallacy
The belief that keeping resources 100% busy maximizes efficiency. Actually,
high utilization makes work move slower (queuing theory—wait time approaches
infinity as utilization approaches 100%). Slack enables adaptation. Leaving
room in the system enables response to change.
— *Nygard, Ch. 16*

### Specialization Trap
Optimizing for today makes tomorrow's changes harder. "Shell scripts are
crude, but they work everywhere." The less optimized solution may be more
adaptable. Provide primitives that can be combined flexibly rather than
fixed, optimized frameworks.
— *Nygard, Ch. 16*

### Layered vs Component Architecture
Layered architecture couples horizontally (all controllers must change
together). Component-based architecture couples vertically (within each
component) but allows components to change independently. Layered inhibits
change; component-based supports evolution.
— *Nygard, Ch. 16*

### Services Control Their Identifiers
"Services should issue their own identifiers. Let the caller keep track of
ownership." Don't embed ownership relationships in your model. Let callers
manage their own mappings. Workers register under names they choose;
callers look up by name. Simpler than having registries manage ownership
hierarchies.
— *Nygard, Ch. 16*

### Data Agnosticism
Design principle: workers should be data-agnostic where possible. "Parse
only what you need. Pass through the rest." If worker A adds a new field
to its messages, worker B shouldn't need to understand it if B just passes
it through. Minimizes concept leakage and coupling.
— *Nygard, Ch. 16*

### Information Architecture
The structure of data within and between systems. Key distinction: state-first
(current values are primary, history is discarded) vs event-first (events
are primary, state is derived). Choice affects replay capability, audit
trails, and recovery options.
— *Nygard, Ch. 16*

### Pilot-Induced Oscillation
Aviation phenomenon where pilot control inputs are faster than aircraft
response, causing violent swings. Software equivalent: changing configuration
or restarting faster than the system can respond. The leaky bucket algorithm
paces actions to prevent oscillation.
— *Nygard, Ch. 16*

---

## Chaos Engineering Concepts (Chapter 17)

### Chaos Engineering
"The discipline of experimenting on a distributed system in order to build
confidence in the system's capability to withstand turbulent conditions in
production." Empirical rather than formal—we run experiments to learn what
the system *does*, not use models to understand what it *should* do.
— *principlesofchaos.org, via Nygard, Ch. 17*

### Emergent Properties (Non-Composable Safety)
Properties that arise from system interaction but cannot be observed in
individual components. "Safety is not a composable property"—two services
may each be safe individually, but their composition isn't necessarily safe.
Example: two services with 30ms p99 latency may together exceed a 50ms
timeout. This is why chaos engineering emphasizes whole-system perspective.
— *Nygard, Ch. 17*

### Resilience Engineering
A multidisciplinary field studying how systems cope with complexity and
disturbance. Draws from cybernetics, complex adaptive systems, and
high-reliability organizations. Emphasizes that failures are inevitable,
*a priori* prediction of all failure modes is impossible, and human action
is a major source of failures. Focus on recovery rather than prevention.
— *John Allspaw, Sidney Dekker, via Nygard, Ch. 17*

### Drift into Failure
Sidney Dekker's concept: systems exist in a realm bounded by economic
viability, acceptable workload, and safety. Economic pressure and human
nature create a gradient pushing systems toward safety boundaries. Like
airliners flying at economically optimal altitudes where the margin between
stall speed and turbulence-inducing speed is narrower. "Highly efficient
systems handle disruption badly. They tend to break all at once."
— *Dekker, "Drift into Failure," via Nygard, Ch. 17*

### Fundamental Regulator Paradox
Weinberg's insight: "The task of a regulator is to eliminate variation, but
this variation is the ultimate source of information about the quality of
its work. Therefore, the better job a regulator does, the less information
it gets about how to improve." Paraphrased: "You don't know how much you
depend on your IT staff until they go on vacation." Chaos engineering
creates the variation needed to learn.
— *Gerald Weinberg, "General Principles of Systems Design," via Nygard, Ch. 17*

### Volkswagen Microbus Paradox
"You learn how to fix the things that often break. You don't learn how to
fix the things that rarely break." Implication: when rarely-breaking things
finally break, the situation is dire. Solution: create a continuous low
level of breakage to maintain competence for handling larger failures.
— *Nygard, Ch. 17*

### Antifragile
Nassim Taleb's term for systems that improve from stresses. Distributed
systems don't naturally fall into this category—they degrade under stress.
Chaos engineering uses stress like a weightlifter uses iron: "to create
tolerable levels of stress and breakage to increase the strength of the
system over time."
— *Taleb, "Antifragile," via Nygard, Ch. 17*

### Chaos Monkey
Netflix tool that randomly kills instances in production. Born during
Netflix's AWS migration. The insight: "Netflix needed failures to happen
*more often* so that they became totally routine." Follows the agile adage:
"If something hurts, do it more often." Kills one instance from a randomly
selected autoscaling cluster; the cluster should recover automatically.
— *Netflix, via Nygard, Ch. 17*

### Simian Army
Netflix's collection of chaos tools: Chaos Monkey (kills instances), Latency
Monkey (adds latency), Janitor Monkey (cleans up unused resources),
Conformity Monkey (checks configurations), Chaos Kong (simulates entire
region failure). "Every new kind of monkey improves overall availability."
Made open source at netflix.github.io.
— *Netflix, via Nygard, Ch. 17*

### Latency Monkey
Chaos tool that adds latency to calls. Finds two kinds of weaknesses:
(1) services that timeout and report errors when they should have useful
fallbacks, (2) undetected race conditions that only appear when responses
arrive in different order than usual.
— *Netflix, via Nygard, Ch. 17*

### Opt-In vs Opt-Out (Chaos)
Organizational approaches to chaos engineering adoption. Netflix chose
opt-out: every service is subject to Chaos Monkey unless explicitly
exempted (requires sign-off, carries stigma). Opt-in has much lower
adoption rates but may be necessary for mature, fragile architectures.
Recommended: start opt-in to build success stories, then transition to
opt-out.
— *Nygard, Ch. 17*

### Blast Radius
The magnitude of bad experiences from a chaos test—both the number of
customers affected and the degree of disruption. Chaos experiments should
control blast radius by selecting "victims" based on criteria (e.g., "every
10,000th request") rather than affecting everyone.
— *Nygard, Ch. 17*

### Steady State (Chaos Context)
The healthy condition a system should maintain even under turbulent
conditions. Chaos hypotheses are framed as: "Under condition X, the system
should maintain steady state Y." Example: "Clustered services should be
unaffected by instance failures." If steady state is not maintained, the
hypothesis is invalidated.
— *Nygard, Ch. 17*

### Invariant (Chaos Context)
A property the system should uphold even under turbulence. Focus on
externally observable behavior, not internals. Examples: "Response time
stays under 100ms," "Error rate stays below 0.1%," "All requests eventually
complete or fail cleanly." Form hypotheses around invariants.
— *Nygard, Ch. 17*

### Fault Injection
Deliberately introducing faults to test system response. Types: kill
instances (crude but effective), add latency (finds timeouts and race
conditions), fail service calls (finds missing fallbacks). The key question:
which instances, connections, and calls are *interesting* enough to inject?
— *Nygard, Ch. 17*

### FIT (Failure Injection Testing)
Netflix technique for injecting subtle failures. Tags a request at the
inbound edge with a cookie saying "this request will fail when service G
calls service H." At the call site, the cookie is checked and the call is
failed without making the actual request. Requires a common framework for
outbound service calls.
— *Netflix, via Nygard, Ch. 17*

### LDFI (Lineage-Driven Fault Injection)
Research approach by Peter Alvaro (UC Santa Cruz) for learning how to break
systems by observing normal operation. Collects traces, builds a graph of
service dependencies, uses graph algorithms to find links to cut. When a
cut link doesn't cause failure, learns about redundancy. Dramatically
narrows the search space for productive chaos tests.
— *Peter Alvaro, via Nygard, Ch. 17*

### Cunning Malevolent Intelligence
Peter Alvaro's term for automated systems that learn to target chaos
injections effectively. Instead of random fault injection, the system
observes successful requests, infers dependencies, and systematically
tests links to find critical paths. "Can dramatically reduce the time
needed to run productive chaos tests."
— *Peter Alvaro, via Nygard, Ch. 17*

### ChAP (Chaos Automation Platform)
Netflix's platform for managing chaos experiments. Decides what injections
to apply, when, to whom, and which services are off-limits. Ensures one
customer doesn't get flagged for all experiments at once. Reports tests
to monitoring systems for correlation with production behavior changes.
— *Netflix, via Nygard, Ch. 17*

### Disaster Simulation (Zombie Apocalypse)
Chaos engineering for the human side of organizations. Randomly select
50% of people as "incapacitated"—they must stay away from work and not
respond to communication. Discover key processes that depend on specific
individuals. After simulation, conduct postmortem and fix gaps through
documentation, role changes, or automation. Have an abort code word for
real emergencies.
— *Nygard, Ch. 17*

### High-Reliability Organizations
Organizations (nuclear plants, aircraft carriers, air traffic control)
that operate complex, hazardous systems with remarkably few failures. Use
drills and simulations to find systemic weaknesses in both technology and
human processes. Source of practices adapted by chaos engineering.
— *Resilience engineering research, via Nygard, Ch. 17*

### Cybernetics
The study of regulatory systems, their structures, constraints, and
possibilities. One of the intellectual antecedents of chaos engineering,
along with complex adaptive systems and resilience engineering. Weinberg's
"fundamental regulator paradox" comes from this tradition.
— *Nygard, Ch. 17*

### Complex Adaptive Systems
Systems composed of many interacting agents that adapt to each other's
behavior. Another intellectual antecedent of chaos engineering. Distributed
software systems exhibit complex adaptive behavior—components react to
each other in ways that create emergent properties not predictable from
individual component behavior.
— *Nygard, Ch. 17*

### Whole-System Perspective
Chaos engineering's emphasis on testing the complete system, not isolated
components. "Many problems only reveal themselves in the whole system":
excessive retries, cascading failures, dogpiles, slow responses, single
points of failure. Staging environments aren't full-size replicas; only
production reveals production-scale behavior.
— *Nygard, Ch. 17*

### Safety Boundary
The limit beyond which a system fails catastrophically. Systems drift
toward safety boundaries under economic pressure. Chaos engineering
provides a counterforce—stress testing that reveals how close the system
is to its safety boundary before production traffic discovers it.
— *Nygard, Ch. 17*

### Economic Gradient
The pressure that pushes systems toward maximum efficiency (and thus toward
safety boundaries). "We will optimize the system for maximum gain... right
up until the time a disruption occurs." Chaos engineering counterbalances
this gradient by optimizing for resilience, not just throughput.
— *Nygard, Ch. 17*

### Request Tracing
Tracking a request through all tiers of the system. Essential for chaos
engineering: if a chaos-affected request succeeds, the trace shows where
redundancy saved it; if it fails, the trace shows where failure occurred.
Requires correlation IDs propagated through all service calls.
— *Nygard, Ch. 17*

### Recovery Plan (Chaos)
Plan for returning the system to healthy state after a chaos experiment.
The system may not automatically recover when chaos is turned off. Must
know what to restart, disconnect, or clean up. Without a recovery plan,
chaos experiments can leave persistent damage.
— *Nygard, Ch. 17*

### Hypothesis (Chaos)
The expected behavior under chaos conditions. Examples: "Clustered services
should be unaffected by instance failures," "The application is responsive
even under high latency conditions." Frame hypotheses around invariants.
Check that you can measure whether the hypothesis holds before running
the experiment.
— *Nygard, Ch. 17*

### Statistical Significance (Chaos)
The threshold of evidence needed to reject a hypothesis. "A non-zero
failure rate on a request type" may not be sufficient—some failures are
normal (mobile connections abort). Need to determine what change in metrics
constitutes real evidence versus noise. May require statistics knowledge.
— *Nygard, Ch. 17*

### Targeting (Chaos)
Deciding which components to inject faults into. Random selection works
early (the search space for faults is densely populated). As easy bugs
are fixed, the space becomes more sparse. Need targeted injections based
on system knowledge: which calls are crucial? What happens if this link
fails? Humans use abductive reasoning; automation can use LDFI.
— *Nygard, Ch. 17*

### Search Problem (Chaos)
Chaos engineering as searching a high-dimensional space for faults that
cause failures. With n service-to-service calls, there could be 2^n
possible faults to inject. Random search works initially but becomes
inefficient. LDFI and targeted injection narrow the search space.
— *Nygard, Ch. 17*

### Cluster Membership Roster
A list of instances in a cluster. Chaos engineering at Netflix revealed
rosters that "grew without bounds"—old IP addresses stayed on the list
even after instances were terminated. If an IP came back as a different
service, it would be treated as the original. Configuration rot revealed
by chaos.
— *Nygard, Ch. 17*

### Business Continuity
The ability to continue operations when part of the organization is
unavailable. Disaster simulations test this: "What happens when your
single point of failure goes home every evening?" Larger scale: what if
a building or city is inaccessible? Chaos engineering applies to human
systems, not just software.
— *Nygard, Ch. 17*

### Abort Signal (Chaos)
A way to immediately stop a chaos experiment. "Be sure you have a way to
abort the exercise." For zombie simulations, a code word means "this is
not part of the drill." For automated chaos, a kill switch that stops
all fault injection. Essential when "learning opportunity" becomes
"existential crisis."
— *Nygard, Ch. 17*

### If It Hurts, Do It More Often
Agile principle applied to chaos engineering. Netflix needed failures to
happen more often so they became routine. The same principle applies to
deployments, testing, and any painful process: frequent small pains build
competence and reduce the impact of each occurrence.
— *Agile folklore, via Nygard, Ch. 17*

---

## Terms Complete

All major terminology from Release It! Second Edition has been captured.
This glossary provides Umi's domain language for resilience engineering.

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
