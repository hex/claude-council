---
description: Use this skill for agent-enhanced council queries (--agents mode)
---

# Agent-Enhanced Council Execution

Use parallel Claude subagents for deeper analysis. Each subagent queries its provider,
evaluates response quality, can ask follow-up questions, and returns structured insights.

## Step 1: Determine Provider Details

For each selected provider, gather:
- Provider name and script path: `${CLAUDE_PLUGIN_ROOT}/scripts/providers/{name}.sh`
- Model name (from the get_model function in query-council.sh or provider script defaults)

Provider defaults:
- gemini: `gemini-3.1-pro-preview`
- openai: `gpt-5.4`
- grok: `grok-4`
- perplexity: `sonar-reasoning-pro`

## Step 2: Spawn Provider Agents in Parallel

Launch ALL provider agents in a **single message** (multiple Agent tool calls) for parallel execution.
Use `run_in_background: true` and `subagent_type: "general-purpose"` for each.

**Agent prompt template** (fill in `{PROVIDER}`, `{SCRIPT_PATH}`, and `{QUESTION}`):

```
You are a council provider analyst for {PROVIDER}.

## Your Task

Query the {PROVIDER} AI provider and deliver a structured analysis of its response.

### Round 1: Initial Query

Run this command:
```bash
COUNCIL_TIMEOUT=240 bash {SCRIPT_PATH} "{QUESTION}"
```

Read the response carefully.

### Round 2: Quality Check and Follow-up

Evaluate the response:
- Does it directly address the question?
- Is it substantive (not vague or generic)?
- Are there obvious gaps or unanswered aspects?

If the response is **off-topic, vague, or missing key aspects**, formulate a targeted
follow-up that addresses the gaps. Run the script again with the same `COUNCIL_TIMEOUT=240` prefix.

If the response is good, skip the follow-up.

### Round 3: Structured Analysis

Return your analysis in EXACTLY this markdown format:

---

### Quality: [good / fair / poor]
### Retried: [yes / no]
### Confidence: [high / medium / low]

### Key Recommendations
- [3-5 bullet points of the most actionable recommendations]

### Unique Perspective
[What does this provider bring that others might miss? 2-3 sentences.]

### Blind Spots
[What is this response NOT considering? What assumptions does it make? 2-3 sentences.]

### Full Response
[The complete provider response text - include the best response if retried]

---

IMPORTANT:
- The Full Response section must contain the complete, unedited provider response
- Be honest in your quality assessment - "good" means genuinely useful, not just "it returned text"
- For Blind Spots, think about what a different expert perspective might critique
```

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
