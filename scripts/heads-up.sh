#!/bin/bash
# ABOUTME: Runs the heads-up side-check detached: digests the transcript and asks one seat once
# ABOUTME: Writes result.json then .done into the run dir the mod passed; the mod polls, never waits
#
# Usage: heads-up.sh --run-dir DIR --session ID --seat NAME --avoid-file FILE [--model FILE]
#   --model FILE    JSON object {model?, effort?}, the seat's pick: the model goes to the seat's own
#                   *_MODEL variable for its call; the effort to codex's -c model_reasoning_effort
#
# Prints the detached worker's pid and exits 0 at once. Exit 1 before the fork
# when the arguments are unusable (the mod logs stderr once). The worker writes:
#   DIR/pid, DIR/start                before the fork returns
#   DIR/digest.md, DIR/prompt.md      what left the machine; kept until the mod removes the dir
#   DIR/seat.{out,err,events}         the seat's raw output
#   DIR/result.json                   {kind:note|none|failed, bytes, seat?, model?, ms?, tag?, topic?, headline?, title?, points?, detail?,
#                                      seats:[{seat,outcome,ms,detail?}]}; seats holds the seat's outcome, none
#                                      when the run failed before asking it; written to a temp name and moved
#   DIR/.done                         last; the mod trusts result.json only after it
# Env (COUNCIL_* so provider_env_scrub keeps them):
#   COUNCIL_HEADS_UP_SEAT_SECONDS   the seat's deadline, default 60
#   COUNCIL_HEADS_UP_TURNS          digest window, default 5
#   COUNCIL_HEADS_UP_RESULTS        tool results in the digest, default 8, 2000 characters each

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/prompts.sh"
source "${SCRIPT_DIR}/lib/providers.sh"
source "${SCRIPT_DIR}/lib/clock.sh"

usage() {
    echo "Usage: heads-up.sh --run-dir DIR --session ID --seat NAME --avoid-file FILE [--model FILE]" >&2
    exit 1
}

die() {
    echo "Error: $*" >&2
    exit 1
}

