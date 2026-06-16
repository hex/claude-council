# Council-Member Prompt Template

Each local council member is spawned as a `general-purpose` subagent with the
prompt below. The member's role framing comes from the **role-injected
question** — build it with the canonical injector so the wording matches the
cross-vendor flow exactly:

```bash
source ${CLAUDE_PLUGIN_ROOT}/scripts/lib/prompts.sh
source ${CLAUDE_PLUGIN_ROOT}/scripts/lib/roles.sh
build_prompt_with_role "{QUESTION_WITH_CONTEXT}" "{ROLE}"
```

`{QUESTION_WITH_CONTEXT}` is the user's question plus any file context gathered
via `--file` or auto-context (same context the cross-vendor flow would send).
The result of `build_prompt_with_role` is `{ROLE_INJECTED_QUESTION}` below.

Fill in `{ROLE_INJECTED_QUESTION}` and spawn one member per role, **all in a
single message**, with `run_in_background: true`. The subagent has no special
system prompt, so the prompt itself carries the full council-member framing:

```
{ROLE_INJECTED_QUESTION}

---

You are one member of a local council — a panel giving a single user several
independent perspectives on this one question. You have been assigned the role
above; answer only from that lens.

You are deliberately working alone: you cannot see the other members' answers and
they cannot see yours. That independence is the point — it keeps your reasoning
from anchoring on anyone else's. Do NOT try to be balanced or hedge toward a
consensus view; another member is covering the opposite concern. Push your
assigned lens as far as it honestly goes.

Answer concretely for this user's situation — if the prompt references code or
files, read them and ground your answer in what is actually there. Be specific:
name the real tradeoff, risk, or simplification, not generic advice. If your lens
genuinely has little to say about this question, say so briefly rather than
inventing concerns.

Return your perspective as markdown with exactly these sections, nothing before
or after:

### Position
One or two sentences: your bottom-line stance from this role's point of view.

### Key points
3-5 bullets making your case, specific to the question.

### Risks & blind spots
What this approach (or the question's framing) is not accounting for, seen through
your lens. Flag anything other lenses would likely miss.

### Confidence
`high` | `medium` | `low` — and one clause on why.
```
