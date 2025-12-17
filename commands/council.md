---
description: Query multiple AI agents for diverse perspectives on a coding problem
argument-hint: [--file=path] [--providers=list] "question"
allowed-tools: Bash(*), Read
---

<!--
Usage:
  /council "How should I structure authentication?"
  /council --providers=gemini,openai "Review this approach"
  /council --file=src/auth.ts "What's wrong with this implementation?"
  /council --file=src/api.ts --providers=gemini "Review this code"
-->

Query the council of AI coding agents to gather diverse perspectives.

## Context Gathering

Before querying, gather relevant context:

1. **If `--file=path` specified**: Read the file contents using the Read tool
2. Summarize the problem or question being discussed
3. Include any relevant code snippets from conversation
4. Note any constraints or requirements mentioned

## Query Execution

Parse arguments from: $ARGUMENTS

Supported flags:
- `--file=path`: Include contents of specified file in the query
- `--providers=list`: Comma-separated list of providers to query (default: all)

Everything after flags is the question text.

Build a comprehensive prompt that includes:
1. The user's question
2. Relevant context from our conversation (code, constraints, goals)
3. Request for specific, actionable recommendations

Execute the query:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh [--providers=list] "compiled prompt"
```

## Response Presentation

Present each provider's response in a clear side-by-side format:

### Gemini
[Response from Gemini]

### OpenAI
[Response from OpenAI]

### Grok
[Response from Grok]

## Synthesis

After presenting individual responses:
1. Highlight areas of consensus (where multiple agents agree)
2. Note interesting divergences (where agents disagree)
3. Identify unique insights from each perspective
4. Recommend which approach seems strongest for this specific situation

If any providers failed, note the errors but continue with available responses.
