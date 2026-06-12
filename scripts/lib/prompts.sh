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
interpolate_template() {
    local out="$1"
    shift
    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        # Replacement is quoted so bash 5.2 patsub_replacement leaves & and \ literal
        out=${out//"{{${key}}}"/"$val"}
    done
    # Unfilled slots collapse to empty
    out=$(printf '%s' "$out" | perl -pe 's/\{\{[A-Za-z0-9_]+\}\}//g')
    printf '%s\n' "$out"
}
