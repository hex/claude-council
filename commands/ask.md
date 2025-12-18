---
description: Query multiple AI agents for diverse perspectives on a coding problem
argument-hint: [--file=path] [--providers=list] [--roles=list] [--debate] [--output=path] [--quiet] [--no-cache] [--no-auto-context] "question"
allowed-tools: Bash(*), Read, Glob, Grep
---

## Step 1: Auto-Context Detection

Unless `--no-auto-context` or `--file=` is specified, detect relevant files:

1. Extract keywords from the question (function names, file patterns)
2. Search with Glob/Grep for matching files (max 5 files)
3. If found, show: `Auto-included context: [list]`
4. Add `--file=<path>` for each to the arguments

Skip if question doesn't reference code concepts.

## Step 2: Execute and Display

Run this command and display output VERBATIM (preserve ALL formatting, colors, bar characters):

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh $ARGUMENTS 2>/dev/null | bash ${CLAUDE_PLUGIN_ROOT}/scripts/format-output.sh
```

IMPORTANT: Show the exact terminal output. Do not reformat, summarize, or recreate the headers.

## Step 3: Synthesis

After the verbatim output, generate synthesis:

**If single provider**: Brief 1-2 sentence summary.

**If multiple providers**:
1. **Consensus**: Where they agree
2. **Divergence**: Where they disagree and why
3. **Recommendation**: Strongest approach for the situation

**If debate mode** (--debate): Also note strongest criticisms and any position shifts.

## Step 4: Export

If `--output=<path>` was specified, run:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/lib/export.sh --write "<path>" "<question>" "<providers>"
```

Confirm: `Exported to: <path>`

## Error Handling

- If script fails, show the error message
- If some providers fail, continue with available responses
- If all fail, report clearly
