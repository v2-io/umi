# Umi (海)

**OTP-like resilience patterns for Ruby 4.0**

Umi brings battle-tested stability patterns to Ruby, leveraging Ruby 4.0's improved
Ractors to build systems that gracefully handle failure. The name means "sea" or
"deep water" in Japanese - systems that remain calm on the surface while handling
turbulence below.

## The Problem

> "Triggering a fault opens the crack. Faults become errors, and errors provoke
> failures. That's how the cracks propagate."
> — Michael Nygard, *Release It!*

Tight coupling accelerates cracks. Every connection is a potential failure point.
Every shared resource is a bottleneck waiting to become a system-wide outage.

Umi provides Ruby-native solutions to these stability antipatterns:

| Problem | What Happens | Umi's Answer |
|---------|--------------|--------------|
| **Blocked Threads** | System appears up but does nothing | Timeouts everywhere |
| **Cascading Failures** | One failure triggers callers to fail | Bulkheads via Ractors |
| **Slow Responses** | Worse than no response - ties up resources | Circuit breakers |
| **Chain Reactions** | Load spreads to remaining instances | Let it crash + restart |
| **Dogpile** | Everyone retries at once after recovery | Backpressure, governors |

## Philosophy

**The goal is not to make Ruby act like Erlang.** The goal is to solve the same
problems—crack propagation, cascading failures, blocked threads—in a way that
feels natural to Rubyists.

OTP is a solution. "Release It!" describes the problems. Ruby 4.0 Ractors provide
new primitives. Umi reasons from problems to solutions rather than translating
someone else's answers.

## Current Status: Proctor

Umi is in early development. The first component, `Umi::Proctor`, wraps external
processes as Ractor-citizens with:

- **Bidirectional messaging** - stdin/stdout as send/receive
- **Death notification** - via `Ractor.monitor`
- **Isolation** - process crashes become messages, not Ruby crashes
- **OTP-style tagged tuples** - pattern matching for control flow

```ruby
require 'umi'

proctor = Umi::Proctor.new("cat")
proctor << "hello\n"

case proctor.pop_stdout(2)
in [:ok, line]
  puts "Got: #{line}"
in nil
  puts "Timeout - do other work"  # Timeouts are normal, not errors
in [:closed, result]
  puts "Process exited: #{result.exit_code}"
end

proctor.close_stdin
proctor.join
```

### Why Start With External Processes?

Before building internal Ractor supervision, we're solving the same problem for
external processes. This forces us to solve the hard problems—death detection,
multiplexing, timeout handling—in a concrete, testable context. What we learn
applies directly to Ractor supervision.

## Key Insight: Ractors Are Bulkheads

Ruby 4.0's Ractors provide structural isolation by default. Each Ractor is
memory-isolated. A crash in one Ractor cannot corrupt another's state.

```ruby
# Each Ractor is a natural bulkhead
critical_work = Ractor.new { handle_payments }
background_work = Ractor.new { send_emails }
# A crash in background_work cannot affect critical_work
```

This is the foundation Umi builds on.

## Requirements

- Ruby 4.0.0 or later (uses `Ractor::Port`, `Ractor.monitor`)

## Installation

```ruby
# Gemfile (when published)
gem 'umi'

# For now, clone and add to load path
$LOAD_PATH.unshift '/path/to/umi/lib'
require 'umi'
```

## Documentation

- [First Principles](UMI_FIRST_PRINCIPLES.md) - The problems we're solving and why
- [Phase 1: Proctor](phase-1-pilot-proctor.md) - Current implementation details
- [Spike Findings](spikes/FINDINGS.md) - What we learned about Ruby 4.0 Ractors

## Running Tests

```bash
ruby test/proctor_test.rb        # Basic tests
ruby test/proctor_api_test.rb    # API contract tests
ruby test/proctor_stress_test.rb # Stress/edge case tests
ruby test/mcp_client_test.rb     # MCP protocol client tests
```

## License

MIT

## References

- Nygard, Michael T. *Release It! Second Edition.* Pragmatic Programmers, 2018.
- Thomas, Dave et al. *Programming Ruby 4th Edition.* Pragmatic Programmers, 2025.
- Mather, Bruce et al. *Designing Elixir Systems with OTP.* Pragmatic Programmers, 2019.
