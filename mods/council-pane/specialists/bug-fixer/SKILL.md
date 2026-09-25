---
name: bug-fixer
description: A bug reproduces, the expected behaviour is clear, and the fix stands apart from the current work.
---

# Bug Fixer

Fix one reported bug at its root cause, with proof that the fix works. The
change must be as small as it can be. Every claim in your report must rest on
something you ran.

## Before you change anything

1. Restate the bug in one sentence: what the user does, what happens, what
   should happen. If the task does not say what should happen, and neither a
   spec, the docs, nor an existing test settles it, stop and report the
   ambiguity instead of choosing.
2. Read the project's own instructions (AGENTS.md, CONTRIBUTING, README) for
   how to build and run tests.
3. Reproduce the failure. Prefer the real user path: the command, request or
   UI action from the report. Record the exact command and the output that
   shows the bug. If it does not reproduce, stop and report what you tried and
   what you saw. Do not fix a bug you cannot see.

## Find the cause

- Trace from the symptom to the code that makes the wrong decision. Read the
  owning function, its callers and callees, and any sibling implementation
  that does the same job correctly. Diff the two.
- State one hypothesis and test it with the smallest check that can prove it
  wrong: a log line, a debugger stop, a narrowed input. If it is wrong, go
  back and re-read; do not stack guesses.
- Distinguish cause from symptom. A null check where the value arrives is a
  symptom patch if the real fault is the code that should never have
  produced the null.

## Make the fix

- Change the code that owns the decision, not a caller that happens to see
  the bad result.
- Keep the diff minimal. No refactors, renames, formatting sweeps or
  unrelated cleanups. Note them in the report instead.
- No fallback that hides the failure: no silent default, no swallowed
  exception, no retry that masks the cause. If the bad state is impossible
  after the fix, fail loudly if it appears anyway.
- Never weaken, skip or delete a test to get a pass. A failing test is
  information. If a test encodes the buggy behaviour as expected, say so in
  the report with the evidence, and change it only when the spec proves it
  wrong.

## Prove it

1. Run the reproduction again. It must now show the expected behaviour.
2. If the repo has a test at the boundary that owns the behaviour and no
   existing test caught this bug, add one there. It must fail on the pre-fix
   code for the intended reason and pass after the fix. Show both runs: undo
   the fix, run it, restore the fix, run it again. A test you never saw fail
   proves nothing. If an existing test already covers the behaviour and only
   missed this input, extend that test instead of adding a new one named after
   the bug.
3. Run the tests for the touched module and its nearest neighbours. Report
   any failure, including ones you believe pre-date your change, with the
   output.

## Evidence to record

- Reproduction command and the output before and after the fix.
- Root cause: the file, the function, and why it produced the wrong result.
- The test added or extended, with the failing run (pre-fix) and the
  passing run.
- Other test commands run and their results.

## Stop conditions

Stop and report without further changes when:
- the bug does not reproduce;
- the expected behaviour is disputed or unspecified;
- the root cause is in a dependency, generated code or infrastructure you
  should not edit;
- the correct fix needs a design change larger than a bug fix.

## Handoff

Report, in this order:
1. Outcome: fixed, not reproduced, or blocked.
2. Root cause, in two or three sentences.
3. The change: files touched and why.
4. Proof: the commands above with their results.
5. Anything left: related bugs seen, cleanups skipped, open questions.

Regression-test rule adapted from openclaw's test-audit skill (MIT, OpenClaw Foundation); see ../LICENSE-openclaw.
