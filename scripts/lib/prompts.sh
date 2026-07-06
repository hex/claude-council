#!/bin/bash
# ABOUTME: Loads prompt templates from prompts/ and fills {{VAR}} slots
# ABOUTME: Missing variables collapse to empty so callers can omit optional slots

PROMPTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="${COUNCIL_PROMPTS_DIR:-${PROMPTS_LIB_DIR}/../../prompts}"

# Print the named template from prompts/<name>.md
load_prompt_template() {
    local name="$1"
    local file="${PROMPTS_DIR}/${name}.md"
    if [[ ! -f "$file" ]]; then
        echo "Error: prompt template not found: $file" >&2
        return 1
    fi
    cat "$file"
}

# Fill {{KEY}} slots in a template string.
# Usage: interpolate_template "$template" "KEY=value" "OTHER=value"
# Values may contain any characters including newlines and equals signs.
# Slots with no matching argument are removed.
#
# Single left-to-right pass over the ORIGINAL template: each {{KEY}} is replaced
# by its value (or removed if unprovided), and the value is appended as-is —
# never re-scanned. This preserves {{...}} sequences that appear inside a
# substituted value (e.g. a git diff containing mustache/Jinja braces), which a
# naive whole-string replace-then-strip would delete.
interpolate_template() {
    local template="$1"
    shift
    local out="" rest="$template" whole name kv val
    while [[ "$rest" =~ \{\{([A-Za-z0-9_]+)\}\} ]]; do
        whole="${BASH_REMATCH[0]}"
        name="${BASH_REMATCH[1]}"
        out+="${rest%%"$whole"*}"   # literal text before this slot
        val=""
        for kv in "$@"; do
            if [[ "${kv%%=*}" == "$name" ]]; then val="${kv#*=}"; break; fi
        done
        out+="$val"                 # provided value (or empty); not re-scanned
        rest="${rest#*"$whole"}"
    done
    out+="$rest"
    printf '%s\n' "$out"
}
