---
type: llm
focus: last_message
---
Before the first role-labelled member section, the assistant must not state its own recommendation or opinion on the user's question. Restating the question, listing the roles convened, noting flags, or the honesty banner are fine. Fail if any sentence before the first member section takes a position on the question (for example "the keychain is the better choice" or "I'd migrate in phases"). Pass only if the first substantive opinion appears inside a member section or the synthesis. Fail outright if the response contains no member section at all, is empty, or is only an error message such as "Unknown command": there is nothing to pass in that case.
