---
name: council-execution
description: Executes council queries by running the query pipeline across selected AI providers (Gemini, OpenAI, Grok, Perplexity), displaying formatted responses verbatim, and generating a synthesis of consensus, divergence, and recommendations. Invoked by the ask command during standard (non-agent) council queries.
---

# Council Query Execution

## Step 1: Run Query and Save to File

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-council.sh --providers=gemini,openai -- "Your question"
```

This outputs the path to the saved file (e.g., `.claude/council-cache/council-1734567890.md`).

**Flag syntax**: Use `=` with no spaces: `--providers=gemini,openai`

**Pass only the flags the user asked for.** Never add `--no-pane`, `--quiet`,
`--no-cache` or `--no-auto-context` on your own judgment; they are the user's
to choose, and the script already skips a pane that cannot open.

**CRITICAL**: Always place `--` before the prompt to prevent prompt text containing dashes from being parsed as flags.

**Run this Bash call with `timeout: 600000`** (ten minutes). The Bash tool's
two-minute default is shorter than a slow council round, and inside tmux a
provider failure makes the streaming pane offer the user a retry for
`COUNCIL_RETRY_WAIT` seconds (default 45) and then runs another provider round
if accepted. A call cut off mid-run loses the whole transcript, the answers
that did arrive included.

## Step 2: Read and Display the Output VERBATIM

Use the **Read tool** to read the output file path returned by Step 1.

**If the file's first line is `<!-- council: round 1 was shown in the pane -->`**,
the user already read every round-1 answer in the streaming pane. Do not
reprint them. Instead, output one line per provider in round 1, taken from
its `## ` header (name, role, model, and any fallback note) followed by
`answered` or the `Error:` line under it. Then display VERBATIM the rest of
the file from its `## Round 2` heading, or from `## Synthesis` when there is no
round 2 (debate rebuttals never reach the pane), and continue with Step 3 under
the `## Synthesis` header. Without that first line, display the whole file as
below.

**CRITICAL**: Display the file content EXACTLY as written. Do NOT:
- Reformat or reinterpret any text
- Add your own headers or structure
- Summarize or abbreviate responses
- Skip any lines including separator lines (`---`)

Simply copy-paste the entire file content into your response.

## Step 3: Complete the Synthesis Section

The file ends with a `## Synthesis` header. Read
`${CLAUDE_PLUGIN_ROOT}/prompts/synthesis.md` and write your synthesis UNDER
that header following its structure (Consensus / Divergence / Recommendation)
and calibration rules.

## Step 4: Notify User of Saved Output

After displaying the synthesis, tell the user:

> ---
> (use this emoji 💾) Full output saved to `.claude/council-cache/council-TIMESTAMP.md` (use the actual filename)

This lets them review the complete responses later.

## Output Format: Provider Names

The output file uses emoji prefixes to visually distinguish providers.
Preserve this format when displaying results:

| Provider | Prefix |
|----------|--------|
| Gemini | 🟦 Gemini |
| OpenAI | 🔳 OpenAI |
| Grok | 🟥 Grok |
| Perplexity | 🟩 Perplexity |
