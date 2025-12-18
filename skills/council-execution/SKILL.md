---
description: Use this skill when executing council queries to display provider responses in text (not truncated terminal output)
---

# Council Query Execution

When running council queries, follow these rules to ensure responses are visible (not truncated by Claude Code's UI).

## Step 1: Run Query and Capture JSON

```bash
JSON=$(bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh $ARGUMENTS 2>/dev/null)
echo "$JSON" | jq -r '.round1 | keys[]'
```

This returns the JSON and lists which providers responded.

## Step 2: Extract and Display Each Response

For each provider, extract and display their response IN YOUR TEXT OUTPUT (not bash):

```bash
echo "$JSON" | jq -r '.round1.gemini.response'
echo "$JSON" | jq -r '.round1.openai.response'
```

## Step 3: Format in Your Response

Display each provider's response with bar-style headers in your message text:

```
━━━ 🔵 GEMINI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ gemini-3-flash-preview

[paste gemini response here]

━━━ ⚪ OPENAI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ codex-mini-latest

[paste openai response here]

━━━ ⚡ SYNTHESIS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[your synthesis here]
```

## Why This Approach

Claude Code's UI truncates long bash outputs (shows "+N lines ctrl+o to expand"). By extracting responses and displaying them in your text output, the full content is visible without expansion.

## Provider Colors

When writing headers:
- 🔵 GEMINI (blue)
- ⚪ OPENAI (white/gray)
- 🔴 GROK (red)
- ⚡ SYNTHESIS (cyan)

## Getting Model Names

```bash
echo "$JSON" | jq -r '.round1.gemini.model'
echo "$JSON" | jq -r '.round1.openai.model'
```

Include the model name in the header bar.
