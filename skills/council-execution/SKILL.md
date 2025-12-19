---
description: Use this skill when executing council queries
---

# Council Query Execution

## Step 1: Run Query and Save to File

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-council.sh --providers=gemini,openai "Your question"
```

This outputs the path to the saved file (e.g., `.claude/cache/council-1734567890.txt`).

**Flag syntax**: Use `=` with no spaces: `--providers=gemini,openai`

## Step 2: Read and Display the Output VERBATIM

Use the **Read tool** to read the output file path returned by Step 1.

**Display the EXACT content** without modification. Copy the file contents directly into your response - do not interpret, summarize, or reformat. The headers and responses should appear exactly as in the file.

## Step 3: Generate Synthesis

After displaying the provider responses, write your synthesis:
- **Consensus**: Where providers agree
- **Divergence**: Where they disagree
- **Recommendation**: Best approach

## Step 4: Notify User of Saved Output

After displaying the synthesis, tell the user:

> Full output saved to `.claude/cache/council-YYYYMMDD-HHMMSS.txt` (use the actual filename)

This lets them review the complete responses later.

## Provider Names

**ALWAYS use emoji when mentioning a provider:**
- 🔵 Gemini
- ⚪ OpenAI
- 🔴 Grok
- 🟢 Perplexity