RUN_DIR="" SESSION_ID="" SEAT="" AVOID_FILE="" PICK_FILE=""

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
            --run-dir|--session|--seat|--avoid-file|--model)
                [[ $# -ge 2 ]] || die "$1 needs a value."
                case "$1" in
                    --run-dir) RUN_DIR="$2" ;;
                    --session) SESSION_ID="$2" ;;
                    --seat) SEAT="$2" ;;
                    --avoid-file) AVOID_FILE="$2" ;;
                    --model) PICK_FILE="$2" ;;
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
    [[ -n "$SEAT" ]] || die "--seat is required."
    [[ -n "$AVOID_FILE" ]] || die "--avoid-file is required."
    [[ -d "$RUN_DIR" ]] || die "run dir not found: $RUN_DIR"
    [[ -f "$AVOID_FILE" ]] || die "avoid file not found: $AVOID_FILE"
    if [[ -n "$PICK_FILE" ]]; then
        [[ -f "$PICK_FILE" ]] || die "model file not found: $PICK_FILE"
        jq -e 'type == "object"' "$PICK_FILE" > /dev/null 2>&1 || die "--model: $PICK_FILE must hold a JSON object"
    fi

    # The seat name is spliced into a script path and run, so it passes the
    # one allowlist, derived from the providers/ registry.
    provider_allowlisted "$SEAT" || die "not a council seat: $SEAT"
    local effort
    effort=$(seat_pick effort)
    [[ -z "$effort" || "$effort" =~ ^[a-z]+$ ]] || die "--model: effort must be lowercase letters, got: $effort"

    SEAT_SECONDS="${COUNCIL_HEADS_UP_SEAT_SECONDS:-60}"
    TURNS="${COUNCIL_HEADS_UP_TURNS:-5}"
    RESULTS="${COUNCIL_HEADS_UP_RESULTS:-8}"
    require_count COUNCIL_HEADS_UP_SEAT_SECONDS "$SEAT_SECONDS"
    require_count COUNCIL_HEADS_UP_TURNS "$TURNS"
    require_count COUNCIL_HEADS_UP_RESULTS "$RESULTS"
    SEAT_SECONDS=$((10#$SEAT_SECONDS))
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
# watchdog does the ticking so a fast command returns at once. At the
# deadline it TERMs the tree as it stands, then KILLs those same pids five
# seconds later: a child that outlives its wrapper is reparented and would
# otherwise be lost to a second tree walk, so the walk happens once, and the
# escalation runs to its end before the seat is reported. Sets RC and
# TIMED_OUT.
run_with_ticks() {
    local limit="$1" pid watchdog fired="${RUN_DIR}/deadline"
    shift
    rm -f "$fired"
    "$@" &
    pid="$!"
    (
        t=0
        while (( t < limit )); do
            sleep 1
            t=$((t + 1))
            kill -0 "$pid" 2>/dev/null || exit 0
        done
        : > "$fired"
        # shellcheck disable=SC2207 # pids hold no spaces or globs
        tree=($(process_tree "$pid"))
        kill -TERM "${tree[@]}" 2>/dev/null || true
        # Up to five seconds of grace, cut short once every pid is gone.
        for _ in 1 2 3 4 5; do
            sleep 1
            any_alive "${tree[@]}" || exit 0
        done
        kill -KILL "${tree[@]}" 2>/dev/null || true
    ) &
    watchdog="$!"
    RC=0
    wait "$pid" || RC=$?
    TIMED_OUT=0
    if [[ -f "$fired" ]]; then
        TIMED_OUT=1
    else
        kill "$watchdog" 2>/dev/null || true
    fi
    wait "$watchdog" 2>/dev/null || true
    rm -f "$fired"
}

# One string field of codex's answer file, on one line, without its trailing
# newline or a Windows jq's \r.
answer_field() {
    jq -r "$2 | tostring | gsub(\"[\\r\\n\\t]+\"; \" \")" "$1" | tr -d '\r'
}

# The seat's pick from --model: "model" or "effort", empty without one.
seat_pick() {
    [[ -n "$PICK_FILE" ]] || { echo ""; return 0; }
    jq -r --arg field "$1" '.[$field] // "" | tostring' "$PICK_FILE"
}

# The variable get_model reads for a seat, so a --model pick lands where the
# provider script and the band's model name both look.
seat_model_var() {
    case "$1" in
        gemini) echo GEMINI_MODEL ;;        openai) echo OPENAI_MODEL ;;
        grok) echo GROK_MODEL ;;            grok-cli) echo GROK_CLI_MODEL ;;
        perplexity) echo PERPLEXITY_MODEL ;; codex) echo CODEX_MODEL ;;
        antigravity) echo ANTIGRAVITY_MODEL ;; kimi) echo KIMI_MODEL ;;
        kimi-cli) echo KIMI_CLI_MODEL ;;    cursor-cli) echo CURSOR_CLI_MODEL ;;
        claude-cli) echo CLAUDE_CLI_MODEL ;; copilot-cli) echo COPILOT_CLI_MODEL ;;
        ollama) echo OLLAMA_MODEL ;;        openrouter) echo OPENROUTER_MODEL ;;
        *) echo "" ;;
    esac
}

# Exports the seat's model pick for the rest of this worker, in the seat's own
# variable.
apply_pick() {
    local model var
    model=$(seat_pick model)
    var=$(seat_model_var "$SEAT")
    [[ -n "$model" && -n "$var" ]] && export "$var=$model"
    return 0
}

codex_call() {
    local effort
    local args=(exec --json --skip-git-repo-check -s read-only)
    [[ -n "${CODEX_MODEL:-}" ]] && args+=(-m "$CODEX_MODEL")
    effort=$(seat_pick effort)
    [[ -n "$effort" ]] && args+=(-c "model_reasoning_effort=\"${effort}\"")
    args+=(--output-schema "${SCRIPT_DIR}/heads-up.schema.json" -o "${RUN_DIR}/seat.out" -)
    ( provider_env_scrub codex; exec codex "${args[@]}" ) \
        < "${RUN_DIR}/prompt.md" > "${RUN_DIR}/seat.events" 2> "${RUN_DIR}/seat.err"
}

