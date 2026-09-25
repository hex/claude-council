---
name: test-writer
description: The task is to add or extend tests for existing behaviour that has a spec, a documented contract, or a confirmed expected output.
---

# Test Writer

Add tests that protect behaviour a user or caller relies on. Every test must
be able to fail for a real regression, and every expected value must come
from somewhere other than the code under test.

## Authoring gate

Before writing any test, answer these four questions in your notes. If one
has no answer, do not write that test; list it in the report instead.

1. What observable behaviour, invariant or contract does it protect?
   Observable means a caller can see it: a return value, output, file, HTTP
   response, error message, state change.
2. What credible regression would make it fail? Name the plausible bug.
3. Why does existing coverage not catch that already? Each contract should
   have one primary test at the strongest boundary that owns it. Another
   layer needs a distinct risk that the owner cannot reach. Prefer adding a
   case to an existing table or fixture over a near-duplicate test.
4. Does it need a production seam that no production caller needs, such as an
   extra export, a flag or an injection hook? If yes, test at the real
   boundary instead.

## Where expected values come from

In order of preference:
- the spec, API docs, RFC or file-format definition;
- a worked example in the docs or the task;
- a known-good literal confirmed by the task author;
- a real recorded output that a human has confirmed is correct.

Never compute the expected value with the function under test, a helper it
uses, or the same algorithm restated. `expect(add(a, b)).toBe(a + b)` proves
nothing. If the only source for a value is the current code, say so in the
report and do not assert it as correct.

## Reject these patterns

- tests with no assertion, or assertions that cannot fail;
- a value compared with itself or with a copy made by the code under test;
- copied fixtures, inventories or export lists that just mirror the source;
- asserting source text, import paths or private function names;
- private helper tests that duplicate a test at the public boundary;
- the same contract invoked twice in different files;
- mocks that implement the behaviour being asserted;
- negative tests that pass for an unrelated reason, such as a different
  validation rejecting the input first;
- names that promise more than the test checks.

A test that would break under a behaviour-preserving refactor is asserting
implementation, not behaviour. Rewrite it at the owning boundary.

## Prefer real boundaries

- Test through the public interface the caller uses: CLI, HTTP handler,
  library entry point, file reader.
- Use real dependencies where they are cheap and deterministic, such as a
  temp directory, in-memory database or local server. Fake only what is slow,
  paid or non-deterministic, and never fake the thing being tested.
- Follow the repository's existing test layout, helpers, naming and runner.
  Do not add a new test framework.

## Write and check each test

For each test, one at a time:
1. Write it.
2. Run it and see it pass.
3. Prove it can fail. Temporarily break the behaviour it protects, for
   example by returning a wrong value or removing a branch, and confirm the
   test fails with a message that points at the problem. Then restore the
   code exactly. A test you have never seen fail proves nothing.
4. If the test fails on the unmodified code, you may have found a bug. Do not
   change the expected value to match the code. Record the input, expected
   and actual, and the source of the expected value, and report it.

Change production code only when a test cannot be written otherwise, and
explain why in the report.

## Evidence to record

- For each test: the four gate answers, the source of each expected value,
  and the mutation you used to see it fail.
- The test command and its full result.
- Tests considered and rejected, and which gate question failed.

## Stop conditions

Stop and report when the expected behaviour has no independent source, when
the test would need a production seam, or when the code appears to contradict
its own spec.

## Handoff

Report the tests added or extended, with the contract each protects; the
proof that each can fail; suspected bugs found; rejected candidates; and any
production change with its reason.

Authoring gate and junk patterns adapted from openclaw's test-audit skill (MIT, OpenClaw Foundation); see ../LICENSE-openclaw.
