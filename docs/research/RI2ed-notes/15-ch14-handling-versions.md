# Chapter 14: Handling Versions — Reflections for Umi

> "If you want others to respect your autonomy, then you must respect theirs. That means you can't force consumers to match your release schedule."

This chapter is about API versioning and compatibility. While it focuses on HTTP services, the principles apply to any interface—including the message protocols between Umi workers.

## Postel's Robustness Principle

> "Be conservative in what you do, be liberal in what you accept from others."

This is the foundation of protocol compatibility. For requests:
- Accept more than you require
- Never reject something you previously accepted

For responses:
- Return more than you promise
- Never omit something you previously returned

**The mathematical formulation:**
- Safe: Require a subset of previously required parameters
- Safe: Accept a superset of previously accepted parameters
- Safe: Return a superset of previously returned values
- Safe: Enforce a subset of previously enforced constraints

**For Umi:** Messages between workers are like API requests. If worker A sends a message to worker B:
- Worker B should accept messages even if fields are missing (liberal acceptance)
- Worker A should only send messages it knows are valid (conservative sending)
- If worker B adds optional fields to its expected format, old senders should still work
- If worker B returns more data than before, old callers should ignore the extra

## Implementation Becomes Specification

This is a sobering insight:

> "As soon as the service went live, its implementation becomes the de facto specification."

Even if documentation says "pass a URL," if the implementation accepted any string, you can't later add URL validation. Some consumer somewhere is relying on that accidental leniency.

**For Umi:** This applies to:
- Message formats between workers
- The supervision protocol (supervisor ↔ child)
- Registry naming conventions
- Proctor I/O protocols

Once workers are deployed and communicating, the *actual* message formats are the contract. Future versions must remain compatible with what workers actually send, not what documentation says they should send.

This is a strong argument for **strict message validation from day one**. If you validate early, the implementation matches the specification. If you validate later, you break callers.

## Message Protocol Versioning

When must Umi messages change? Consider:
- Supervision protocol evolves (new lifecycle states, new messages)
- Worker-to-worker protocols gain features
- Proctor adds new output types
- Registry adds metadata to registrations

**The versioning question:** Should Umi messages include version identifiers?

For **supervision protocol** (Umi-internal):
- Version is tied to Umi library version
- Supervisor and children always use same Umi version (same process)
- Less need for explicit versioning within a session

For **application messages** (user-defined):
- Users control their own protocols
- Umi doesn't impose structure
- Users could adopt versioning conventions

For **Proctor I/O**:
- Messages cross process boundaries
- External process may use different protocol version
- Version negotiation could matter

## During-State Protocol Compatibility

During a rolling restart:
- Old workers and new workers coexist
- They might send messages to each other
- Both directions must work

**Example scenario:**
1. Worker pool has 10 workers, all v1
2. Rolling restart begins, 2 workers upgraded to v2
3. V2 workers receive messages from v1 workers (must accept old format)
4. V1 workers receive messages from v2 workers (must accept old responses)

For this to work:
- V2 must accept v1 message format
- V2 must return v1-compatible responses (or v1 must ignore new fields)

**Umi implication:** Message format changes must follow expansion/contraction:
1. **Expansion**: New version accepts both old and new formats
2. **Rollout**: Mix of old and new workers
3. **Contraction**: After all workers upgraded, remove old format support (if desired)

## Contract Testing

Nygard advocates testing both sides against the specification:

> "I prefer a style of testing that has each side check its own conformance to the specification."

- **Inbound testing**: Does your service handle valid requests correctly?
- **Outbound testing**: Do you send valid requests to dependencies?

For Umi workers:
- Test that workers accept the messages they claim to accept
- Test that workers send messages that match their stated protocol
- Use generative testing to explore edge cases

The "consumer-driven contract" approach: the *caller* writes tests against the provider, catching gaps between expectations and reality.

## Version Location in Messages

For HTTP APIs, Nygard discusses:
1. URL prefix (`/v1/applications`)
2. Accept header (media type negotiation)
3. Custom header (`api-version: 2`)
4. Field in request body

**For Umi messages:** Version could be:
1. Tagged tuple style: `[:v2, :request, data]`
2. Metadata field: `{version: 2, type: :request, data: ...}`
3. Implicit (tied to worker type)

My instinct: for Umi, version should be **explicit when crossing trust boundaries** (Proctor to external process) and **implicit when internal** (workers in same Umi version).

## Multiple Version Support

During transition:

> "You must support both the old and the new versions for some period of time."

For Umi, this means:
- Supervisors might need to support children with old message formats
- Workers might need to accept messages from old callers
- The Registry might need to serve lookups for old naming conventions

This is the "during" state from Chapter 13, applied to protocols.

## Raw JSON Warning

> "Make sure to always wash your hands and clean your work surfaces after handling raw JSON!"

Deserialization is dangerous. Malformed data can crash parsers, inject unexpected types, or exceed memory limits.

**For Umi:** Workers receiving messages from:
- Other workers: Relatively safe (same process, same Umi version)
- Proctor: External process, untrusted—validate carefully
- Network (future): Completely untrusted—full validation required

The more trust boundaries crossed, the more validation needed.

## Questions for Umi

1. **Message versioning**: Should Umi messages include explicit version fields? Or is it unnecessary within a single process?

2. **Protocol stability**: Should Umi guarantee backward compatibility of its internal protocols (supervision, registry) across Umi versions?

3. **Proctor protocol**: Should Proctor have explicit protocol versioning with the external process?

4. **Message validation**: Should Umi provide helpers for validating message structure? Schema checking for worker input?

5. **Contract tests**: Should Umi provide tooling for contract testing between workers?

6. **Format evolution**: How do users evolve message formats between workers without breaking during rolling restart?

## The Bigger Picture

This chapter completes the deployment story. Chapters 12-14 together say:

1. **Make deployment cheap** (Chapter 12)
2. **Design for zero-downtime deployment** (Chapter 13)
3. **Design for protocol compatibility** (Chapter 14)

For Umi, this translates to:
1. Make worker restart cheap (fast startup)
2. Support rolling restart without downtime (supervision)
3. Support message format evolution without breaking (protocol design)

The supervision tree is Umi's deployment infrastructure. The message protocols are Umi's API contracts. The same principles that govern HTTP services govern Ractor communication—just at a smaller scale.

---

Part 3 is complete. We've covered the full arc: from deployment nightmares (Chapter 12) through zero-downtime design (Chapter 13) to protocol versioning (Chapter 14). The themes reinforce each other: cheap deployment enables frequent releases, which enables small protocol changes, which are safer than big protocol changes.
