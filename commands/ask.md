---
description: Query multiple AI agents for diverse perspectives on a coding problem
argument-hint: [--file=path] [--providers=list] [--roles=list] [--debate] [--output=path] [--quiet] [--no-cache] [--no-auto-context] "question"
allowed-tools: Bash(*), Read, Glob, Grep, AskUserQuestion, TaskCreate, TaskUpdate
---

Query the council of AI coding agents to gather diverse perspectives.

## Progress Tracking

Create a task at the start to show progress throughout the query:

```
TaskCreate:
  subject: "Query council"
  description: "Querying AI providers for diverse perspectives"
  activeForm: "Preparing council query..."

TaskUpdate: status → in_progress
```

Update `activeForm` as you progress through phases:
- `"Gathering context..."` - during auto-context detection
- `"Querying council providers..."` - during query-council.sh execution
- `"Formatting responses..."` - during format-output.sh execution
- `"Synthesizing recommendations..."` - during synthesis generation

Mark `status → completed` when finished.

## Pre-Query Interaction

Before querying, use AskUserQuestion in these scenarios:

### 1. Provider Selection (if --providers not specified)

First, discover available providers:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --list-available 2>&1 | head -1
```

**Only show available providers in the question.** If only 1 provider is available, skip and use it directly.

Example (if Gemini and OpenAI available):
```
Question: "Which AI providers should I consult?"
Header: "Providers"
Options (multiSelect: true):
  - Gemini (gemini-3-flash-preview) - Google's fast reasoning model
  - OpenAI (gpt-5.2-codex) - OpenAI's code-focused model
```

### 2. Clarify Ambiguous Questions

If the question is vague or could be interpreted multiple ways, ask for clarification.

**Skip these interactions if:**
- User provided `--providers` flag
- Question is specific and clear
- Context from conversation already clarifies intent

## Step 1: Auto-Context Detection

Unless `--no-auto-context` or `--file=` is in $ARGUMENTS, detect and include relevant files:

1. Extract keywords from the question (function names, domain terms, file patterns)
2. Search with Glob and Grep for matching files (max 5 files, ~10,000 tokens)
3. If relevant files found, show: `Auto-included context (N files): [list]`
4. Append file contents to the prompt sent to providers

Skip auto-context if:
- `--no-auto-context` is specified
- `--file=` is specified (explicit context)
- Question doesn't reference code concepts

## Step 2: Execute and Display

**CRITICAL - Flag Syntax**: All script flags use `=` with NO spaces:
- CORRECT: `--providers=gemini,openai`
- WRONG: `--providers "gemini,openai"`
- WRONG: `--providers gemini,openai`

**Invoke the `council-execution` skill** and follow its instructions to run the query pipeline and display output.

## Step 3: Generate Synthesis

After the formatted output, generate synthesis analyzing the provider responses:

1. **Consensus**: Points where providers agree
2. **Divergence**: Where they disagree and why
3. **Unique insights**: Notable points from each provider
4. **Recommendation**: Strongest approach for the situation

### If Debate Mode Was Used

Additionally include:
- **Strongest criticisms**: Most compelling points from rebuttals
- **Consensus shifts**: Where providers changed positions
- **Unresolved tensions**: Remaining disagreements

## Step 4: Export (if --output specified)

If `--output=<path>` was specified:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/lib/export.sh --write "<output_path>" "<prompt>" "<providers>"
```

Confirm: `Exported to: <output_path>`

## Error Handling

- If query-council.sh fails, show the error message
- If some providers fail, note errors but continue with available responses
- If all providers fail, report the failure clearly
