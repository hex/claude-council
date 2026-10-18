#!/bin/bash
# ABOUTME: Runs the heads-up side-check detached: digests the transcript, asks the seats in order, first non-NONE wins
# ABOUTME: Writes result.json then .done into the run dir the mod passed; the mod polls, never waits
#
# Usage: heads-up.sh --run-dir DIR --session ID --seats codex[,gemini,...] --avoid-file FILE
#
# Prints the detached worker's pid and exits 0 at once. Exit 1 before the fork
# when the arguments are unusable (the mod logs stderr once). The worker writes:
#   DIR/pid, DIR/start                before the fork returns
#   DIR/digest.md, DIR/prompt.md      what left the machine; kept until the mod removes the dir
#   DIR/seat-<n>.{out,err,events}     each seat's raw output
#   DIR/result.json                   {kind:note|none|failed, bytes, seat?, ms?, topic?, headline?, detail?,
#                                      seats:[{seat,outcome,ms,detail?}]}; written to a temp name and moved
#   DIR/.done                         last; the mod trusts result.json only after it
# Env (COUNCIL_* so provider_env_scrub keeps them):
#   COUNCIL_HEADS_UP_SEAT_SECONDS   per seat, default 60
#   COUNCIL_HEADS_UP_RUN_SECONDS    whole run, default 180
#   COUNCIL_HEADS_UP_TURNS          digest window, default 5
#   COUNCIL_HEADS_UP_RESULTS        tool results in the digest, default 8, 2000 characters each

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/prompts.sh"
source "${SCRIPT_DIR}/lib/providers.sh"
source "${SCRIPT_DIR}/lib/clock.sh"

usage() {
    echo "Usage: heads-up.sh --run-dir DIR --session ID --seats codex[,gemini,...] --avoid-file FILE" >&2
    exit 1
}

die() {
    echo "Error: $*" >&2
    exit 1
}

RUN_DIR="" SESSION_ID="" SEATS_ARG="" AVOID_FILE=""
SEATS=()

