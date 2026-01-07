# Umi Implementation Plan

Iterative cycles, thin vertical slices. Each cycle produces working, tested code.

See `docs/plan/*.md` for detailed design rationale.
See `docs/tmp/implementation-sketches.md` for rough code sketches.

---

## Cycle 1: Minimal Vertical Slice

The simplest system demonstrating core patterns working together.

### Registry
- [x] Single Ractor, global namespace
- [x] `register(name, ractor)` / `lookup(name)` / `unregister(name)`
- [x] Auto-unregister on Ractor death (via monitor)
- [x] Thread-safe via message passing (no locks)

### Worker
- [x] `start_link` spawns Ractor with message loop
- [x] Call pattern (request + reply port)
- [x] Cast pattern (fire-and-forget)
- [x] Shutdown handling
- [x] WorkerHandle for callers

### Supervisor
- [x] Static child specs
- [x] `:one_for_one` strategy only
- [x] Restart bounding (max_restarts / within_seconds)
- [x] Escalation on exceeded restarts (supervisor dies)
- [x] Monitor all children
- [x] Shutdown in reverse start order

### Tests
- [x] Registry: register, lookup, auto-cleanup, collision error (26 tests)
- [x] Worker: call, cast, shutdown, crash notification (23 tests)
- [x] Supervisor: start children, restart on death, escalation, shutdown (13 tests)
- [ ] Integration: Supervisor + Worker + Registry together

---

## Cycle 2: Coordinator

The "boring root" that enables "let it crash."

### Coordinator
- [ ] Signal handling (TERM, INT → shutdown; PIPE ignored)
- [ ] Bootstrap phase (start kernel Ractors, then applications)
- [ ] Registry as kernel Ractor (death = halt)
- [ ] Steady-state loop (select on signals + monitors)
- [ ] Shutdown sequence (reverse order, timeouts)
- [ ] Check for shutdown between bootstrap phases

### Application (minimal)
- [ ] Named bundle of child specs
- [ ] Dependency declaration (for ordering)
- [ ] Start = create supervisor with children
- [ ] Stop = shutdown supervisor

### Tests
- [ ] Boot with no apps, verify running
- [ ] SIGTERM triggers graceful shutdown
- [ ] Kill kernel Ractor → system halts
- [ ] Application starts and is monitored
- [ ] Full stack integration test

---

## Cycle 3: Refinement

Based on learnings from Cycles 1-2.

Candidates (prioritize based on what we learn):
- [ ] `:permanent` / `:transient` / `:temporary` restart types
- [ ] Application lifecycle hooks (prepare, running, stopping)
- [ ] Named worker registration (worker self-registers)
- [ ] DynamicSupervisor (runtime child creation)
- [ ] Better dead-Ractor identification (if race condition bites us)
- [ ] Health check endpoint

---

## Already Done

- `Umi::Proctor` - external process wrapper
- `Umi::MCPClient` - MCP client on Proctor
- Timer port pattern (in Proctor)
- Spikes validating all Ruby 4.0 primitives

---

## Technical Debt

### Test Framework Unification
The existing Proctor and MCP tests use a standalone script format with custom assertion
helpers. Consider migrating to Minitest for consistency:
- `test/proctor_test.rb` - standalone script
- `test/proctor_api_test.rb` - standalone script
- `test/mcp_client_test.rb` - standalone script
- `test/mcp_chaos_test.rb` - standalone script (chaos injection)
- `test/proctor_stress_test.rb` - standalone script (stress tests)

Benefits: unified test runner, consistent assertion API, better IDE integration.
Risk: high - these tests are well-proven and modifications could introduce bugs.

---

## Open Questions (resolve during implementation)

1. Force-kill mechanism - does Ruby 4.0 have `Ractor.kill`? If not, what's the fallback?
2. Dead Ractor identification - is `find { !alive? }` race acceptable or needs mitigation?
3. Registry shutdown protocol - stop accepting registrations? notify registered Ractors?
4. Worker self-registration timing - before or after init completes?
