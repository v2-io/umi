# Chapter 11: Security — Reflections for Umi

Security might seem orthogonal to Umi's core mission of resilience. But as I read this chapter, several unexpected connections emerged. The principles interweave more than I initially expected.

## Security and Resilience Share a Mindset

> "Security must be baked in. It's not a seasoning to sprinkle onto your system at the end."

Replace "security" with "resilience" and the statement is equally true. Both require:
- Cynical assumptions about the world (expect attacks / expect failures)
- Defense in depth (multiple layers / bulkheads)
- Ongoing vigilance (patch vulnerabilities / monitor health)
- Input validation (sanitize user input / validate messages)

The attacker's mindset and the failure-mode mindset are surprisingly similar: "What could go wrong? What happens if I give it garbage? What if I overwhelm it? What if a component misbehaves?"

## Ractor Isolation as Security Primitive

The chapter discusses bulkheading for security:

> "If one customer's credentials are stolen, that's bad. If the attacker can use those to get other customers' data, that's catastrophic."

Ractors provide natural isolation. A compromised worker (through a bug, not a true attacker inside the VM) cannot directly access another Ractor's data. This is security by architecture, not security by policy.

**But the isolation isn't perfect.** Ractors share:
- The filesystem (if they write files)
- External services (databases, APIs)
- The Ruby VM itself

If a worker can be manipulated to write arbitrary files (directory traversal), Ractor isolation doesn't help. If a worker has database credentials, it can access any data those credentials allow—not just "its own" data.

**For Umi:** This suggests that Proctor's isolation story is important for security too. If an external process is compromised, Proctor provides a bulkhead. The Ruby process can survive the external process going bad.

## Input Validation Is Not Just for HTTP

The OWASP Top 10 focuses on web vulnerabilities, but the principle generalizes:

> "Never trust input. Scrub it on the way in and escape it on the way out."

For Umi, "input" includes:
- Messages received on ports
- Data returned by external processes (via Proctor)
- Registry lookup results
- Configuration provided at spawn time

**The message validation question:**

Should Umi workers assume messages from other Ractors are safe? The "pie crust defense" says no:

> "Boundaries are much less clear today, so we need to think about authentication everywhere. Don't trust calls based on their originating IP addresses, because those can be faked."

In Umi terms: don't trust messages based on which Ractor sent them. A bug in the sender could produce malformed messages. A compromised Ractor (through any means) could send malicious messages.

This suggests workers should validate incoming messages even from "trusted" internal Ractors. Not with the same paranoia as untrusted external input, but with structural validation: is the message the right shape? Do values fall in expected ranges?

## Proctor and Least Privilege

> "The principle of 'least privilege' mandates that a process should have the lowest level of privilege needed to accomplish its task. This never includes running as root."

Proctor spawns external processes. What privileges do those processes run with?

- By default, they inherit the Ruby process's privileges
- If the Ruby process runs as a normal user, so do Proctor children
- But Proctor doesn't currently provide a way to *reduce* privileges further

**Question for Umi:** Should Proctor support spawning processes with reduced privileges? For example:
- Different user (if Ruby has permission to setuid)
- Restricted filesystem access (chroot, containers)
- Resource limits (ulimit, cgroups)

This is outside Umi's core scope, but it's worth documenting that Proctor doesn't add any security restrictions beyond what the parent process has.

## Credential Management and Workers

> "Passwords are the Brazil nut of application security; every mix has them, but nobody wants to deal with them."

If workers need credentials (database passwords, API keys), how do they get them?

