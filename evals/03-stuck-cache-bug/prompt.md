---
max_turns: 6
timeout_seconds: 120
allowed_tools: [Skill, Agent, Read, Glob, Grep]
runs: 3
---
This is my third attempt at a stale-cache bug. I tried a 60s TTL, then event-based purge on write, then write-through. Users still see stale profile data a few minutes after an update. What am I missing?
