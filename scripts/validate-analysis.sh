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
# the two in sync via the schema's required-fields list.
VIOLATIONS=$(echo "$INPUT" | jq -r '
    [
        (if type == "object" then empty else "document must be a JSON object" end),
        (if (type == "object") and ((.quality? // "") | IN("good","fair","poor"))
            then empty else "quality must be one of good|fair|poor" end),
        (if (type == "object") and ((.retried? | type) == "boolean")
            then empty else "retried must be a boolean" end),
        (if (type == "object") and ((.confidence? // "") | IN("high","medium","low"))
            then empty else "confidence must be one of high|medium|low" end),
        (if (type == "object") and ((.key_recommendations? | type) == "array")
            and ((.key_recommendations // []) | length >= 1)
            and ((.key_recommendations // []) | all(type == "string"))
            then empty else "key_recommendations must be a non-empty array of strings" end),
        (if (type == "object") and ((.unique_perspective? | type) == "string")
            and ((.unique_perspective // "") | length >= 1)
            then empty else "unique_perspective must be a non-empty string" end),
        (if (type == "object") and ((.blind_spots? | type) == "string")
            and ((.blind_spots // "") | length >= 1)
            then empty else "blind_spots must be a non-empty string" end),
        (if (type == "object") and ((.full_response? | type) == "string")
            and ((.full_response // "") | length >= 1)
            then empty else "full_response must be a non-empty string" end)
    ] | .[]
')

if [[ -n "$VIOLATIONS" ]]; then
    echo "invalid agent analysis:" >&2
    echo "$VIOLATIONS" | sed 's/^/  - /' >&2
    exit 1
fi

exit 0
