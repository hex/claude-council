---
name: deep-execution
description: Executes agent-enhanced council queries as one Workflow of parallel Claude analyst agents that each query a provider, evaluate response quality, ask follow-up questions, and return a schema-enforced analysis with confidence ratings and blind spot analysis. Invoked when the --agents flag is used or when complex architectural decisions are detected.
---

# Agent-Enhanced Council Execution

Run one Workflow of parallel Claude analyst agents for deeper analysis. Each analyst
queries its provider, evaluates response quality, can ask follow-up questions, and
returns a structured analysis that the workflow enforces against the schema.

## Step 1: Resolve Providers and Write the Questions

One shell call resolves what the workflow needs — each provider's model, its
role, and the question file it will send — with the same helpers the standard
flow uses. Paste the final question into the heredoc verbatim: the quoted
marker means the shell does NOT interpret quotes, backticks or `$()` in it.
The question is emitted once; each provider's role-injected variant is built
in shell, not pasted again.

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/providers.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/roles.sh"
PROVIDERS=(<the selected providers, space separated>)
ROLES="<the --roles value, or empty>"
RUN=$(date +%s)                                  # names this run's files; Step 6 reuses it
Q="$PWD/.claude/council-cache/.agents-$RUN"
mkdir -p "$PWD/.claude/council-cache"
# Self-ignoring, as cache.sh and run-council.sh keep it: these files carry the
# question and any --file contents, and must never land in a commit.
[[ -f "$PWD/.claude/council-cache/.gitignore" ]] || printf '*\n' > "$PWD/.claude/council-cache/.gitignore"
cat > "$Q.txt" <<'COUNCIL_Q_EOF'
<the question, verbatim>
COUNCIL_Q_EOF
# --file / auto-context: append the context to the question file here, e.g.
#   { printf '\n\nHere is the content of %s:\n\n```\n' "<path>"; cat "<path>"; printf '```\n'; } >> "$Q.txt"
# An unknown role is refused, as the standard flow refuses it; assigning it
# would hand that provider the bare question under a role heading.
[[ -z "$ROLES" ]] || validate_roles "$ROLES" || exit 1
ASSIGNMENTS=""
[[ -n "$ROLES" ]] && ASSIGNMENTS=$(assign_roles_to_providers "$ROLES" "${PROVIDERS[@]}")
echo "run $RUN"
for p in "${PROVIDERS[@]}"; do
    role=""
    [[ -n "$ASSIGNMENTS" ]] && role=$(get_provider_role "$p" "$ASSIGNMENTS")
    qf="$Q.txt"
    if [[ -n "$role" ]]; then
        qf="$Q-$p.txt"
        build_prompt_with_role "$(cat "$Q.txt")" "$role" > "$qf"
    fi
    printf '%s\t%s\t%s\n' "$p" "$(get_model "$p")" "$qf"
done
```

It prints the run id, then one line per provider: name, model (shown in the
Step 4 header), and the absolute path of that provider's question file.

## Step 2: Run the Analyst Workflow

Agent mode is one Workflow: one analyst agent per provider, in parallel, each
returning its analysis through schema-enforced structured output. The user
asked for agent mode (`--agents`, or yes to the prompt in ask.md Step 1.5),
which is the opt-in the Workflow tool requires.

If the Workflow tool is not available in this session, stop here: tell the
user that `--agents` needs a Claude Code with the Workflow tool, and offer to
run the same question in standard mode instead. Do not fall back to another
way of spawning agents.

Read `${CLAUDE_PLUGIN_ROOT}/schemas/agent-analysis.schema.json` with the Read
tool, then call the Workflow tool with this script, verbatim, via `script`:

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
const template = `${args.pluginRoot}/skills/deep-execution/agent-prompt-template.md`
// Single stage: there is no later step for a finished analyst to move on to,
// so the barrier costs nothing.
const results = await parallel(args.providers.map(p => () =>
  agent(
    `You are the council analyst for the provider "${p.name}".\n` +
    `Read ${template} and carry out every step in it, with these values:\n` +
    `- {PROVIDER} = ${p.name}\n` +
    `- {PLUGIN_ROOT} = ${args.pluginRoot}\n` +
    `- {QUESTION_FILE} = ${p.questionFile}\n` +
    `Your final answer is the Round 3 analysis object, returned through the structured output tool.`,
    { label: p.name, phase: 'Analyze', schema, agentType: 'general-purpose' })))
// parallel() keeps a dead or skipped analyst's slot as null, index-aligned with args.providers.
const failed = args.providers.filter((_, i) => !results[i]).map(p => p.name)
if (failed.length) log(`no analysis from: ${failed.join(', ')}`)
return {
  // The label goes last so an analyst that emits its own "provider" key cannot rename itself.
  analyses: results.map((a, i) => a && { ...a, provider: args.providers[i].name }).filter(Boolean),
  failed,
}
```

and these `args` (real JSON values, not a string; `pluginRoot` is the real
path of `${CLAUDE_PLUGIN_ROOT}`, `questionFile` the path Step 1 printed):

```json
{
  "pluginRoot": "<CLAUDE_PLUGIN_ROOT>",
  "schema": { "...the parsed schema file..." },
  "providers": [
    { "name": "gemini", "questionFile": "<absolute path from Step 1>" }
  ]
}
```

The workflow returns `{ analyses, failed }`. Every object in `analyses`
satisfies the schema; `failed` names the providers whose analyst died or was
skipped. A provider that returned an error is not in `failed`: its analyst
reports it as a `quality: poor`, `confidence: low` analysis whose
`full_response` is the error text (the template says so). Step 5 treats both
as the same thing — a provider that did not answer.

## Step 3: Read the Result

Nothing to validate: use each analysis's fields directly in Steps 4-5, and
carry `failed` into Step 5's provider failures.

## Step 4: Display Results

For each analysis, display it using this format. `{MODEL}` is the Step 1
model: a model-fallback re-run inside an analyst cannot change this header,
and the displacement is visible only in the analysis text.

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

With pre-analyzed responses, generate a richer synthesis than the standard mode.
The calibration rules in `${CLAUDE_PLUGIN_ROOT}/prompts/synthesis.md` apply here
too. Its "returned an error" case covers the providers in `failed` AND every
`quality: poor` analysis whose `full_response` is a provider error: name them
under failures and keep them out of consensus, whatever weight their
confidence field would give them.

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

Save the complete output (all provider analyses + synthesis) to
`.claude/council-cache/council-agents-{RUN}.md`, where RUN is the run id
Step 1 printed (the directory exists since Step 1). Then remove the run's
question files, which nothing prunes:

```bash
rm -f .claude/council-cache/.agents-{RUN}*
```

Tell the user:
> ---
> Full agent analysis saved to `.claude/council-cache/council-agents-{RUN}.md`

## Error Handling

- If a provider's analyst fails (it is listed in `failed`), say so and continue with the others
- If ALL analysts fail, report clearly and suggest falling back to standard mode
- If only one provider was selected and its analyst fails, suggest retrying without --agents
- A killed or interrupted workflow can be resumed: relaunch with the same args and the
  `scriptPath` and `resumeFromRunId` from the tool result; the finished analysts return from cache
