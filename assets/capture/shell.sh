#!/bin/bash
# ABOUTME: Runs capture commands without loading personal shell startup files.
# ABOUTME: Keeps the fixture PATH and cleared provider environment intact.
set -euo pipefail
args=()
for arg in "$@"; do
    case "$arg" in
        -l|--login|-i) ;;
        -lc|-ic) args+=("-c") ;;
        *) args+=("$arg") ;;
    esac
done
exec /bin/bash --noprofile --norc "${args[@]}"
