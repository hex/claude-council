#!/bin/bash
# ABOUTME: Validates an agent analysis document against schemas/agent-analysis.schema.json
# ABOUTME: Reads JSON on stdin; exit 0 if valid, exit 1 listing every violation

set -euo pipefail

INPUT=$(cat)

if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
    echo "invalid: input is not valid JSON" >&2
    exit 1
fi

# Mirrors the contract in schemas/agent-analysis.schema.json. jq cannot run
# JSON Schema directly, so each rule is restated here; the bats suite keeps
# the two in sync via the schema's required-fields list and bounds.
VIOLATIONS=$(echo "$INPUT" | jq -r '
    if type != "object" then ["document must be a JSON object"]
    else [
        (if (.quality? // "") | IN("good","fair","poor")
            then empty else "quality must be one of good|fair|poor" end),
        (if (.retried? | type) == "boolean"
            then empty else "retried must be a boolean" end),
        (if (.confidence? // "") | IN("high","medium","low")
            then empty else "confidence must be one of high|medium|low" end),
        (if (.key_recommendations? | type) == "array"
            and (.key_recommendations | length >= 1 and length <= 5 and all(type == "string"))
            then empty else "key_recommendations must be an array of 1-5 strings" end),
        (["unique_perspective", "blind_spots", "full_response"][] as $f |
            if (.[$f]? | type == "string" and length >= 1)
                then empty else "\($f) must be a non-empty string" end)
    ] end | .[]
')

if [[ -n "$VIOLATIONS" ]]; then
    echo "invalid agent analysis:" >&2
    echo "$VIOLATIONS" | sed 's/^/  - /' >&2
    exit 1
fi

exit 0
