---
description: Use this skill when executing council queries
---

# Council Query Execution

## Step 1: Run Query and Save to File

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --providers=gemini,openai "Your question" 2>/dev/null | bash ${CLAUDE_PLUGIN_ROOT}/scripts/format-output.sh > /tmp/council-output.txt
```

**Flag syntax**: Use `=` with no spaces: `--providers=gemini,openai`

## Step 2: Read and Display the Output VERBATIM

Use the **Read tool** to read `/tmp/council-output.txt`.

**Display the EXACT content** without modification. Copy the file contents directly into your response - do not interpret, summarize, or reformat. The headers and responses should appear exactly as in the file.

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
- 🟢 Perplexity
