#!/bin/bash
# ABOUTME: Answers the council-pane mod's seat questions from the runner's own provider library
# ABOUTME: A shipped script with fixed subcommands, so the mod never hands bash an inline script
#
# Usage: seat-info.sh discover | model SEAT | allowlisted SEAT
#   discover          the seats a council run would seat here, space-separated
#   model SEAT        the model SEAT would run, as the runner resolves it
#   allowlisted SEAT  exit 0 when SEAT is a council provider, 1 when not

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROVIDERS_DIR="${SCRIPT_DIR}/providers"

usage() {
    echo "Usage: seat-info.sh discover | model SEAT | allowlisted SEAT" >&2
    exit 2
}

[[ $# -ge 1 ]] || usage
case "$1" in
    discover)
        [[ $# -eq 1 ]] || usage
        source "${SCRIPT_DIR}/lib/keys.sh"
        resolve_grok_key
        source "${SCRIPT_DIR}/lib/providers.sh"
        discover_providers
        ;;
    model)
        [[ $# -eq 2 ]] || usage
        source "${SCRIPT_DIR}/lib/providers.sh"
        get_model "$2"
        ;;
    allowlisted)
        [[ $# -eq 2 ]] || usage
        source "${SCRIPT_DIR}/lib/providers.sh"
        provider_allowlisted "$2"
        ;;
    *)
        usage
        ;;
esac