Options (building on `ini.md`'s configuration discussion):
1. **Passed at spawn**: Supervisor provides credentials when starting worker
2. **Environment variables**: Worker reads from ENV
3. **Secret store**: Worker queries a vault service at runtime

From a security perspective:
- Option 1: Credentials in memory of every worker that receives them
- Option 2: Credentials available to any code running in the process
- Option 3: Credentials fetched on-demand, potentially with short TTL

**The memory dump warning:**

> "If the application keeps the keys or passwords in memory, then memory dumps will also contain them."

For Umi, this means workers holding credentials should be aware that:
- Core dumps could expose credentials
- Memory inspection tools could read credentials
- Long-lived workers hold credentials longer

There's no perfect answer, but Umi could document best practices:
- Fetch credentials when needed, not at startup
- Consider short-lived workers for credential-sensitive operations
- If using Option 1, supervisor should own credentials and inject them

## Attack Protection and Load Shedding

The chapter discusses insufficient attack protection:

> "Services do not typically track illegitimate requests by their origin. They do not block callers that issue too many bad requests."

This connects directly to Umi's stability patterns:

| Attack Protection | Stability Pattern |
|------------------|-------------------|
| Rate limiting bad actors | Load shedding |
| Blocking repeated failures | Circuit breaker |
| Partitioning damage | Bulkheads |
| Quick rejection | Fail fast |

**The insight:** Some security attacks look like stability problems. A DDoS attack overwhelms capacity—the response is the same as handling legitimate high load. An attacker probing for vulnerabilities issues many bad requests—the circuit breaker trips the same way it would for a misbehaving integration point.

This doesn't mean stability patterns *are* security, but they provide a foundation that makes some attacks less damaging.

## Known Vulnerabilities and Dependencies

> "Most attacks are mundane. A workbench-style tool probes IP addresses for hundreds of vulnerabilities, some of them truly ancient."

Umi will have dependencies. Those dependencies will have vulnerabilities. The question is: how do we track and patch them?

This is mostly a project hygiene issue, not an Umi design issue. But it's worth noting:
- Umi should minimize dependencies (smaller attack surface)
- Dependencies should be maintained projects (security patches available)
- Projects using Umi should audit their dependency tree

**For Proctor specifically:** Proctor wraps external processes. Those processes are often the *reason* for using Proctor—they're third-party tools like `mcp-server`, database clients, etc. Each external process is a potential vulnerability. Umi can't fix that, but it can document that external processes should be kept up-to-date.

## Security as Ongoing Process

> "Security is an ongoing activity. It must be part of your system's architecture."

The same is true for resilience. You don't "add stability patterns" at the end. You design for stability from the beginning. You monitor, adjust, and improve continuously.

Both security and resilience require:
1. **Design-time decisions**: Architecture that supports the goals
2. **Build-time checks**: Tests, static analysis, dependency scanning
3. **Runtime monitoring**: Detect problems before they become catastrophes
4. **Continuous improvement**: Learn from incidents, patch weaknesses

Umi provides the design-time and runtime components for resilience. Security is a parallel concern that uses similar infrastructure (monitoring, circuit breakers, bulkheads) for different goals.

## Questions for Umi

1. **Message validation**: Should Umi provide helpers for validating message structure? Or is that purely application concern?

2. **Credential injection**: Should Umi document best practices for credential management in workers?

3. **Proctor privilege reduction**: Is there any value in Proctor supporting privilege dropping for spawned processes?

4. **Logging sensitive data**: Should Umi's transparency features have any awareness of sensitive data that shouldn't be logged?

5. **Dependency audit**: As Umi matures, should we include dependency checking in the build process?

## The Bigger Picture

This chapter reinforces something I've been noticing throughout the book: **the same architectural patterns appear in different contexts.**

- Bulkheads: Stability pattern, security pattern
- Fail fast: Stability pattern, attack protection pattern
- Timeouts: Stability pattern, credential TTL pattern
- Defense in depth: Stability concept, security concept
- Cynical design: Expect failures, expect attacks

Umi is primarily about resilience, not security. But a well-designed Umi application inherits some security benefits from its architecture. Ractor isolation is a bulkhead. Proctor is a containment barrier. Circuit breakers limit the damage from attackers as well as from failures.

Security and resilience are cousins. They share the same cynical worldview and many of the same defensive patterns. Building one well tends to help the other.
