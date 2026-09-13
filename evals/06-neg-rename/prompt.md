---
    max_turns: 6
    timeout_seconds: 120
    allowed_tools: [Skill, Agent, Read, Glob, Grep]
    runs: 3
    ---
    Rename `fetchUser` to `loadUser` in this snippet and give me back the whole thing:

```js
async function fetchUser(id) {
  const res = await fetch(`/api/users/${id}`);
  if (!res.ok) throw new Error(`fetchUser failed: ${res.status}`);
  return res.json();
}

export async function loadProfile(id) {
  const user = await fetchUser(id);
  return { ...user, loadedAt: Date.now() };
}
```
