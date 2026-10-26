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

# The usage of a chat-completions body: cached tokens part of prompt_tokens,
# reasoning tokens part of completion_tokens, either split null when the vendor
# leaves out its details object. Linted on its own, this file shows no reader
# of either shape: the providers that pass them to emit_usage are out of view.
# shellcheck disable=SC2034
USAGE_CHAT='.usage | {input: .prompt_tokens, cached: .prompt_tokens_details.cached_tokens,
    output: .completion_tokens, reasoning: .completion_tokens_details.reasoning_tokens}'

# The usage of a Responses API body: cached tokens part of input_tokens,
# reasoning tokens part of output_tokens, the details optional.
# shellcheck disable=SC2034
USAGE_RESPONSES='.usage | {input: .input_tokens, cached: .input_tokens_details.cached_tokens,
    output: .output_tokens, reasoning: .output_tokens_details.reasoning_tokens}'

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
