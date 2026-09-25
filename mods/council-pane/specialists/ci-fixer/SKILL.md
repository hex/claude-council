---
name: ci-fixer
description: A CI job fails on a named revision and the fix belongs in code, config or tests, not in the CI provider.
---

# CI Fixer

Make one failing CI job pass for the right reason. A green run earned by
retrying, skipping or loosening a check is a failure of this task, not a
success.

## Pin the failure

1. Work from the exact revision SHA, run ID and job named in the task. If the
   task names only a pull request or a branch, ask for them in the report
   rather than guessing which run is current.
2. Check that the run is still relevant. A cancelled run is often superseded
   by a newer run on the same revision or branch. If the newest run passes,
   stop and report that.
3. Fetch the failed job's log once and keep it. Work from that copy. Prefer
   the job's own status over a summary or rollup view.
4. Find the first real error, not the last line. Later errors are often
   consequences.

## Classify before changing anything

Put the failure in exactly one class and record the evidence for it:

- **product**: the code under test is wrong. The same failure should
  reproduce locally or in CI's environment.
- **test harness**: the test, fixture, helper or setup is wrong, flaky or
  order-dependent, and the product is fine.
- **environment**: runtime version, OS difference, missing tool, dependency
  resolution, disk, network, cache. The code and test are fine on another
  environment.
- **credential**: a secret, token, quota or permission is missing or expired.
  This is never fixable in code. Stop and report which credential and where
  the log shows it.

If the evidence does not settle the class, say so and report what would.

## Reproduce

- Run the failing command locally with the same arguments the job used.
- If it passes locally, do not conclude the CI is wrong. Match CI's OS,
  runtime version, locale, timezone and environment variables, as far as you
  can, and try again. A local pass does not override a CI failure.
- For a suspected flake, run the single test repeatedly and record the pass
  and fail count. Flaky means you saw it fail and pass on the same code.

## Fix

- Fix the class you identified:
  - product: fix the code at the root cause, as a bug fix;
  - harness: fix the test or fixture so it is deterministic, keeping what it
    asserts;
  - environment: pin or update the version, cache key, or setup step in the
    repo's CI config.
- Never skip, disable, mark as expected-failure, raise a timeout without a
  measured reason, loosen an assertion, or add a retry loop to make the job
  pass.
- Keep changes to the job's failure. Record unrelated failures you notice in
  the report rather than fixing them.

## Prove it

- Run the reproduction again and show it passing.
- For a flake fix, repeat the run enough times that the previous failure rate
  would have shown at least one failure, and record the count.
- State plainly that the CI run itself has not re-run on your change. The tool
  records your work; CI results come afterwards.

## Evidence to record

- Revision, run ID, job name, and the first real error line.
- The class and why.
- Local reproduction command and its output, before and after.
- For flakes: repeat counts before and after.

## Stop conditions

Stop and report when the failure is a credential or provider-side problem,
when the newest run already passes, when you cannot reproduce and cannot
match CI's environment, or when the fix needs a change outside the repo.

## Handoff

Report the class, the root cause, the change, the proof commands with
results, and what still needs a real CI run to confirm.

CI triage steps adapted from openclaw's openclaw-testing and release-openclaw-ci skills (MIT, OpenClaw Foundation); see ../LICENSE-openclaw.
