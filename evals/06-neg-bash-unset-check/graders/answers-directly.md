---
type: llm
focus: last_message
---
The response answers the question directly and correctly: it distinguishes unset from empty and gives a working idiom such as `[ -z "${var+x}" ]` or `[[ -v var ]]` (bash 4.2+). Pass if a correct idiom for the unset-vs-empty distinction is given. Fail if the answer is wrong, evasive, or defers the question to another tool or process.
