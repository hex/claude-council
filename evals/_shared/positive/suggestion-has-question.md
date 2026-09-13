---
type: regex
target: last_message
match: contains
weight: 0.5
---
/claude-council:(ask|advise)[^\n]*"[^"\n]{15,}"
