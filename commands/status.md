---
description: Check connectivity and configuration status of all council providers
allowed-tools: Bash(*)
---

Check the status of all configured AI providers.

## Execution

Run the status check script:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-status.sh
```

## Output

Present the script output directly - it includes formatted status for each provider:
- Connection status (connected, timeout, auth error, not configured)
- Response time in milliseconds
- Configured model name
- Per-provider fix command for anything not available
- Summary of available providers

No additional formatting needed - the script handles all presentation.

## Background Jobs

Also list any background council jobs:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-council.sh --jobs
```

If the output is non-empty, present it as a table (job id, status, created)
and mention `/claude-council:result <job-id>`. If empty, omit the section.
