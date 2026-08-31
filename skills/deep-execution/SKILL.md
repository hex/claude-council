---
name: deep-execution
description: Executes agent-enhanced council queries as one Workflow of parallel Claude analyst agents that each query a provider, evaluate response quality, ask follow-up questions, and return a schema-enforced analysis with confidence ratings and blind spot analysis. Invoked when the --agents flag is used or when complex architectural decisions are detected.
---

# Agent-Enhanced Council Execution

Run one Workflow of parallel Claude analyst agents for deeper analysis. Each analyst
queries its provider, evaluates response quality, can ask follow-up questions, and
returns a structured analysis that the workflow enforces against the schema.

## Step 1: Determine Provider Details

For each selected provider, gather:
- Provider name and script path: `${CLAUDE_PLUGIN_ROOT}/scripts/providers/{name}.sh`
- Model name: run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --list-available` or read the provider script defaults

## Step 2: Prepare the Question and the Schema

Write the final question — with the role injected and any file context included
— to a file the analysts will read. A quoted heredoc marker means the shell
does NOT interpret quotes, backticks or `$()` in the question; paste it
verbatim, do not escape it:

```bash
mkdir -p .claude/council-cache
cat > .claude/council-cache/.agents-question.txt <<'COUNCIL_Q_EOF'
<the final question, verbatim>
COUNCIL_Q_EOF
```

**CRITICAL**: If a role was assigned to a provider (via --roles), build the
role-injected question with the same helper the standard flow uses — source
`scripts/lib/prompts.sh` and `scripts/lib/roles.sh`, then
`build_prompt_with_role "<question>" "<role>"` — and write ITS output to the
file. Roles differ per provider, so write one file per provider in that case
(`.agents-question-<provider>.txt`) and pass each provider its own path. The
role format itself is defined in `${CLAUDE_PLUGIN_ROOT}/prompts/role-injection.md`.

**CRITICAL**: If file context was gathered (via --file or auto-context), it
belongs in the question file too.

Read `${CLAUDE_PLUGIN_ROOT}/schemas/agent-analysis.schema.json` with the Read
tool; its parsed content is passed to the workflow as `args.schema`, where it
becomes each analyst's enforced output contract.

## Step 3: Run the Analyst Workflow

Agent mode runs as one Workflow: one analyst agent per provider, all in
parallel, each returning its analysis through the schema-enforced structured
output — so no reply ever reaches this context as raw text that has to be
pasted and validated. The user asked for agent mode (`--agents`, or yes to the
prompt in ask.md Step 1.5), which is the opt-in the Workflow tool requires.

If the Workflow tool is not available in this session, stop here: tell the
user that `--agents` needs a Claude Code with the Workflow tool, and offer to
run the same question in standard mode instead. Do not fall back to another
way of spawning agents.

Call the Workflow tool with this script, verbatim, via `script`:

```js
export const meta = {
  name: 'council-agents',
  description: 'One analyst per council provider: query it, judge the answer, follow up, return a structured analysis',
  phases: [{ title: 'Analyze', detail: 'one analyst agent per provider, in parallel' }],
}
// The tool's schema validator does not know the draft-2020-12 dialect the
// file declares; without the declaration it validates the same keywords fine.
const schema = { ...args.schema }
delete schema.$schema
// A barrier is right here: the synthesis that follows needs every analysis
// together, and there is no later stage for a finished analyst to move on to.
const analyses = await parallel(args.providers.map(p => () =>
  agent(
    `You are the council analyst for the provider "${p.name}".\n` +
    `Read ${args.templatePath} and carry out every step in it, with these values:\n` +
    `- {PROVIDER} = ${p.name}\n` +
    `- {SCRIPT_PATH} = ${p.script}\n` +
    `- {QUESTION_FILE} = ${p.questionFile}\n` +
    `- {SCHEMA_PATH} = ${args.schemaPath}\n` +
    `Your final answer is the Round 3 analysis object, returned through the structured output tool.`,
    { label: p.name, phase: 'Analyze', schema, agentType: 'general-purpose' }
  ).then(a => a && { provider: p.name, model: p.model, ...a })))
const done = analyses.filter(Boolean)
const failed = args.providers.map(p => p.name).filter(n => !done.some(a => a.provider === n))
if (failed.length) log(`no analysis from: ${failed.join(', ')}`)
return { analyses: done, failed }
```

and these `args` (real JSON values, not a string):

```json
{
  "providers": [
    { "name": "gemini", "script": "<CLAUDE_PLUGIN_ROOT>/scripts/providers/gemini.sh",
      "model": "<model from Step 1>", "questionFile": "<absolute path to the question file>" }
  ],
  "templatePath": "<CLAUDE_PLUGIN_ROOT>/skills/deep-execution/agent-prompt-template.md",
  "schemaPath": "<CLAUDE_PLUGIN_ROOT>/schemas/agent-analysis.schema.json",
  "schema": { "...the parsed schema file..." }
}
```

Expand `<CLAUDE_PLUGIN_ROOT>` to the real path before calling, and pass every
path absolute — the analysts run in their own contexts. The workflow
returns `{ analyses, failed }`: every object in `analyses` already satisfies the
schema (an analyst that could not produce one is retried by the tool, and one
that died or was skipped is simply absent), so there is nothing to validate
here. Name each provider in `failed` under the provider failures in Step 5,
and continue with the analyses that arrived.

## Step 4: Display Results

For each provider with a valid analysis, display it using this format:

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
is stronger signal than low-confidence agreement — but only about the reasoning,
never about the premises. Every provider read the same description of a system
none of them can inspect, so confident unanimity can equally mean the question
asserted something false and each provider reasoned from it correctly. When
agreement is both broad and confident, say so and then name the premise the
whole answer rests on, and whether anyone was in a position to check it.

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

- If a provider's analyst fails (it is listed in `failed`), say so and continue with the others
- If ALL analysts fail, report clearly and suggest falling back to standard mode
- If only one provider was selected and its analyst fails, suggest retrying without --agents
- A killed or interrupted workflow can be resumed: relaunch with the same script and args plus
  `resumeFromRunId` from the tool result, and the finished analysts return from cache
