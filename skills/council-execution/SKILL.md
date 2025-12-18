---
description: Use this skill when executing council queries
---

# Council Query Execution

## Run the Query

Execute with a single command:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --providers=gemini,openai "Your question" 2>/dev/null | bash ${CLAUDE_PLUGIN_ROOT}/scripts/format-output.sh
```

**Flag syntax**: Use `=` with no spaces: `--providers=gemini,openai`

## After Output

The terminal output may be truncated (shows "+N lines ctrl+o to expand"). Tell the user:

> Press **ctrl+o** to expand and see full provider responses.

Then generate your synthesis with:
- **Consensus**: Where providers agree
- **Divergence**: Where they disagree
- **Recommendation**: Best approach

## Provider Names

**ALWAYS use emoji when mentioning a provider:**
- 🔵 Gemini (not just "Gemini")
- ⚪ OpenAI (not just "OpenAI")
- 🔴 Grok (not just "Grok")

Example: "🔵 Gemini recommends using Redis, while ⚪ OpenAI suggests Memcached."
