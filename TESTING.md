# Testing Guide

Manual testing procedures for claude-council features.

## Prerequisites

1. **API Keys configured** (at least one):
   ```bash
   export GEMINI_API_KEY="your-key"
   export OPENAI_API_KEY="your-key"
   export GROK_API_KEY="your-key"
   ```

2. **Plugin loaded** in Claude Code:
   ```bash
   claude --plugin-dir /path/to/claude-council
   ```

3. **Verify provider status**:
   ```bash
   bash scripts/check-status.sh
   # Or via slash command:
   /claude-council:status
   ```
   Expected: At least one provider shows "Connected"

---

## Script-Level Tests (No Plugin Required)

These tests verify the bash implementation directly.

### JSON Output Structure
```bash
bash scripts/query-council.sh --providers=gemini "Test" 2>/dev/null | jq 'keys'
```
**Expected**: `["metadata", "round1"]`

### Argument Validation
```bash
bash scripts/query-council.sh --invalid-flag "Test" 2>&1
```
**Expected**: `Error: Unknown flag: --invalid-flag`

### Role Validation
```bash
bash scripts/query-council.sh --roles=nonexistent "Test" 2>&1
```
**Expected**: `Error: Unknown role: nonexistent` with available roles listed

### Role Preset Expansion
```bash
bash scripts/query-council.sh --providers=gemini,openai --roles=balanced "Test" 2>&1 | grep "Provider roles"
```
**Expected**: Shows security, performance, maintainability assignments

### Debate Mode JSON
```bash
bash scripts/query-council.sh --providers=gemini --debate "Test" 2>/dev/null | jq 'has("round2")'
```
**Expected**: `true`

### Formatter Test
```bash
echo '{"metadata":{"quiet_mode":false},"round1":{"gemini":{"status":"success","response":"Test","model":"test-model","role":"security"}}}' | bash scripts/format-output.sh
```
**Expected**: Formatted box with provider name, model, and role

### Quiet Mode Formatter
```bash
echo '{"metadata":{"quiet_mode":true},"round1":{"gemini":{"status":"success","response":"Test","model":"test"}}}' | bash scripts/format-output.sh
```
**Expected**: Only synthesis header shown (no provider response box)

---

## Feature Tests (Via Slash Command)

### 1. Basic Query

**Test**: Simple query to all providers
```bash
/claude-council:ask "What are the pros and cons of REST vs GraphQL?"
```

**Expected**:
- [ ] Shows "Querying N providers in parallel"
- [ ] Each provider shows status (success/cached/error)
- [ ] Response boxes with provider name + model
- [ ] Synthesis section with consensus/divergence table

---

### 2. Provider Selection (--providers)

**Test**: Query specific providers only
```bash
/claude-council:ask --providers=gemini,openai "Explain dependency injection"
```

**Expected**:
- [ ] Only queries Gemini and OpenAI
- [ ] Grok not included in output
- [ ] Synthesis only references queried providers

---

### 3. File Context (--file)

**Test**: Include a specific file
```bash
/claude-council:ask --file=scripts/query-council.sh "Review this script for improvements"
```

**Expected**:
- [ ] File contents included in prompt to providers
- [ ] Responses reference specific code from the file
- [ ] Auto-context skipped (explicit file provided)

---

### 4. Export to File (--output)

**Test**: Save response to markdown
```bash
/claude-council:ask --output=test-output.md "What's the best way to handle errors in async code?"
```

**Expected**:
- [ ] File created at `test-output.md`
- [ ] Contains metadata header (Query, Date, Providers)
- [ ] Clean markdown (no ANSI codes, no box characters)
- [ ] All provider responses included
- [ ] Synthesis section present

**Cleanup**:
```bash
rm test-output.md
```

---

### 5. Quiet Mode (--quiet)

**Test**: Show only synthesis
```bash
/claude-council:ask --quiet "Should I use TypeScript or JavaScript?"
```

**Expected**:
- [ ] No individual provider response boxes shown
- [ ] Only synthesis section displayed
- [ ] Synthesis still references all provider opinions

---

### 6. Response Caching

**Test A**: First query (cache miss)
```bash
/claude-council:ask "What is the singleton pattern?"
```

**Expected**:
- [ ] All providers show "success" (not "cached")
- [ ] Cache files created in `.claude/council-cache/`

**Test B**: Repeat same query (cache hit)
```bash
/claude-council:ask "What is the singleton pattern?"
```

**Expected**:
- [ ] Providers show "cached" instead of "success"
- [ ] Response appears faster
- [ ] Same content as first query

**Test C**: Force fresh query
```bash
/claude-council:ask --no-cache "What is the singleton pattern?"
```

**Expected**:
- [ ] All providers show "success" (not "cached")
- [ ] Fresh responses from APIs

**Verify cache files**:
```bash
ls -la .claude/council-cache/
```

**Cleanup**:
```bash
rm -rf .claude/council-cache/
```

---

### 7. Auto-Context Injection

**Test A**: Question with code keywords
```bash
/claude-council:ask "How can I improve the caching implementation?"
```

**Expected**:
- [ ] Shows "Auto-included context (N files):"
- [ ] Lists files like `scripts/lib/cache.sh`
- [ ] Responses reference specific code from auto-included files

**Test B**: Disable auto-context
```bash
/claude-council:ask --no-auto-context "What are caching best practices?"
```

