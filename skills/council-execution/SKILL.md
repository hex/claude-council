---
description: Use this skill when executing council queries
---

# Council Query Execution

## Step 1: Run Query and Save to File

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-council.sh --providers=gemini,openai -- "Your question"
```

This outputs the path to the saved file (e.g., `.claude/council-cache/council-1734567890.md`).

**Flag syntax**: Use `=` with no spaces: `--providers=gemini,openai`

**CRITICAL**: Always place `--` before the prompt to prevent prompt text containing dashes from being parsed as flags.

## Step 2: Read and Display the Output VERBATIM

Use the **Read tool** to read the output file path returned by Step 1.

**CRITICAL**: Display the file content EXACTLY as written. Do NOT:
- Reformat or reinterpret any text
- Add your own headers or structure
- Summarize or abbreviate responses
- Skip any lines including separator lines (`---`)

Simply copy-paste the entire file content into your response.

## Step 3: Complete the Synthesis Section

The file ends with a `## Synthesis` header. Write your synthesis UNDER that header:
- **Consensus**: Where providers agree
- **Divergence**: Where they disagree
- **Recommendation**: Best approach

## Step 4: Notify User of Saved Output

After displaying the synthesis, tell the user:

> ---
> (use this emoji 💾) Full output saved to `.claude/council-cache/council-TIMESTAMP.md` (use the actual filename)

This lets them review the complete responses later.

## Provider Names

**ALWAYS use emoji + space when mentioning a provider:**
- 🟦 Gemini (blue square)
- 🔳 OpenAI (white square button)
- 🟥 Grok (red square)
- 🟩 Perplexity (green square)

Format: `🟦 Gemini` not `🟦Gemini` - always include the space.
