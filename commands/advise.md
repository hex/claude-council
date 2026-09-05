---
description: Put the current conversation to the council — resolve this session's transcript, digest a bounded window of it, show what would leave the machine, and only then ask external providers for advice on it. Use when the user asks the council to look at what we have been doing, wants a second opinion on this session's approach rather than on a question typed fresh, or says they are stuck and the reasoning so far is the thing worth reviewing. Prefer /claude-council:ask when the question stands on its own without the conversation behind it.
argument-hint: '[--turns=last:N] [--providers=list] [--verbosity=brief|standard|detailed] "what to ask about it"'
allowed-tools: Bash(bash */scripts/session-transcript.sh *), Bash(bash */scripts/transcript-digest.sh *), Bash(bash */scripts/query-council.sh *), Bash(wc:*), Bash(head:*), Bash(mktemp:*), Bash(rm:*), Read, AskUserQuestion
---

Ask the council about this conversation.

## What makes this different from `/ask`

`/ask` sends a question you typed. This sends a slice of the conversation
itself, so the providers can see the reasoning rather than your summary of it.
That is the point: a model given only your framing tends to agree with your
framing, and agreement produced that way measures the framing, not the work.

It is also why every run shows you the payload before anything is sent.

## Step 1: Resolve this conversation's transcript

The session id is substituted into this file at invocation:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/session-transcript.sh ${CLAUDE_SESSION_ID}
```

If that fails, stop and report why. Do not search for a transcript by
modification time or pick the newest file: a teammate agent running in the same
directory writes its own transcript, and the newest file is frequently theirs.

## Step 2: Digest a bounded window

Default to the last 25 turns. `--turns=last:N` overrides it; `--turns=all` is
available but say plainly that it sends the whole conversation.

```bash
DIGEST=$(mktemp -t council-digest)
bash ${CLAUDE_PLUGIN_ROOT}/scripts/transcript-digest.sh --turns last:25 "<path>" > "$DIGEST" \
  || { echo "digest failed"; rm -f "$DIGEST"; }
wc -c "$DIGEST"
```

Stop if the script exited non-zero or the file is empty: there is nothing to
show and nothing to send. The script fails loudly on a record it cannot read
rather than emitting a digest with a hole in it, and a windowed run that matched
no turn writes nothing at all.

Use a plain temporary name. The file path is interpolated into the prompt the
providers receive, so a name carrying the session or directory tells them things
the digest itself does not.

The digest carries human turns, assistant replies, and the questions the
assistant put to the user through AskUserQuestion together with what they
picked, since those are decisions and the reason to ask for a review. It
excludes every other tool result and tool input, thinking blocks, hook output,
teammate and peer messages, and compact summaries.

A line near the top reading `> N malformed record(s) skipped: this digest is
incomplete.` means the transcript held records the script could not parse. It
is part of the payload, so it reaches the user in Step 3 and the providers
after.

## Step 3: Show the payload, then ask

This step is the privacy control and it is not optional. The script cannot be
the gate: inside a subagent the ambient session id names the *parent*
conversation, so nothing the script can read tells it whose words it holds.

Show the user, before sending:

- the byte size and how many turns it covers
- the first few lines of the digest, via `head`
- which providers will receive it

Then use **AskUserQuestion** to confirm, offering: send it, send a smaller
window, or cancel. Treat anything other than an explicit yes as cancel, and
delete the digest.

Sending is publishing. The digest goes to third-party providers, may be
retained by them, and cannot be recalled.

## Step 4: Query the council

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh \
  --file="$DIGEST" --no-auto-context --no-pane \
  -- "<the user's question>"
```

`--no-auto-context` because the digest is the context; auto-detected repo files
would add material the user did not see in step 3. Pass `--file=` in the equals
form, which is what the auto-context skip condition names.

Delete the digest afterwards.

## Step 5: Show the responses, do not synthesize them

Display every provider's response verbatim, labelled by provider and model.

Then stop. Unlike `/ask`, do **not** write a synthesis: the conversation under
review is your own, so a summary of the advice would be the reviewed party
grading the review. Where providers disagree, say so in one line and leave the
disagreement standing.

If a provider fails, show its error in its slot. Never fill a failed slot with
your own answer.
