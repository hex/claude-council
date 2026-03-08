# Persistence Layer for a Real-Time Collaborative Editor

## Council Recommendation

This is a textbook case for consulting the council of AI agents. Choosing the persistence layer for a real-time collaborative editor has deep, long-term consequences across performance, operational complexity, data consistency, and scaling. Each option involves genuine tradeoffs that different experts will weigh differently.

Consider running:

```
/claude-council:ask "We're building a real-time collaborative editor (Google Docs clone) with a team of 4 SQL-comfortable backend engineers. We need to choose a persistence layer: PostgreSQL with LISTEN/NOTIFY, CockroachDB for horizontal scaling, or Redis with AOF persistence. What should we pick and why? Consider: operational text (CRDT/OT), presence/cursor data, document storage, undo history, and scaling trajectory."
```

This will gather opinions from Gemini, OpenAI, Grok, and Perplexity to compare approaches -- each may highlight different tradeoffs around consistency guarantees, operational burden, and real-time performance characteristics.

---

## My Initial Assessment

That said, here is my own analysis to get the conversation started.

### The real question you should be asking

Before choosing a database, you need to nail down your **concurrency model**: are you using Operational Transformation (OT) or CRDTs? This choice constrains your persistence requirements far more than team size or scaling ambitions.

- **OT** requires a central authority to serialize operations, which means strong consistency matters and a single-writer model is natural. PostgreSQL fits well here.
- **CRDTs** are designed for eventual consistency and can merge concurrent edits without coordination. This opens the door to Redis or distributed stores, but also makes PostgreSQL perfectly viable since CRDTs handle the hard part in the application layer.

### Option-by-option analysis

#### PostgreSQL with LISTEN/NOTIFY

**Strengths:**
- Your team already knows it. This is a massive advantage with only 4 engineers.
- LISTEN/NOTIFY provides pub/sub for real-time change propagation without an external message broker.
- JSONB columns handle flexible document structures well.
- Strong ACID guarantees simplify reasoning about document state.
- Mature ecosystem: connection pooling (PgBouncer), replication, backups, monitoring -- all well-understood.

**Weaknesses:**
- LISTEN/NOTIFY does not scale horizontally. It works through a single PostgreSQL instance. With read replicas, only the primary can send notifications.
- At high concurrency (hundreds of users in one document), LISTEN/NOTIFY can become a bottleneck. The notification payload is limited to 8KB.
- Horizontal write scaling requires sharding, which PostgreSQL does not provide natively.

**Verdict:** Strong choice if your scale target is tens of thousands of documents with tens of concurrent editors each. This covers most real-world collaborative editors outside of Google Docs itself.

#### CockroachDB

**Strengths:**
- SQL-compatible, so your team's skills transfer.
- Horizontal write scaling out of the box.
- Strong consistency with serializable isolation by default.
- Built-in geo-partitioning if you need multi-region.

**Weaknesses:**
- Higher latency per operation than PostgreSQL (distributed consensus on every write). For a real-time editor where sub-50ms latency matters, this is a real concern.
- Operational complexity is higher than a managed PostgreSQL instance. Your team of 4 will spend more time on infrastructure.
- No LISTEN/NOTIFY equivalent -- you will need a separate pub/sub system (Redis, NATS, or similar) anyway.
- Smaller ecosystem, fewer experts available to hire, less community knowledge for debugging.
- You are paying for horizontal scaling before you need it. YAGNI applies here.

**Verdict:** Premature optimization for most teams at this stage. If you genuinely expect millions of concurrent documents across multiple regions, revisit this. But you can migrate to CockroachDB later more easily than you can undo the operational complexity of adopting it too early.

#### Redis with AOF persistence

**Strengths:**
- Blazing fast reads and writes. Sub-millisecond latency.
- Native pub/sub for real-time change propagation.
- Redis Streams can provide ordered, durable event logs.
- Data structures like sorted sets and hashes map well to presence data (cursors, selections, active users).

**Weaknesses:**
- AOF persistence is not a substitute for a real database. It is a crash-recovery mechanism, not a durable storage system. Data loss windows exist even with `appendfsync always` (which also kills performance).
- No relational integrity, no complex queries, no joins. Reporting, auditing, and analytics become painful.
- Memory-bound storage. Your cost scales with working set size. Document history (undo/redo, version tracking) can eat memory fast.
- Redis Cluster has known limitations with pub/sub (messages are broadcast to all nodes).
- Your team's SQL skills are wasted.

**Verdict:** Excellent as a complementary layer, dangerous as your sole persistence layer. You do not want your source of truth for documents to be Redis.

### My recommendation

**PostgreSQL as primary store + Redis as real-time layer.** This is not a cop-out -- it is the architecture that Google Docs, Figma, and most successful collaborative editors converge on:

1. **PostgreSQL** stores documents, version history, user data, permissions, and provides your transactional backbone. Use JSONB for document content or a dedicated column for your CRDT/OT state.

2. **Redis** handles the hot path: presence data (who is online, cursor positions), pub/sub for broadcasting operations to connected clients, and short-lived operation buffering before flushing to PostgreSQL.

3. **WebSockets** (via something like Socket.IO or a lightweight custom layer) for client communication, backed by Redis pub/sub for multi-server fan-out.

This architecture lets each technology do what it is best at. PostgreSQL provides durability and queryability. Redis provides speed and real-time pub/sub. Your team stays productive in SQL-land for the core domain logic.

### Scaling trajectory

When you outgrow this setup (and you may never need to):

- **Step 1:** Add read replicas to PostgreSQL for read scaling.
- **Step 2:** Shard documents across PostgreSQL instances by document ID.
- **Step 3:** If you reach global scale, *then* evaluate CockroachDB or a purpose-built document store for the document data tier.

Most collaborative editors hit WebSocket connection limits and application-layer bottlenecks long before the database becomes the constraint. Invest your engineering time in your CRDT/OT implementation and WebSocket infrastructure first.

### One more thing

With 4 engineers, operational simplicity is not a nice-to-have -- it is a survival requirement. Every hour spent debugging CockroachDB clock skew or Redis memory fragmentation is an hour not spent on the product. PostgreSQL is boring in the best possible way.