# codex: structured output. Success only on a "turn.completed" event, since
# codex exits 0 on SIGTERM. Sets OUTCOME (none|note|error|timeout), DETAIL and,
# for a note, TAG, TOPIC, HEADLINE, TITLE and POINTS_JSON (a JSON array).
ask_codex() {
    local limit="$1" answer="${RUN_DIR}/seat.out"
    run_with_ticks "$limit" codex_call
    if (( TIMED_OUT )); then
        OUTCOME=timeout DETAIL="no answer in ${limit}s"
        return 0
    fi
    if ! grep -q '"type":"turn.completed"' "${RUN_DIR}/seat.events" 2>/dev/null; then
        DETAIL=$(last_error_line "${RUN_DIR}/seat.err")
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
    TITLE=$(answer_field "$answer" '.title // ""')
    POINTS_JSON=$(jq -c '[(.points // [])[] | select(type == "string")]' "$answer")
    TAG=$(answer_field "$answer" '.tag // ""')
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
    local limit="$1"
    ( provider_env_scrub "$SEAT"
      COUNCIL_TIMEOUT="$(( limit + 5 ))" exec bash "${SCRIPT_DIR}/providers/${SEAT}.sh" --prompt-file "${RUN_DIR}/prompt.md" ) \
        > "${RUN_DIR}/seat.out" 2> "${RUN_DIR}/seat.err"
}

# Any other seat: its provider script under the scrubbed env; the first line
# decides. NONE by the builtin's regex; "NOTE: <headline>" then "TAG: ...",
# "TOPIC: ...", "TITLE: ..." and "POINT: ..." lines; anything else is an error, never a note.
ask_text_seat() {
    local limit="$1" first line
    run_with_ticks "$limit" text_call "$limit"
    if (( TIMED_OUT )) || (( RC == 143 )); then
        OUTCOME=timeout DETAIL="no answer in ${limit}s"
        return 0
    fi
    if (( RC != 0 )); then
        DETAIL=$(last_error_line "${RUN_DIR}/seat.err")
        OUTCOME=error DETAIL="exit ${RC}${DETAIL:+: $DETAIL}"
        return 0
    fi
    first=$(head -n 1 "${RUN_DIR}/seat.out" | tr -d '\r')
    # The builtin's NONE test. In a POSIX bracket a backslash is literal, so the
    # brackets are placed by position: "]" first, "[" just before the "-".
    local none_re='^[Nn][Oo][Nn][Ee][[:space:]]*([].!?():;,[-]|$)'
    if [[ "$first" =~ $none_re ]]; then
        OUTCOME=none DETAIL=""
        return 0
    fi
    if [[ "$first" =~ ^NOTE:[[:space:]]*(.+)$ ]]; then
        HEADLINE="${BASH_REMATCH[1]}" TOPIC="" TITLE="" TAG="" POINTS_JSON='[]'
        while IFS= read -r line; do
            line="${line%$'\r'}"
            if [[ -z "$TAG" && "$line" =~ ^TAG:[[:space:]]*(.+)$ ]]; then
                TAG="${BASH_REMATCH[1]}"
            elif [[ -z "$TOPIC" && "$line" =~ ^TOPIC:[[:space:]]*(.+)$ ]]; then
                TOPIC="${BASH_REMATCH[1]}"
            elif [[ -z "$TITLE" && "$line" =~ ^TITLE:[[:space:]]*(.+)$ ]]; then
                TITLE="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^POINT:[[:space:]]*(.+)$ ]]; then
                POINTS_JSON=$(jq -c --arg point "${BASH_REMATCH[1]}" '. + [$point]' <<< "$POINTS_JSON")
            fi
        done < <(tail -n +2 "${RUN_DIR}/seat.out")
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
        --arg seat "$SEAT" --arg model "${NOTE_MODEL:-}" --argjson ms "${NOTE_MS:-0}" --arg topic "${TOPIC:-}" \
        --arg headline "${HEADLINE:-}" --arg title "${TITLE:-}" --argjson points "${POINTS_JSON:-[]}" --arg tag "${TAG:-}" --arg failure "${FAILURE:-}" \
        '{kind: $kind, bytes: $bytes}
         + (if $kind == "note" then {seat: $seat, model: $model, ms: $ms, tag: $tag, topic: $topic, headline: $headline, title: $title, points: $points}
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
    local start ms
    apply_pick
    start=$(now_ms)
    if [[ "$SEAT" == codex ]]; then
        ask_codex "$SEAT_SECONDS"
    else
        ask_text_seat "$SEAT_SECONDS"
    fi
    ms=$(( $(now_ms) - start ))
    record_seat "$SEAT" "$OUTCOME" "$ms" "$DETAIL"
    case "$OUTCOME" in
        note)
            NOTE_MS="$ms" NOTE_MODEL="$(get_model "$SEAT")"
            write_result note
            ;;
        none) write_result none ;;
        *) write_result failed ;;
    esac
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
