---
description: Query multiple AI agents for diverse perspectives on a coding problem
argument-hint: [--file=path] [--providers=list] "question"
allowed-tools: Bash(*), Read, AskUserQuestion
---

<!--
Usage:
  /claude-council:ask "How should I structure authentication?"
  /claude-council:ask --providers=gemini,openai "Review this approach"
  /claude-council:ask --file=src/auth.ts "What's wrong with this implementation?"
-->

Query the council of AI coding agents to gather diverse perspectives.

## Pre-Query Interaction

Before querying, use AskUserQuestion in these scenarios:

### 1. Provider Selection (if --providers not specified)

First, discover which providers are available by checking for API keys:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --list-available 2>&1 | head -1
```

Or check environment variables directly:
- GEMINI_API_KEY set? → 🔵 Gemini available
- OPENAI_API_KEY set? → ⚪ OpenAI available
- GROK_API_KEY set? → 🔴 Grok available

**Only show available providers in the question.** If only 1 provider is available, skip the question and use it directly.

Example (if only Gemini and OpenAI are available):
```
Question: "Which AI providers should I consult?"
Header: "Providers"
Options (multiSelect: true):
  - 🔵 Gemini (gemini-3-flash-preview) - Google's fast reasoning model
  - ⚪ OpenAI (codex-mini-latest) - OpenAI's code-focused model
```

### 2. Clarify Ambiguous Questions
If the user's question is vague, broad, or could be interpreted multiple ways, ask for clarification.

Signs of ambiguity:
- Question lacks specific context (e.g., "What's the best approach?")
- Multiple valid interpretations exist
- Missing key details (language, framework, scale, constraints)

Example clarification:
```
Question: "What aspect should I focus the council's attention on?"
Header: "Focus"
Options:
  - Architecture & design patterns
  - Performance optimization
  - Security considerations
  - Code quality & maintainability
```

Skip these interactions if:
- User provided `--providers` flag (they already chose)
- Question is specific and clear
- Context from conversation already clarifies intent

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

Present each provider's response with prominent separators showing the model used.
Include the model name right-aligned in the header box.
Use dim gray (\033[2m) for box-drawing characters - easier on the eyes than bright white.

Default models (override via env vars):
- GEMINI_MODEL: gemini-3-flash-preview
- OPENAI_MODEL: codex-mini-latest
- GROK_MODEL: grok-4-1-fast-reasoning

Format: Use dim gray box characters. Pad the model name on the LEFT with spaces so the
total content width between ║ characters is exactly 78 characters. The provider name and
emoji go on the left, model name right-aligned.

**Color provider names** consistently throughout output:
- 🔵 **Gemini**: Always use blue text
- ⚪ **OpenAI**: Always use grey/dim text
- 🔴 **Grok**: Always use red text

This applies to headers, inline references, and synthesis. When mentioning a provider
(e.g., "Gemini suggests..." or "According to OpenAI..."), color the provider name.

Example with proper alignment:
```
╔══════════════════════════════════════════════════════════════════════════════╗
║  🔵 GEMINI                                          gemini-3-flash-preview   ║
╚══════════════════════════════════════════════════════════════════════════════╝
```
[Response from Gemini]

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  ⚪ OPENAI                                               codex-mini-latest   ║
╚══════════════════════════════════════════════════════════════════════════════╝
```
[Response from OpenAI]

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  🔴 GROK                                         grok-4-1-fast-reasoning   ║
╚══════════════════════════════════════════════════════════════════════════════╝
```
[Response from Grok]

IMPORTANT: Count characters carefully! The box is 80 chars wide (78 inside + 2 borders).
Pad with spaces between provider name and model to make total inner content exactly 78 chars.

## Synthesis

After presenting individual responses, provide a synthesis section with its own header box.

**Use green/cyan color for the synthesis box** to distinguish it from provider responses:

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  ⚡ SYNTHESIS                                                                ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

Use dim gray (\033[2m) for the box characters and cyan (\033[36m) for "SYNTHESIS".

### Use tables to summarize key points:

**Consensus & Divergence Table:**
| Topic | 🔵 Gemini | ⚪ OpenAI | 🔴 Grok | Consensus? |
|-------|----------|----------|--------|------------|
| Approach | ... | ... | ... | Yes/No |
| Technology | ... | ... | ... | Yes/No |

**Recommendation Summary:**
| Aspect | Recommended Approach | Supported By |
|--------|---------------------|--------------|
| ... | ... | 🔵 🔴 (2/3) |

### Synthesis content:
1. **Consensus**: Where multiple agents agree (use table above)
2. **Divergence**: Where agents disagree and why
3. **Unique insights**: Notable points from each provider (color provider names!)
4. **Recommendation**: Which approach seems strongest for this situation

Do NOT use horizontal rules (---) between sections. Use the box headers for visual separation.

If any providers failed, note the errors but continue with available responses.
