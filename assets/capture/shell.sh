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
# bash 3.2 under set -u rejects "${args[@]}" when the array is empty.
exec /bin/bash --noprofile --norc ${args[@]+"${args[@]}"}
