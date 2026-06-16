---
name: local-council-execution
description: Runs a local council when no external AI providers are configured. Spawns N independent Claude subagents (one per role, blind to each other) that each answer the question from a single assigned lens, then synthesizes their perspectives. Invoked by the ask command via --local, or when the user accepts the local-council offer after no providers are found. This is a same-model (Claude-only) panel, not a cross-vendor council.
---

# Local Council Execution

When no external providers are configured, convene a council of independent
Claude subagents instead. Each member answers from one role, blind to the
others; you then synthesize the spread of perspectives.

**Read this first — the honest framing is not optional.** Every member is
Claude. They share priors and training, so *agreement between them is weak
signal*, not validation. The value here is **independent angles and blind-spot
coverage**, not consensus. The output you produce MUST make this explicit and
MUST NOT present member agreement as if it were cross-vendor corroboration.

## Step 0: Confirm this is a local-council context (guard)

A local council is the **fallback** for when no real providers exist — it is not
a default way to "use the council". Only proceed if one of these holds:

1. The user explicitly passed `--local`, or
2. There are no configured providers and the user accepted the local-council
   offer.

If you reached this skill any other way, verify providers are actually absent
before spawning anything:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --list-default 2>&1 | head -1
```

If that lists one or more providers and the user did **not** ask for `--local`,
**STOP** — do not spawn local members. Run the standard cross-vendor flow
(`council-execution`) so the real providers answer, since same-model role-play is
strictly weaker than the cross-vendor council the user can actually get.

## Step 1: Resolve the roles

Source the libs once:

```bash
source ${CLAUDE_PLUGIN_ROOT}/scripts/lib/prompts.sh
source ${CLAUDE_PLUGIN_ROOT}/scripts/lib/roles.sh
```

**If the user passed `--roles`**, it already says both which lenses and how many
members — use it directly and skip the size question:

```bash
local_council_roles "<--roles value>"
```

**Otherwise, ask the user how many members to convene**, then resolve that many:

```
AskUserQuestion:
  Question: "How many independent perspectives should the local council convene? More members means broader angle coverage, but a longer run and synthesis."
  Header: "Members"
  multiSelect: false
  Options:
    - "4 (Recommended) - balanced breadth"
    - "3 - quick, three sharpest lenses"
    - "5 - thorough"
    - "6 - exhaustive"
```

Then pass the chosen number as the count:

```bash
local_council_roles "" "<chosen number>"
```

`local_council_roles` returns a comma-separated role list (e.g.
`devil,simplicity,security,scalability`). Each role becomes one council member;
N = number of roles. It draws from a diverse ordering and clamps to the 8
available roles — a user who wants more or specific lenses can pass `--roles`
(e.g. `--roles=security,devil,simplicity,scalability,dx,compliance`). If you want
to be safe, `validate_roles "<list>"` returns non-zero on an unknown role.

## Step 2: Assemble the question + context

Build the text each member will answer:

- The user's question.
- Any file context gathered via `--file` or auto-context (the same context the
  cross-vendor flow would send). Include it inline so members can reason about it
  even though they will also read referenced files themselves.

## Step 3: Spawn the members in parallel

For **each** role, build the role-injected prompt and spawn one member. See
[agent-prompt-template.md](agent-prompt-template.md) for the exact prompt and the
`build_prompt_with_role` call.

Launch **all members in a single message** (multiple Agent tool calls) with:
- `subagent_type: "general-purpose"`
- `run_in_background: true`

The member framing (independent, blind to the others, commit to the assigned
lens, return format) lives in the prompt itself — see the template. Launching
them together runs them concurrently and keeps each one blind to the others.

## Step 4: Collect results

You are notified automatically as each background member finishes. Wait for ALL
of them before synthesizing. If a member fails or times out, note it and
continue with the rest.

## Step 5: Display each perspective

Lead with this banner verbatim (it sets honest expectations):

> **Local council** — these perspectives all come from Claude playing different
> roles, not from different AI vendors. Treat agreement as a shared starting
> point to pressure-test, not as independent confirmation.

Then, for each member, display its perspective under a header naming the role
(use `get_role_name "<role>"` for the display name):

```
## 🗳️ {ROLE_NAME}

{member's Position / Key points / Risks & blind spots / Confidence}
```

## Step 6: Synthesize — angles, not consensus

Because members share a model, frame the synthesis around spread and coverage,
NOT agreement strength:

- **Shared starting points** — where members converged. Explicitly note this is
  a common prior to *stress-test*, not corroboration, and ask what they might all
  be missing for the same reason.
- **Genuine tensions** — where the roles pull in different directions, and what
  the user's specific situation implies about which tension matters most here.
- **Blind spots** — risks raised by one member that the others' approaches would
  walk into. Also flag anything *no* member covered.
- **Suggested direction** — your best synthesized recommendation, naming which
  roles support it and where the real uncertainty remains.

## Step 7: Save output

```bash
mkdir -p .claude/council-cache
```

Write the full output (banner + all member perspectives + synthesis) to
`.claude/council-cache/local-council-{TIMESTAMP}.md` where TIMESTAMP is the
current Unix timestamp. Then tell the user:

> ---
> Local council saved to `.claude/council-cache/local-council-{TIMESTAMP}.md`
> For cross-vendor perspectives, configure a provider key or install a CLI
> (`/claude-council:status` shows what's available).

## Error Handling

- If a member fails, show the failure and continue with the others.
- If ALL members fail, report clearly and suggest retrying.
- If only one role resolved, say so — a one-member "council" is just a single
  role-played answer, and the user should know that.
