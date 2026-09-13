---
max_turns: 25
timeout_seconds: 600
allowed_tools: [Skill, Agent, Read, Glob, Grep]
runs: 3
---
/claude-council:ask --local --roles=security,simplicity --no-auto-context "Should a CLI tool store its API keys in a dotfile in the home directory or in the OS keychain?"
