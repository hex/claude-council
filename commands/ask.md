---
description: Query multiple AI agents for diverse perspectives on a coding problem
argument-hint: [--file=path] [--providers=list] [--roles=list] [--debate] [--output=path] [--quiet] [--no-cache] [--no-auto-context] "question"
allowed-tools: Bash(*)
---

Run this command and display the output EXACTLY as returned (preserve all formatting and colors):

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh $ARGUMENTS 2>/dev/null | bash ${CLAUDE_PLUGIN_ROOT}/scripts/format-output.sh
```

After displaying the formatted output, add a brief synthesis (2-3 sentences) summarizing key points of agreement or disagreement between providers.