# A whole number of 1 or more, read base-10 so a padded 08 is not octal.
require_count() {
    case "$2" in
        ''|*[!0-9]*) die "$1 needs a whole number, got: $2" ;;
    esac
    (( 10#$2 > 0 )) || die "$1 needs 1 or more, got: $2"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-dir|--session|--seats|--avoid-file)
                [[ $# -ge 2 ]] || die "$1 needs a value."
                case "$1" in
                    --run-dir) RUN_DIR="$2" ;;
                    --session) SESSION_ID="$2" ;;
                    --seats) SEATS_ARG="$2" ;;
                    --avoid-file) AVOID_FILE="$2" ;;
                esac
                shift 2
                ;;
            *)
                echo "Error: unknown argument: $1" >&2
                usage
                ;;
        esac
    done
    [[ -n "$RUN_DIR" ]] || die "--run-dir is required."
    [[ -n "$SESSION_ID" ]] || die "--session is required."
    [[ -n "$SEATS_ARG" ]] || die "--seats is required."
    [[ -n "$AVOID_FILE" ]] || die "--avoid-file is required."
    [[ -d "$RUN_DIR" ]] || die "run dir not found: $RUN_DIR"
    [[ -f "$AVOID_FILE" ]] || die "avoid file not found: $AVOID_FILE"

    # The seat name is spliced into a script path and run, so each one passes
    # the one allowlist, derived from the providers/ registry.
    local seat
    IFS=, read -r -a SEATS <<< "$SEATS_ARG"
    [[ ${#SEATS[@]} -gt 0 ]] || die "--seats names no seat."
    for seat in "${SEATS[@]}"; do
        provider_allowlisted "$seat" || die "not a council seat: $seat"
    done

    SEAT_SECONDS="${COUNCIL_HEADS_UP_SEAT_SECONDS:-60}"
    RUN_SECONDS="${COUNCIL_HEADS_UP_RUN_SECONDS:-180}"
    TURNS="${COUNCIL_HEADS_UP_TURNS:-5}"
    RESULTS="${COUNCIL_HEADS_UP_RESULTS:-8}"
    require_count COUNCIL_HEADS_UP_SEAT_SECONDS "$SEAT_SECONDS"
    require_count COUNCIL_HEADS_UP_RUN_SECONDS "$RUN_SECONDS"
    require_count COUNCIL_HEADS_UP_TURNS "$TURNS"
    require_count COUNCIL_HEADS_UP_RESULTS "$RESULTS"
    SEAT_SECONDS=$((10#$SEAT_SECONDS))
    RUN_SECONDS=$((10#$RUN_SECONDS))
}

# The last line of a seat's stderr, one line and at most 300 characters, for a
# reason the pane logs once.
last_error_line() {
    local line
    line=$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | tr -d '\r') || true
    printf '%s' "${line:0:300}"
}

# Resolves the transcript and builds digest.md and prompt.md. On failure sets
# FAILURE to the reason and returns 1; the worker then writes kind failed.
build_digest() {
    local transcript avoid
    if ! transcript=$(bash "${SCRIPT_DIR}/session-transcript.sh" "$SESSION_ID" 2> "${RUN_DIR}/transcript.err"); then
        FAILURE="transcript: $(last_error_line "${RUN_DIR}/transcript.err")"
        return 1
    fi
    if ! bash "${SCRIPT_DIR}/transcript-digest.sh" --turns "last:${TURNS}" \
            --tool-results "$RESULTS" --tool-result-chars 2000 -- "$transcript" \
            > "${RUN_DIR}/digest.md" 2> "${RUN_DIR}/digest.err"; then
        FAILURE="digest: $(last_error_line "${RUN_DIR}/digest.err")"
        return 1
    fi
    if [[ ! -s "${RUN_DIR}/digest.md" ]]; then
        FAILURE="digest: no human turn in the last ${TURNS}"
        return 1
    fi
    avoid=$(cat "$AVOID_FILE")
    [[ -n "$avoid" ]] || avoid="(nothing yet)"
    interpolate_template "$(load_prompt_template heads-up)" \
        "AVOID=${avoid}" "DIGEST=$(cat "${RUN_DIR}/digest.md")" > "${RUN_DIR}/prompt.md"
    BYTES=$(wc -c < "${RUN_DIR}/prompt.md" | tr -d ' ')
}

# Runs "$@" in the background under a deadline of $1 ticks of `sleep 1`, never
# a $((SECONDS+N)) deadline, which bash 3.2 can reach in milliseconds. A
# watchdog does the ticking so a fast command returns at once; it records each
# tick so the run budget can be charged. Sets RC, TIMED_OUT and TICKS.
run_with_ticks() {
    local limit="$1" pid watchdog ticks_file="${RUN_DIR}/ticks" fired="${RUN_DIR}/deadline"
    shift
    rm -f "$ticks_file" "$fired"
    "$@" &
    pid="$!"
    (
        t=0
        while (( t < limit )); do
            sleep 1
            t=$((t + 1))
            echo "$t" > "$ticks_file"
            kill -0 "$pid" 2>/dev/null || exit 0
        done
        : > "$fired"
        signal_tree TERM "$pid"
        sleep 5
        signal_tree KILL "$pid"
    ) &
    watchdog="$!"
    RC=0
    wait "$pid" || RC=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    TIMED_OUT=0
    [[ -f "$fired" ]] && TIMED_OUT=1
    TICKS=$(cat "$ticks_file" 2>/dev/null || echo 0)
    rm -f "$ticks_file" "$fired"
}

# One string field of codex's answer file, on one line, without its trailing
# newline or a Windows jq's \r.
answer_field() {
    jq -r "$2 | tostring | gsub(\"[\\r\\n\\t]+\"; \" \")" "$1" | tr -d '\r'
}

codex_call() {
    local n="$1"
    local args=(exec --json --skip-git-repo-check -s read-only)
    [[ -n "${CODEX_MODEL:-}" ]] && args+=(-m "$CODEX_MODEL")
    args+=(--output-schema "${SCRIPT_DIR}/heads-up.schema.json" -o "${RUN_DIR}/seat-${n}.out" -)
    ( provider_env_scrub codex; exec codex "${args[@]}" ) \
        < "${RUN_DIR}/prompt.md" > "${RUN_DIR}/seat-${n}.events" 2> "${RUN_DIR}/seat-${n}.err"
}

# codex: structured output. Success only on a "turn.completed" event, since
# codex exits 0 on SIGTERM. Sets OUTCOME (none|note|error|timeout), DETAIL and,
# for a note, TOPIC, HEADLINE and NOTE_DETAIL.
ask_codex() {
    local n="$1" limit="$2" answer="${RUN_DIR}/seat-${1}.out"
    run_with_ticks "$limit" codex_call "$n"
    if (( TIMED_OUT )); then
        OUTCOME=timeout DETAIL="no answer in ${limit}s"
        return 0
    fi
    if ! grep -q '"type":"turn.completed"' "${RUN_DIR}/seat-${n}.events" 2>/dev/null; then
        DETAIL=$(last_error_line "${RUN_DIR}/seat-${n}.err")
        OUTCOME=error DETAIL="exit ${RC} without turn.completed${DETAIL:+: $DETAIL}"
        return 0
    fi
    if jq -e '.none == true' "$answer" > /dev/null 2>&1; then
        OUTCOME=none DETAIL=""
        return 0
    fi
    if ! jq -e '(.topic | type) == "string" and (.headline | type) == "string"' "$answer" > /dev/null 2>&1; then
        OUTCOME=error DETAIL="answer outside the schema"
        return 0
    fi
    # One field per read, each flattened to one line: @tsv would double any
    # backslash in the seat's text on its way into result.json.
    TOPIC=$(answer_field "$answer" .topic)
    HEADLINE=$(answer_field "$answer" .headline)
    NOTE_DETAIL=$(answer_field "$answer" '.detail // ""')
    if [[ -z "$TOPIC" || -z "$HEADLINE" ]]; then
        OUTCOME=error DETAIL="none false with an empty topic or headline"
        return 0
    fi
    OUTCOME=note DETAIL=""
}

# The provider's own deadline is a backstop five seconds past ours: a provider
# script reports its deadline as exit 1, so were the two equal, whichever fired
# first would decide whether the seat logs a timeout or an error.
text_call() {
    local n="$1" seat="$2" limit="$3"
    ( provider_env_scrub "$seat"
      COUNCIL_TIMEOUT="$(( limit + 5 ))" exec bash "${SCRIPT_DIR}/providers/${seat}.sh" --prompt-file "${RUN_DIR}/prompt.md" ) \
        > "${RUN_DIR}/seat-${n}.out" 2> "${RUN_DIR}/seat-${n}.err"
}

# Any other seat: its provider script under the scrubbed env; the first line
# decides. NONE by the builtin's regex; "NOTE: <headline>" then "TOPIC: ..."
# and "DETAIL: ..." lines; anything else is an error, never a note.
ask_text_seat() {
    local n="$1" seat="$2" limit="$3" first line
    run_with_ticks "$limit" text_call "$n" "$seat" "$limit"
    if (( TIMED_OUT )) || (( RC == 143 )); then
        OUTCOME=timeout DETAIL="no answer in ${limit}s"
        return 0
    fi
    if (( RC != 0 )); then
        DETAIL=$(last_error_line "${RUN_DIR}/seat-${n}.err")
        OUTCOME=error DETAIL="exit ${RC}${DETAIL:+: $DETAIL}"
        return 0
    fi
    first=$(head -n 1 "${RUN_DIR}/seat-${n}.out" | tr -d '\r')
    # The builtin's NONE test. In a POSIX bracket a backslash is literal, so the
    # brackets are placed by position: "]" first, "[" just before the "-".
    local none_re='^[Nn][Oo][Nn][Ee][[:space:]]*([].!?():;,[-]|$)'
    if [[ "$first" =~ $none_re ]]; then
        OUTCOME=none DETAIL=""
        return 0
    fi
    if [[ "$first" =~ ^NOTE:[[:space:]]*(.+)$ ]]; then
        HEADLINE="${BASH_REMATCH[1]}" TOPIC="" NOTE_DETAIL=""
        while IFS= read -r line; do
            line="${line%$'\r'}"
            if [[ -z "$TOPIC" && "$line" =~ ^TOPIC:[[:space:]]*(.+)$ ]]; then
                TOPIC="${BASH_REMATCH[1]}"
            elif [[ -z "$NOTE_DETAIL" && "$line" =~ ^DETAIL:[[:space:]]*(.+)$ ]]; then
                NOTE_DETAIL="${BASH_REMATCH[1]}"
            fi
        done < <(tail -n +2 "${RUN_DIR}/seat-${n}.out")
        if [[ -n "$TOPIC" ]]; then
            OUTCOME=note DETAIL=""
            return 0
        fi
        OUTCOME=error DETAIL="off contract: NOTE without a TOPIC line"
        return 0
    fi
    OUTCOME=error DETAIL="off contract: ${first:0:200}"
}

SEATS_JSON='[]'

record_seat() {
    SEATS_JSON=$(jq -c --arg seat "$1" --arg outcome "$2" --argjson ms "$3" --arg detail "$4" \
        '. + [{seat: $seat, outcome: $outcome, ms: $ms} + (if $detail == "" then {} else {detail: $detail} end)]' \
        <<< "$SEATS_JSON")
}

# result.json via jq --arg, so seat text can never break it; temp name then mv,
# then .done, so a reader that sees .done finds the whole file.
write_result() {
    local kind="$1"
    jq -n --arg kind "$kind" --argjson bytes "${BYTES:-0}" --argjson seats "$SEATS_JSON" \
        --arg seat "${WIN_SEAT:-}" --argjson ms "${WIN_MS:-0}" --arg topic "${TOPIC:-}" \
        --arg headline "${HEADLINE:-}" --arg detail "${NOTE_DETAIL:-}" --arg failure "${FAILURE:-}" \
        '{kind: $kind, bytes: $bytes}
         + (if $kind == "note" then {seat: $seat, ms: $ms, topic: $topic, headline: $headline, detail: $detail}
            elif $failure != "" then {detail: $failure}
            else {} end)
         + {seats: $seats}' > "${RUN_DIR}/result.json.tmp"
    mv "${RUN_DIR}/result.json.tmp" "${RUN_DIR}/result.json"
    : > "${RUN_DIR}/.done"
}

# The worker's own failure, say a full disk, still ends in .done: a pane that
# saw no .done would poll a dead pid instead of logging why.
worker_exit() {
    local rc="$1"
    [[ -f "${RUN_DIR}/.done" ]] && return 0
    FAILURE="worker exited with status ${rc} before writing its result"
    write_result failed || : > "${RUN_DIR}/.done"
}

worker() {
    trap 'worker_exit $?' EXIT
    source "${SCRIPT_DIR}/lib/deadline.sh"
    FAILURE="" BYTES=0
    if ! build_digest; then
        write_result failed
        return 0
    fi
    local n=0 seat start ms budget="$RUN_SECONDS" limit any_none=0
    for seat in "${SEATS[@]}"; do
        n=$((n + 1))
        if (( budget <= 0 )); then
            record_seat "$seat" timeout 0 "run budget of ${RUN_SECONDS}s spent before this seat"
            continue
        fi
        limit=$(( SEAT_SECONDS < budget ? SEAT_SECONDS : budget ))
        start=$(now_ms)
        if [[ "$seat" == codex ]]; then
            ask_codex "$n" "$limit"
        else
            ask_text_seat "$n" "$seat" "$limit"
        fi
        ms=$(( $(now_ms) - start ))
        budget=$(( budget - TICKS ))
        record_seat "$seat" "$OUTCOME" "$ms" "$DETAIL"
        case "$OUTCOME" in
            note)
                WIN_SEAT="$seat" WIN_MS="$ms"
                write_result note
                return 0
                ;;
            none) any_none=1 ;;
        esac
    done
    if (( any_none )); then write_result none; else write_result failed; fi
}

main() {
    parse_args "$@"
    ( worker ) </dev/null >/dev/null 2>&1 &
    local pid="$!"
    echo "$pid" > "${RUN_DIR}/pid"
    date +%s > "${RUN_DIR}/start"
    echo "$pid"
}

main "$@"
