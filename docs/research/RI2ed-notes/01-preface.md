Preface — Reflections for Umi

  The preface sets out Nygard's frame: software that must survive "contact with the real world." A few things strike me as I hold this against Umi:

  "Stability is a necessary prerequisite to any other concerns."

  This ordering—stability first, then operations, then deployment, then systemic adaptation—is the same ordering the Umi planning documents implicitly follow. But there's a subtle inversion worth noticing: Umi is building stability infrastructure, not just stable applications.

  The question this raises: How does Umi itself remain stable while enabling stability for others? The "boring root principle" in ini.md is one answer. But Nygard's book is about applications—we're building the substrate. The substrate has stricter requirements. A circuit breaker in an application is a resilience pattern; a bug in Umi's supervisor is a systemic failure mode.

  "Your software will be under attack from the moment you release it."

  Nygard means DDoS, flash mobs, IoT botnets. But there's another reading: your software will be tested by reality from moment one. Every assumption meets friction. Umi's design documents are largely about anticipated problems (death detection, timeout handling, restart bounding). But what about the problems we haven't anticipated?

  This suggests a meta-capability: Umi should make the unanticipated visible. Not just handle known failure modes, but expose when something unknown is happening. The diagnostic snapshot pattern in etc.md is one piece. But I wonder if there's something deeper—a way for Umi to surface "I don't understand what's happening here" rather than silently continuing in a potentially degraded state.

  "Two eights rather than five nines"

  This is sobering for distributed systems. But Umi is starting single-node. The implicit bet: get local resilience right before attempting distributed resilience. This is wise—but it's worth remembering that even single-node systems can exhibit surprising failure modes when Ractors, OS processes, threads, and external services interact.

  The case studies are real failures, real money.

  This grounding in concrete disaster is the book's power. Umi's planning documents are theoretical. At some point, Umi will need its own case studies—its own encounters with failure that reshape the design. The question is whether we can learn from Nygard's failures and avoid some of ours.
