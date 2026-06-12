---
description: Fetch, list, or cancel background council jobs started with --async
argument-hint: [job-id] | list | cancel <job-id>
allowed-tools: Bash(*), Read
---

Manage background council jobs.

## Argument Handling

- `$ARGUMENTS` is empty or `list`: list jobs
- `$ARGUMENTS` is `cancel <job-id>`: cancel that job
- Otherwise: treat `$ARGUMENTS` as a job id and fetch its result

## List Jobs

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-council.sh --jobs
```

Present the output as a table (job id, status, created). If empty, tell the
user there are no background council jobs and that `/claude-council:ask`
with `--async` starts one.

## Cancel a Job

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-council.sh --cancel=<job-id>
```

Relay the confirmation verbatim.

## Fetch a Result

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-council.sh --result=<job-id>
```

- **Exit 0**: stdout is the output file path. Read the file and display its
  content VERBATIM (same rules as the council-execution skill: no
  reformatting, no summarizing). Then complete the synthesis under the
  `## Synthesis` header following `${CLAUDE_PLUGIN_ROOT}/prompts/synthesis.md`.
- **Exit 2**: the job is still running. Tell the user and suggest re-running
  `/claude-council:result <job-id>` in a little while.
- **Exit 1**: unknown, failed, or cancelled job. Show the script's stderr,
  which includes the tail of the job log for failures.
