# Project Commands
Auto-discovered CLI commands from prior sessions.


## Dev
- `git remote -v 2>/dev/null; echo "---"; git log --oneline -5 2>/dev/null; echo "---"; git tag --list 2>/dev/null | tail -5` -- [1x, last: 2026-04-08]
- `curl -s "https://api.perplexity.ai/models" 2>/dev/null | head -100` -- [1x, last: 2026-04-08]
- `curl -s "https://docs.perplexity.ai/docs/model-cards" 2>/dev/null | head -200` -- [1x, last: 2026-04-08]
- `curl -s "https://docs.x.ai/docs/models" -L --max-time 10 2>/dev/null | head -200 || echo "Failed to fetch docs"` -- [1x, last: 2026-04-08]
- `curl -s "https://api.x.ai/v1/models" -H "Authorization: Bearer ${XAI_API_KEY}" 2>/dev/null | jq '.' 2>/dev/null || echo "No XAI_API_KEY set or request failed"` -- [1x, last: 2026-04-08]
- `curl -s "https://openai.com/api/" 2>/dev/null | head -100` -- [1x, last: 2026-04-08]
- `curl -s "https://platform.openai.com/docs/models" 2>/dev/null | head -200` -- [1x, last: 2026-04-08]
- `curl -s "https://ai.google.dev/gemini-api/docs/models" 2>/dev/null | head -200 || echo "Could not fetch"` -- [1x, last: 2026-04-08]
- `curl -s "https://generativelanguage.googleapis.com/v1beta/models" 2>/dev/null | head -100 || echo "No API key available"` -- [1x, last: 2026-04-08]

## Other
- `git push -u origin main && git push --tags` -- [1x, last: 2026-04-08]
- `git tag -d v2026.3.5` -- [1x, last: 2026-04-08]
- `find /Users/hex/.claude-sessions/claude-council -maxdepth 3 -not -path '*/.git/*' | sort` -- [1x, last: 2026-04-08]
- `git add scripts/providers/grok.sh scripts/providers/openai.sh scripts/check-status.sh README.md` -- [1x, last: 2026-04-08]
- `git reset HEAD -- . 2>&1` -- [1x, last: 2026-04-08]
- `git checkout origin/main -- . 2>&1` -- [1x, last: 2026-04-08]
- `git fetch origin 2>&1` -- [1x, last: 2026-04-08]
- `git init && git remote add origin https://github.com/hex/claude-council.git` -- [1x, last: 2026-04-08]

## Test
- `grep -c "@test" /Users/hex/.claude-sessions/claude-council/tests/cache.bats /Users/hex/.claude-sessions/claude-council/tests/roles.bats /Users/hex/.claude-sessions/claude-council/tests/query-council.bats` -- [1x, last: 2026-04-08]
