#!/bin/bash
# ABOUTME: Writes the tokens one seat call used to the file COUNCIL_USAGE_FILE names, when it names one
# ABOUTME: One record, {input, cached, output, reasoning}; never touches the caller's stdout, stderr or exit code

# The record every seat's tokens are mapped into, so seats add up: input counts
# every prompt token, cached ones and cache writes included; output counts
# every generated token, reasoning included; cached and reasoning are null when
# the vendor gave no such split, never 0 for unknown. Anything else, or a split
# larger than its whole, is not a record.
USAGE_SHAPE='def count: type == "number" and . >= 0 and . == floor;
    select(type == "object"
        and (.input | count) and (.output | count)
        and (.cached == null or (.cached | count))
        and (.reasoning == null or (.reasoning | count))
        and (.cached // 0) <= .input and (.reasoning // 0) <= .output)
    | {input, cached, output, reasoning}'

# Usage: emit_usage JQ_ARG...
#   The jq program and its input as jq takes them; the program maps the
#   vendor's own fields into one record. No record, or more than one, writes
#   nothing: an unreported call is left out, never counted as zero.
emit_usage() {
    [[ -n "${COUNCIL_USAGE_FILE:-}" ]] || return 0
    local record
    record=$(jq -c "$@" 2>/dev/null | jq -cs "if length == 1 then .[0] | ${USAGE_SHAPE} else empty end" 2>/dev/null) || return 0
    [[ -n "$record" ]] || return 0
    { printf '%s\n' "$record" > "$COUNCIL_USAGE_FILE"; } 2>/dev/null || true
}
