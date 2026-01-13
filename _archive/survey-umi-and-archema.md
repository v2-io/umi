⏺ Yes, this is a fundamental paradigm shift. Let me think through what changes...

  The Paradigm Shift

  | One-Shot (Current Ruby Default)                      | Long-Running (OTP-Style)                                      |
  |------------------------------------------------------|---------------------------------------------------------------|
  | Process starts, does work, exits                     | Process runs indefinitely                                     |
  | State is external (DB, files)                        | State lives in supervised workers                             |
  | Errors crash process; external orchestrator restarts | Errors crash workers; internal supervisors restart            |
  | Resources are class definitions, static at boot      | Resources could be runtime entities, versioned, hot-updatable |
  | Schema migrations happen "offline" between deploys   | Schema evolution while serving traffic                        |
  | Each request starts fresh                            | Rich in-memory projections, caches                            |

  What This Opens Up in Archema

  1. Resources as Runtime Entities

  Currently a Resource is a class definition loaded once. In long-running mode:

  # Resources could be versioned, registered, dynamically evolved
  Archema::Registry.register(:user, UserV1)
  # Later, without restart:
  Archema::Registry.evolve(:user, UserV2, migration: :background)
  # Queries route based on compatibility

  The was: syntax for field renames becomes more powerful—old and new versions coexist while migration runs.

  2. Domains as Applications (Layer 3)

  Ash has Domains for grouping resources. In long-running Archema:

  # Each domain is a supervised Application with its own failure policy
  Archema::Domain.define :identity do
    # Ultra-critical: crash on any anomaly, refuse writes unless perfect
    resilience :paranoid

    resource Axiomata    # Core identity
    resource Chronica    # Event log
  end

  Archema::Domain.define :social do
    # More tolerant: retry failures, degrade gracefully
    resilience :resilient

    resource Memorata    # Curated memories
    resource Consortia   # Relationship models
  end

  Failure in :social doesn't cascade to :identity. Clear dependency ordering at startup.

  3. Store Adapters as Supervised Workers

  # Each store is a supervised worker with circuit breaker
  class Archema::StoreWorker
    include Umi::Worker

    resilient do
      timeout 30.seconds
      circuit_breaker threshold: 5, cooldown: 1.minute
      retry_policy max: 3, backoff: :exponential
    end

    def handle([:write, resource, changeset])
      @adapter.write(resource, changeset)
    end
  end

  Multi-store writes become explicit about failure modes:

  # Policy: audit log failure is logged but doesn't block primary
  resource User do
    store :primary, Sequel, required: true
    store :audit, JSONL, required: false, on_failure: :log_and_continue
  end

  4. Calculations as Live Aggregates

  Currently: calculated on each query. Long-running:

  # Maintained by supervised worker, eventually consistent
  resource User do
    calculation :post_count, :integer do
      # This becomes a subscription, not a query
      maintained_by :aggregate_worker
      rebuilds_from :chronica  # If corrupted, replay events
    end
  end

  The aggregate worker is supervised. If it crashes, it restarts and rebuilds from the event log.

  5. Schema Evolution Without Downtime

  This is particularly interesting. Currently:
  1. Detect changes → 2. Generate migration → 3. Downtime/blue-green → 4. Deploy

  Long-running internalized expand-contract:

  # Register new version alongside old
  Archema::Schema.evolve(User, to: UserV2) do
    # Both versions coexist during transition
    coexistence_policy :route_by_version

    # Background worker transforms old records
    migration_worker :background, batch_size: 1000

    # Deprecate old version when migration complete
    on_complete :deprecate_v1
  end

  No deploy boundary. The system manages its own evolution.

  6. Actions as Supervised Operations

  resource Order do
    action :process_payment do
      # This becomes a supervised task with saga semantics
      supervised :transient  # Only restart on abnormal exit

      step :authorize_payment
      step :reserve_inventory
      step :charge_payment
      step :confirm_order

      # Compensating actions if steps fail
      compensate :charge_payment, with: :refund_payment
      compensate :reserve_inventory, with: :release_inventory
    end
  end

  7. The Registry Becomes Essential

  From UMI's insight: in Ruby, Ractor refs aren't serializable. Names are the only way to persist references.

  # State that survives crashes stores names, not references
  class OrderProcessor
    def init(_)
      # NOT: { payment_worker: some_ractor }
      # YES: { payment_worker: :payment_service }
      { services: [:payment_service, :inventory_service] }
    end

    def handle([:process, order], state)
      # Lookup at use-time, survives restarts
      payment = Archema::Registry.lookup(state[:services][0])
      payment.call([:charge, order.total])
    end
  end

  Ash Features That Become Relevant

  | Feature        | Was "Out of Scope" Because...                      | Now Relevant Because...                                     |
  |----------------|----------------------------------------------------|-------------------------------------------------------------|
  | Domains        | Seemed like just namespace organization            | Each domain = supervised Application with failure isolation |
  | Notifiers      | Simple hooks seemed sufficient                     | Supervised async delivery with guaranteed processing        |
  | Reactors       | Multi-step workflows seemed like app-level concern | Sagas with checkpointing, compensation, resumption          |
  | Aggregates     | Computed on query is simpler                       | Live aggregates maintained by workers, rebuild from events  |
  | Manual Actions | Async seemed like app concern                      | Natural fit for supervised long-running tasks               |
  | Multitenancy   | Seemed like app-level routing                      | Per-tenant supervision trees, resource isolation            |

  The Consciousness Infrastructure Angle

  For the real use case (AXIOMATA, CHRONICA, MEMORATA, CONSORTIA):

  # Different failure policies for different criticality
  Archema::Domain.define :existence do
    # AXIOMATA: Core identity. Maximally paranoid.
    # Crash on any anomaly. Refuse updates unless perfect validation.
    resource Axiomata, resilience: :paranoid

    # CHRONICA: Immutable event log. Append-only, hash-chained.
    # Writer just keeps trying forever. Never loses events.
    resource Chronica, resilience: :persistent
  end

  Archema::Domain.define :memory do
    # MEMORATA: Can rebuild from CHRONICA if corrupted.
    # More tolerant of temporary failures.
    resource Memorata, resilience: :recoverable

    # CONSORTIA: Per-entity isolation.
    # One entity's corruption doesn't spread.
    resource Consortia, resilience: :isolated_per_entity
  end

  Open Questions for Discussion

  1. How much of this lives in Archema vs. UMI? Should Archema depend on UMI, or should these patterns be internalized?
  2. Incremental adoption path? Can we design so apps can start simple (one-shot) and progressively adopt long-running patterns?
  3. The hot-reload question: OTP has hot code loading. Ruby doesn't. Is "restart worker with new code" sufficient, or do we need something more?
  4. Event sourcing's role: Does CHRONICA become the primitive everything rebuilds from? That would be a significant architectural commitment.
  5. API surface: How do users configure resilience policies? Declarative DSL (like Ash)? External config? Both?