**Expected**:
- [ ] No "Auto-included context" message
- [ ] Generic response (not referencing local code)

**Test C**: Generic question (no code keywords)
```bash
/claude-council:ask "What's the weather like today?"
```

**Expected**:
- [ ] No auto-context injection (question doesn't reference code)

---

### 8. Specialized Roles (--roles)

**Test A**: Specific roles
```bash
/claude-council:ask --roles=security,performance,maintainability "Review this authentication approach: JWT stored in localStorage"
```

**Expected**:
- [ ] Shows "Provider roles:" before querying
- [ ] Each provider assigned different role
- [ ] Gemini focuses on security concerns
- [ ] OpenAI focuses on performance
- [ ] Grok focuses on maintainability
- [ ] Responses clearly reflect assigned perspectives

**Test B**: Role preset
```bash
/claude-council:ask --roles=balanced "How should I structure API endpoints?"
```

**Expected**:
- [ ] Preset expands to: security, performance, maintainability
- [ ] Same behavior as Test A

**Test C**: Fewer roles than providers
```bash
/claude-council:ask --roles=security "Review error handling in this approach"
```

**Expected**:
- [ ] First provider gets security role
- [ ] Other providers respond without role
- [ ] No errors

---

### 9. Debate Mode (--debate)

**Test**: Enable multi-round discussion
```bash
/claude-council:ask --debate "Should we use microservices or monolith for a new project?"
```

**Expected**:
- [ ] Shows "## Round 1: Initial Responses"
- [ ] All providers give initial answers
- [ ] Shows "## Round 2: Rebuttals"
- [ ] Each provider critiques others' responses
- [ ] Rebuttal headers use yellow color
- [ ] Synthesis includes:
  - [ ] Strongest criticisms
  - [ ] Consensus shifts
  - [ ] Unresolved tensions

**Test B**: Debate with roles
```bash
/claude-council:ask --debate --roles=security,scalability,simplicity "Review this database schema design"
```

**Expected**:
- [ ] Round 1: Each provider argues from their role
- [ ] Round 2: Rebuttals maintain role perspective
- [ ] Rich debate from different angles

---

### 10. Combined Flags

**Test**: Multiple flags together
```bash
/claude-council:ask --providers=gemini,openai --roles=security,performance --quiet --output=combined-test.md "Review this code pattern"
```

**Expected**:
- [ ] Only Gemini and OpenAI queried
- [ ] Roles assigned correctly
- [ ] Terminal shows only synthesis (quiet mode)
- [ ] File contains full output including individual responses

**Cleanup**:
```bash
rm combined-test.md
```

---

## Edge Cases

### No API Keys
```bash
unset GEMINI_API_KEY OPENAI_API_KEY GROK_API_KEY
bash scripts/query-council.sh "Test question" 2>&1
```
**Expected**: `Error: No providers configured. Set API keys for at least one provider.`

### Invalid Provider
```bash
bash scripts/query-council.sh --providers=invalid "Test" 2>&1
```
**Expected**: Attempts query but provider script not found (graceful error in JSON)

### Invalid Role
```bash
bash scripts/query-council.sh --roles=hacker "Test" 2>&1
```
**Expected**: `Error: Unknown role: hacker` with list of available roles

### Unknown Flag
```bash
bash scripts/query-council.sh --foobar "Test" 2>&1
```
**Expected**: `Error: Unknown flag: --foobar` with usage message

### Missing File
```bash
bash scripts/query-council.sh --file=/nonexistent "Test" 2>&1
```
**Expected**: `Error: File not found: /nonexistent`

### Empty Question
```bash
bash scripts/query-council.sh "" 2>&1
```
**Expected**: `Error: No prompt provided` with usage message

### Very Long Question
```bash
bash scripts/query-council.sh "$(cat README.md) - Summarize this" 2>/dev/null | jq '.metadata.prompt' | head -c 100
```
**Expected**: Handles gracefully, full prompt stored in metadata

---

## Performance Tests

### Cache TTL
1. Make a query
2. Wait > 1 hour (or set `COUNCIL_CACHE_TTL=10`)
3. Repeat query
**Expected**: Cache expired, fresh query made

### Timeout Handling
```bash
export COUNCIL_TIMEOUT=1
/claude-council:ask "Complex question requiring long response"
```
**Expected**: Timeout error, no retry

### Retry Logic
```bash
export COUNCIL_DEBUG=1
# (Requires simulating 429/5xx errors)
```
**Expected**: Retries with exponential backoff shown in debug output

---

## Checklist Summary

| Feature | Test Command | Status |
|---------|--------------|--------|
| Basic query | `/ask "question"` | [ ] |
| Provider selection | `--providers=gemini` | [ ] |
| File context | `--file=path` | [ ] |
| Export | `--output=file.md` | [ ] |
| Quiet mode | `--quiet` | [ ] |
| Cache hit | Same query twice | [ ] |
| Cache bypass | `--no-cache` | [ ] |
| Auto-context | Query with keywords | [ ] |
| No auto-context | `--no-auto-context` | [ ] |
| Roles | `--roles=security,perf` | [ ] |
| Role preset | `--roles=balanced` | [ ] |
| Debate | `--debate` | [ ] |
| Combined flags | Multiple flags | [ ] |
