---
max_turns: 25
timeout_seconds: 900
allowed_tools: [Skill, Agent, Read, Glob, Grep]
runs: 3
---
/claude-council:ask --local --roles=security,dx --verbosity=detailed --no-auto-context "Our CLI caches provider answers by prompt hash. If the user switches the configured model, a cached answer from the old model is still served. What is the main risk, and how should cache keys and invalidation handle a model change?"
