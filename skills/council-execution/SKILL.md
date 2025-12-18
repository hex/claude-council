---
description: Use this skill when executing council queries
---

# Council Query Execution

## Step 1: Run the Query

Execute this command:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --providers=gemini,openai "Your question" 2>/dev/null | bash ${CLAUDE_PLUGIN_ROOT}/scripts/format-output.sh
```

**Flag syntax**: Use `=` with no spaces: `--providers=gemini,openai`

## Step 2: The Bash Output Contains Provider Responses

The bash command outputs formatted provider responses with headers like:
```
━━━ 🔵 GEMINI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ gemini-3-flash-preview
[response text]

━━━ ⚪ OPENAI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ codex-mini-latest
[response text]
```

**This IS the provider output.** If truncated, tell user: "Press **ctrl+o** to see full responses."

## Step 3: Generate Synthesis

AFTER the bash output is shown, write your synthesis:
- **Consensus**: Where providers agree
- **Divergence**: Where they disagree
- **Recommendation**: Best approach

## Provider Names

**ALWAYS use emoji when mentioning a provider:**
- 🔵 Gemini (not just "Gemini")
- ⚪ OpenAI (not just "OpenAI")
- 🔴 Grok (not just "Grok")

Example: "🔵 Gemini recommends using Redis, while ⚪ OpenAI suggests Memcached."
