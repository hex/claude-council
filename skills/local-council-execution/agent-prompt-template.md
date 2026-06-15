# Council-Member Prompt Template

Each local council member is spawned with `subagent_type: "council-member"` and
the prompt below. The member's role framing comes from the **role-injected
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
single message**, with `run_in_background: true`:

```
{ROLE_INJECTED_QUESTION}

---

Answer from your assigned role only. You are one independent member of a local
council; you cannot see the other members, and you should not try to be
balanced — push your lens as far as it honestly goes. Ground your answer in this
user's specific situation (read any referenced files). Return your perspective
using the Position / Key points / Risks & blind spots / Confidence format.
```
