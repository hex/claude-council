---
max_turns: 6
timeout_seconds: 120
allowed_tools: [Skill, Agent, Read, Glob, Grep]
runs: 3
---
I lean towards Redis Streams over Kafka for a job queue that peaks around 2,000 messages a second, with one small ops team. Check with grok before I commit.
