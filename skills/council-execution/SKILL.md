---
description: Use this skill when executing council queries to display provider responses in text (not truncated terminal output)
---

# Council Query Execution

When running council queries, follow these rules to ensure responses are visible.

## Step 1: Run Query and Save to File

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --providers=gemini,openai "Your question" > /tmp/council.json 2>/dev/null
```

**IMPORTANT flag syntax**: Use `=` with no spaces:
- Correct: `--providers=gemini,openai`
- Wrong: `--providers gemini,openai`

## Step 2: Extract Responses

Extract each provider's response:

```bash
jq -r '.round1.gemini.response' /tmp/council.json
```

```bash
jq -r '.round1.openai.response' /tmp/council.json
```

Get model names:
```bash
jq -r '.round1.gemini.model' /tmp/council.json
jq -r '.round1.openai.model' /tmp/council.json
```

## Step 3: Display in Your Response

Write the responses in your message with bar-style headers:

```
━━━ 🔵 GEMINI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ model-name

[gemini response]

━━━ ⚪ OPENAI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ model-name

[openai response]

━━━ ⚡ SYNTHESIS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[your synthesis]
```

## Why This Approach

Claude Code's UI truncates long bash outputs. By extracting responses and writing them in your text output, the full content is visible.

## Provider Emojis

- 🔵 GEMINI
- ⚪ OPENAI
- 🔴 GROK
- ⚡ SYNTHESIS
