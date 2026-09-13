---
max_turns: 25
timeout_seconds: 600
allowed_tools: [Skill, Agent, Read, Glob, Grep]
runs: 3
---
Convene the local council on this, with the scalability, devil's advocate and maintainability lenses, and keep each perspective brief: we want to move a 40-table PostgreSQL OLTP database to an event-sourced architecture without downtime. How should we sequence the migration, and what ordering guarantees do we need across the event streams?
