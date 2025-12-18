---
description: Use this skill when executing council queries
---

# Council Query Execution

## Step 1: Run Query and Save to File

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --providers=gemini,openai "Your question" 2>/dev/null | bash ${CLAUDE_PLUGIN_ROOT}/scripts/format-output.sh > /tmp/council-output.txt
```

**Flag syntax**: Use `=` with no spaces: `--providers=gemini,openai`

## Step 2: Read and Display the Output

Use the **Read tool** to read `/tmp/council-output.txt` and display its contents in your response.

The file contains formatted provider responses with headers like:
```
━━━ 🔵 GEMINI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ gemini-3-flash-preview
[response text]

━━━ ⚪ OPENAI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ codex-mini-latest
[response text]

━━━ ⚡ SYNTHESIS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Step 3: Generate Synthesis

After displaying the provider responses, write your synthesis:
- **Consensus**: Where providers agree
- **Divergence**: Where they disagree
- **Recommendation**: Best approach

## Provider Names

**ALWAYS use emoji when mentioning a provider:**
- 🔵 Gemini
- ⚪ OpenAI
- 🔴 Grok
