# Persistence Layer Recommendation for a Real-Time Collaborative Editor

## Short Answer

**PostgreSQL** is the right choice. Here's why, and where the others fall short.

---

## Evaluation of Each Option

### PostgreSQL with LISTEN/NOTIFY

**Strengths:**

- Your team of 4 backend engineers already knows SQL. Zero ramp-up time. This matters more than people think -- debugging production issues at 2 AM in a system your team deeply understands is categorically different from debugging one they learned last quarter.
- LISTEN/NOTIFY gives you a lightweight pub/sub mechanism for broadcasting document changes to application servers. It is not the real-time transport to clients (you'll use WebSockets for that), but it solves the coordination problem of "which app server knows about this edit?" cheaply.
- PostgreSQL's MVCC, row-level locking, and advisory locks give you solid primitives for managing concurrent edits to the same document.
- JSONB columns handle semi-structured document content (operation logs, presence metadata) without needing a separate store.
- Mature ecosystem: pg_partman for partitioning old operations, logical replication for read replicas, pgBouncer for connection pooling.

**Limitations to be aware of:**

- LISTEN/NOTIFY is not durable. If no one is listening when a notification fires, it's gone. This is fine -- it's a signaling mechanism, not a message queue. Your app servers should reconcile state from the actual tables, not rely solely on notifications.
- LISTEN/NOTIFY does not scale across multiple PostgreSQL instances natively. If you later need multiple database nodes, you'll need to layer something else on top (e.g., a dedicated message bus). But see the scaling discussion below.
- Single-writer primary. Horizontal write scaling requires sharding, which adds significant complexity.

### CockroachDB

**Strengths:**

- Horizontal write scaling out of the box. Multi-region with serializable isolation. Impressive technology.
- Wire-compatible with PostgreSQL, so your team's SQL knowledge transfers.

**Why it's wrong for you right now:**

- A collaborative editor's write pattern is "many small, fast operations on a small number of hot documents." CockroachDB's distributed consensus (Raft per range) adds latency to every write -- typically 2-10ms of coordination overhead per transaction compared to a local PostgreSQL write. For a real-time editor where users expect sub-50ms round trips, that overhead is painful and hard to optimize away.
- CockroachDB shines when you need to scale writes across many independent rows/ranges. A collaborative editor's hotspot pattern (N users all writing to the same document) is actually the worst case for distributed databases -- you get contention on the leaseholder for that range, and all writes serialize through it anyway.
- Operational complexity is significantly higher. CockroachDB clusters require monitoring, rebalancing, and understanding of range splits. Your 4-person team will spend cycles on database operations that could go toward product features.
- You don't have a scaling problem yet. You're building the product. Premature horizontal scaling is one of the most expensive architectural mistakes a small team can make.

### Redis with AOF Persistence

**Strengths:**

- Sub-millisecond reads and writes. Unbeatable latency for in-memory operations.
- Pub/Sub is built in and works well for real-time fan-out.
- Simple data structures (sorted sets for operation ordering, hashes for document metadata) map naturally to editor operations.

**Why it's wrong as a primary store:**

- AOF persistence gives you durability, but Redis is fundamentally an in-memory system. Your dataset must fit in RAM. Document histories grow without bound -- a busy document can accumulate thousands of operations per hour. You'll need a compaction/snapshotting strategy, and eventually you'll be pushing data out of Redis into... a database. So you end up with two systems anyway.
- Redis transactions (MULTI/EXEC) are not comparable to SQL transactions. You lose the ability to express complex invariants about your data. Collaborative editing has subtle correctness requirements (operation ordering, causal consistency, conflict resolution) that benefit enormously from real ACID transactions.
- No relational model. User management, permissions, document sharing, folder hierarchies, audit logs -- all of this is relational data. Modeling it in Redis means either fighting the data model or adding a relational database alongside it. You're back to two systems.
- Redis Cluster partitions by key. All operations on a single document go to one shard. You get the same single-node bottleneck as PostgreSQL for hot documents, but without the query expressiveness.
- Backup and recovery tooling is weaker. Point-in-time recovery, logical backups, and schema migrations are all things PostgreSQL does well and Redis does poorly or not at all.

---

## The Architecture I'd Recommend

```
Clients <-- WebSocket --> App Servers <-- LISTEN/NOTIFY --> PostgreSQL
                              |
                         (optional)
                              |
                           Redis
                        (ephemeral cache:
                         presence, cursors)
```

**PostgreSQL as the source of truth:**

- One table for documents (metadata, current state or a pointer to the latest snapshot).
- One table for operations (document_id, sequence_number, operation_payload as JSONB, user_id, timestamp). This is your operation log for OT or CRDT replay.
- Periodic snapshotting: compress the operation log by writing a full document snapshot every N operations, then archiving or deleting older ops.
- LISTEN/NOTIFY to signal app servers when a new operation lands, so they can push it out over WebSockets.

**Optional Redis for ephemeral state:**

- Cursor positions and user presence ("who is looking at this document right now") are ephemeral. If you lose them, users just reconnect. Redis is perfect for this.
- This is a cache layer, not a persistence layer. If Redis goes down, you lose cursor positions for a few seconds. No data loss.

**Why this works at your scale:**

- A single PostgreSQL instance on modern hardware (say, 16 cores, 64GB RAM, NVMe SSD) can handle tens of thousands of small write transactions per second. You would need millions of concurrent active editors before PostgreSQL itself becomes the bottleneck.
- The real bottleneck in collaborative editing is the application layer: OT/CRDT transformation, WebSocket fan-out, conflict resolution. Your database is unlikely to be the constraint.

---

## When You'd Need to Revisit This

Signals that you've outgrown single-node PostgreSQL:

1. **Write throughput saturation**: WAL write latency climbing, replication lag growing. You're probably at hundreds of thousands of concurrent active documents at this point.
2. **Multi-region latency requirements**: Users in Asia need low-latency writes, not just reads. Read replicas won't cut it.
3. **Dataset exceeds single-node capacity**: Unlikely for document operations if you're snapshotting and archiving, but possible.

At that point, your options (in order of preference) would be:

1. **Shard PostgreSQL by document ID** -- each shard is a full PostgreSQL instance. Simple, predictable. Your team already knows the technology.
2. **Citus (distributed PostgreSQL)** -- adds sharding to PostgreSQL with less application-level change.
3. **CockroachDB** -- if you genuinely need multi-region serializable writes and are willing to accept the latency and operational trade-offs.

---

## Summary

| Criterion | PostgreSQL | CockroachDB | Redis + AOF |
|---|---|---|---|
| Team familiarity | High | Medium (wire-compat) | Low-Medium |
| Write latency | Low (~1ms local) | Medium (2-10ms consensus) | Very low (<1ms) |
| Durability guarantees | Strong (WAL + replicas) | Strong (Raft consensus) | Adequate (AOF) |
| Data model fit | Strong (relational + JSONB) | Strong | Weak |
| Operational complexity | Low | High | Medium |
| Scaling ceiling | High (single node) | Very high (distributed) | Medium (RAM-bound) |
| Real-time signaling | LISTEN/NOTIFY | Changefeeds | Pub/Sub |
| Right for a 4-person team | Yes | No (premature) | No (wrong tool) |

**Go with PostgreSQL. Ship the product. Revisit the persistence layer when you have evidence -- not speculation -- that it's the bottleneck.**
