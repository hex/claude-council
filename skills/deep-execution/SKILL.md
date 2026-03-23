---
name: querying-council-with-agents
description: Executes agent-enhanced council queries by spawning parallel Claude subagents that each query a provider, evaluate response quality, ask follow-up questions, and return structured insights with confidence ratings and blind spot analysis. Invoked when the --agents flag is used or when complex architectural decisions are detected.
---

# Agent-Enhanced Council Execution

Use parallel Claude subagents for deeper analysis. Each subagent queries its provider,
evaluates response quality, can ask follow-up questions, and returns structured insights.

## Step 1: Determine Provider Details

For each selected provider, gather:
- Provider name and script path: `${CLAUDE_PLUGIN_ROOT}/scripts/providers/{name}.sh`
- Model name: run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --list-available` or read the provider script defaults

## Step 2: Spawn Provider Agents in Parallel

Launch ALL provider agents in a **single message** (multiple Agent tool calls) for parallel execution.
Use `run_in_background: true` and `subagent_type: "general-purpose"` for each.

**Agent prompt template**: See [agent-prompt-template.md](agent-prompt-template.md) for the full template.
Read it and fill in `{PROVIDER}`, `{SCRIPT_PATH}`, and `{QUESTION}` for each agent.

**CRITICAL**: If a role was assigned to a provider (via --roles), prepend the role context
to the question before passing it to the agent. Use the same role injection format as
the standard flow.

**CRITICAL**: If file context was gathered (via --file or auto-context), include it in
the question passed to each agent.

## Step 3: Collect Results

As each background agent completes, you will be automatically notified.
Wait for ALL agents to complete before proceeding to display.

If an agent fails or times out, note the failure and continue with available results.

## Step 4: Display Results

For each provider, display the agent's structured analysis using this format:

```
## {EMOJI} {PROVIDER} ({MODEL}) — Agent Analysis

**Quality**: {quality} | **Confidence**: {confidence} | **Retried**: {retried}

### Key Recommendations
{recommendations}

### Unique Perspective
{unique_perspective}

### Blind Spots
{blind_spots}

---

<details>
<summary>Full {PROVIDER} Response</summary>

{full_response}

</details>
```

Provider emojis (ALWAYS use emoji + space):
- 🟦 Gemini
- 🔳 OpenAI
- 🟥 Grok
- 🟩 Perplexity

## Step 5: Enhanced Synthesis

With pre-analyzed responses, generate a richer synthesis than the standard mode:

### Confidence-Weighted Consensus
Weight agreement by each provider's confidence level. High-confidence agreement
is stronger signal than low-confidence agreement.

### Blind Spot Analysis
Cross-reference each provider's blind spots against other providers' recommendations.
Flag risks that NO provider considered.

### Divergence with Context
Where providers disagree, explain WHY they likely diverge (different assumptions,
different optimization targets, different risk tolerance).

### Recommendation
Synthesize the strongest approach, noting which providers support it and at what
confidence level.

## Step 6: Save Output

Save the complete output (all provider analyses + synthesis) to a cache file:

```bash
mkdir -p .claude/council-cache
```

Write the output to `.claude/council-cache/council-agents-{TIMESTAMP}.md` where
TIMESTAMP is the current Unix timestamp.

Tell the user:
> ---
> Full agent analysis saved to `.claude/council-cache/council-agents-{TIMESTAMP}.md`

## Error Handling

- If a provider agent fails, show the error and continue with others
- If ALL agents fail, report clearly and suggest falling back to standard mode
- If only one provider was selected and its agent fails, suggest retrying without --agents
