---
description: Use this skill when executing council queries to ensure correct bash pipeline and verbatim output display
---

# Council Query Execution

When running council queries, follow these rules exactly.

## The Pipeline

ALWAYS use this exact command:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh $ARGUMENTS 2>/dev/null | bash ${CLAUDE_PLUGIN_ROOT}/scripts/format-output.sh
```

Where `$ARGUMENTS` includes the user's question and any flags.

## Output Rules

1. **Show output VERBATIM** - Display the exact terminal output without reformatting, summarizing, or recreating
2. **Provider responses come first** - Each provider's response appears with a bar header
3. **Synthesis header appears last** - The `SYNTHESIS` header marks where you add your analysis

## Header Format

The formatter outputs bar-style headers:

```
━━━ 🔵 GEMINI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ gemini-3-flash-preview
[provider response here]

━━━ ⚪ OPENAI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ codex-mini-latest
[provider response here]

━━━ ⚡ SYNTHESIS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## After Displaying Output

Only AFTER showing the verbatim output, generate your synthesis analyzing:
- **Consensus**: Where providers agree
- **Divergence**: Where they disagree and why
- **Recommendation**: Strongest approach for the situation

## Common Mistakes to Avoid

- Do NOT capture output to a variable then echo it
- Do NOT recreate or reformat the headers yourself
- Do NOT summarize provider responses instead of showing them
- Do NOT skip showing the formatted output before synthesis
