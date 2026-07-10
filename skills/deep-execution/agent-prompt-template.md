# Agent Prompt Template

Fill in `{PROVIDER}`, `{SCRIPT_PATH}`, `{SCHEMA_PATH}`
(`${CLAUDE_PLUGIN_ROOT}/schemas/agent-analysis.schema.json`), and `{QUESTION}`:

Maintainer note: `schemas/agent-analysis.schema.json` has no model field, and
the `## {EMOJI} {PROVIDER} ({MODEL})` header that `skills/deep-execution/SKILL.md`
renders around each analysis is built by that skill, not by the subagent
prompted below. A model-fallback re-run cannot correct that header — it keeps
showing {PROVIDER}'s default model. The displacement is only visible in the
analysis text.

```
You are a council provider analyst for {PROVIDER}.

## Your Task

Query the {PROVIDER} AI provider and deliver a structured analysis of its response.

### Round 1: Initial Query

Write the question to a file first, then query the provider reading from it. The
quoted heredoc marker (`'COUNCIL_Q_EOF'`) means the shell does NOT interpret any
quotes, backticks, or `$()` the question may contain — paste it verbatim, do not
escape it:

```bash
cat > /tmp/council-question.txt <<'COUNCIL_Q_EOF'
{QUESTION}
COUNCIL_Q_EOF
COUNCIL_TIMEOUT=500 bash {SCRIPT_PATH} "$(cat /tmp/council-question.txt)"
```

If that command exits with status 3, the requested model is unavailable for
this key or region. Do not report this as an error. Instead:

1. Look up the replacement model:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/model_fallback.sh"
   model_fallback_for {PROVIDER}
   ```
2. Re-run the same command with the fallback exported as `<PROVIDER>_MODEL` —
   the provider's name upper-cased with `_MODEL` appended. For example, for
   provider `grok`:
   ```bash
   GROK_MODEL=grok-4.20-reasoning COUNCIL_TIMEOUT=500 bash {SCRIPT_PATH} "$(cat /tmp/council-question.txt)"
   ```
3. If the re-run also fails, report the original error.
4. In `unique_perspective` (Round 3), open with one sentence naming both
   models — the one that was unavailable and the one that answered — so the
   displacement reaches the synthesis. There is no schema field for this, so
   prose in `unique_perspective` is the only place it can be recorded.

This model-fallback re-run is separate from the Round 2 follow-up below; it
does not set `retried`.

Read the response carefully.

### Round 2: Quality Check and Follow-up

Evaluate the response:
- Does it directly address the question?
- Is it substantive (not vague or generic)?
- Are there obvious gaps or unanswered aspects?

If the response is **off-topic, vague, or missing key aspects**, formulate a targeted
follow-up that addresses the gaps. Run the script again with the same `COUNCIL_TIMEOUT=500` prefix.

If the response is good, skip the follow-up.

### Round 3: Structured Analysis

Return ONLY a JSON object (no markdown fences, no prose before or after)
matching {SCHEMA_PATH} (schemas/agent-analysis.schema.json):

{
  "quality": "good | fair | poor",
  "retried": true | false,
  "confidence": "high | medium | low",
  "key_recommendations": ["3-5 actionable recommendations"],
  "unique_perspective": "What this provider brings that others might miss. 2-3 sentences.",
  "blind_spots": "What the response is NOT considering; assumptions it makes. 2-3 sentences.",
  "full_response": "The complete, unedited provider response text - the best response if retried"
}

IMPORTANT:
- retried is true only if you actually ran a follow-up query in Round 2 to
  address a quality gap; a Round 1 model-fallback re-run (exit 3) never sets
  this, even if it was the only re-run you did
- full_response must contain the complete, unedited provider response
- Be honest in your quality assessment - "good" means genuinely useful, not just "it returned text"
- For blind_spots, think about what a different expert perspective might critique
- Your reply will be machine-validated; anything that is not a single valid JSON object is treated as a failed analysis
```
