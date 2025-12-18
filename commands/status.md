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
- Summary of available providers

No additional formatting needed - the script handles all presentation.
