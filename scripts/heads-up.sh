#!/bin/bash
# ABOUTME: Runs the heads-up side-check detached: digests the transcript and asks one seat once
# ABOUTME: Writes result.json then .done into the run dir the mod passed; the mod polls, never waits
#
# Usage: heads-up.sh --run-dir DIR --session ID --seat NAME --avoid-file FILE [--model FILE]
#   --model FILE    JSON object {model?, effort?}, the seat's pick: the model goes to the seat's own
#                   *_MODEL variable for its call; for codex, the model and effort go to the
#                   config.toml of its own home, over the user's
#
# Prints the detached worker's pid and exits 0 at once. Exit 1 before the fork
# when the arguments are unusable (the mod logs stderr once). The worker writes:
#   DIR/pid                           before the fork returns
#   DIR/digest.md, DIR/prompt.md      what left the machine; kept until the mod removes the dir
#   DIR/seat.{out,err,events}         the seat's raw output
#   DIR/seat.usage.json               the tokens the seat's call used, when it reported them (lib/usage.sh)
#   DIR/codex-home/                   codex's CODEX_HOME: config.toml and a link to the user's auth.json;
#                                     codex keeps its session and logs there too
#   DIR/result.json                   {kind:note|none|quota|skipped|failed, bytes, seat?, model?, ms?, tag?, topic?, headline?, title?, points?, detail?,
#                                      seats:[{seat,outcome,ms,detail?,usage?}]}; seats holds the seat's outcome, none
#                                      when the run skipped or failed before asking it; quota is the seat out of
#                                      credits, its words in seats[0].detail; usage is {input,cached,output,reasoning},
#                                      absent when the seat reported none; written to a temp name and moved
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
source "${SCRIPT_DIR}/lib/cli-stderr.sh"
source "${SCRIPT_DIR}/lib/count.sh"
source "${SCRIPT_DIR}/lib/usage.sh"

usage() {
    echo "Usage: heads-up.sh --run-dir DIR --session ID --seat NAME --avoid-file FILE [--model FILE]" >&2
    exit 1
}

die() {
    echo "Error: $*" >&2
    exit 1
}

RUN_DIR="" SESSION_ID="" SEAT="" AVOID_FILE="" PICK_FILE="" PICK_MODEL="" PICK_EFFORT=""

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
    # Absolute, since codex is started inside it with paths that name it.
    RUN_DIR=$(cd "$RUN_DIR" && pwd)
    [[ -f "$AVOID_FILE" ]] || die "avoid file not found: $AVOID_FILE"
    if [[ -n "$PICK_FILE" ]]; then
        [[ -f "$PICK_FILE" ]] || die "model file not found: $PICK_FILE"
        local pick
        pick=$(jq -er 'select(type == "object") | [.model, .effort] | map(. // "" | tostring | gsub("[\t\r\n]"; "")) | join("\t")' "$PICK_FILE" 2> /dev/null) \
            || die "--model: $PICK_FILE must hold a JSON object"
        PICK_MODEL="${pick%%$'\t'*}" PICK_EFFORT="${pick#*$'\t'}"
    fi

    # The seat name is spliced into a script path and run, so it passes the
    # one allowlist, derived from the providers/ registry.
    provider_allowlisted "$SEAT" || die "not a council seat: $SEAT"
    [[ -z "$PICK_EFFORT" || "$PICK_EFFORT" =~ ^[a-z]+$ ]] || die "--model: effort must be lowercase letters, got: $PICK_EFFORT"

    SEAT_SECONDS="${COUNCIL_HEADS_UP_SEAT_SECONDS:-60}"
    TURNS="${COUNCIL_HEADS_UP_TURNS:-5}"
    RESULTS="${COUNCIL_HEADS_UP_RESULTS:-8}"
    require_count COUNCIL_HEADS_UP_SEAT_SECONDS "$SEAT_SECONDS"
    require_count COUNCIL_HEADS_UP_TURNS "$TURNS"
    require_count COUNCIL_HEADS_UP_RESULTS "$RESULTS"
    SEAT_SECONDS=$((10#$SEAT_SECONDS))
}

# The end of a stderr capture, on one line and at most 300 characters, for a
# reason the pane logs once.
error_excerpt() {
    local text
    text=$(stderr_excerpt "$1" 2>/dev/null) || true
    text="${text%"${text##*[![:space:]]}"}"
    if (( ${#text} > 300 )); then text="${text: -300}"; fi
    printf '%s' "$text"
}

# Resolves the transcript and builds digest.md and prompt.md. On failure sets
# FAILURE to the reason and KIND to failed or skipped, and returns 1; the
# worker then writes that kind.
build_digest() {
    local transcript avoid
    if ! transcript=$(bash "${SCRIPT_DIR}/session-transcript.sh" "$SESSION_ID" 2> "${RUN_DIR}/transcript.err"); then
        FAILURE="transcript: $(error_excerpt "${RUN_DIR}/transcript.err")"
        return 1
    fi
    if ! bash "${SCRIPT_DIR}/transcript-digest.sh" --turns "last:${TURNS}" \
            --tool-results "$RESULTS" --tool-result-chars 2000 -- "$transcript" \
            > "${RUN_DIR}/digest.md" 2> "${RUN_DIR}/digest.err"; then
        FAILURE="digest: $(error_excerpt "${RUN_DIR}/digest.err")"
        return 1
    fi
    # An empty digest: the window matched no prompt (a teammate pane, an
    # SDK-driven session: nobody to warn) or holds nothing shown yet (a
    # conversation cs just opened, before Claude's first reply). Either way
    # there is nothing to review: the check is skipped, not failed.
    if [[ ! -s "${RUN_DIR}/digest.md" ]]; then
        FAILURE="digest: nothing in the window to review" KIND=skipped
        return 1
    fi
    avoid=$(cat "$AVOID_FILE")
    [[ -n "$avoid" ]] || avoid="(nothing yet)"
    interpolate_template "$(load_prompt_template heads-up)" \
        "AVOID=${avoid}" "DIGEST=$(cat "${RUN_DIR}/digest.md")" > "${RUN_DIR}/prompt.md"
    BYTES=$(wc -c < "${RUN_DIR}/prompt.md" | tr -d ' ')
}

# One string field of codex's answer file, on one line, without its trailing
# newline or a Windows jq's \r.
answer_field() {
    jq -r "$2 | tostring | gsub(\"[\\r\\n\\t]+\"; \" \")" "$1" | tr -d '\r'
}

# Exports the seat's model pick for the rest of this worker, in the variable
# get_model reads for it, so the provider script and the band's model name both
# see the pick.
apply_pick() {
    [[ -n "$PICK_MODEL" ]] && export "$(provider_env_prefix "$SEAT")_MODEL=$PICK_MODEL"
    return 0
}

# One key of codex's config.toml, its value a TOML basic string: JSON's string
# escapes are all valid there, DEL and the other control characters included.
toml_line() {
    printf '%s = %s\n' "$1" "$(jq -rn --arg v "$2" '$v | tojson')"
}

# Builds the home codex runs the check under, so none of the user's plugins,
# hooks, AGENTS.md, skills, memories or MCP servers ride along: config.toml
# holds the model and effort and switches the rest off. The model is the pick,
# else the user's; the effort likewise; a key neither names is left out for
# codex to choose. The login is linked in by link_login.
# Usage: codex_home USER_HOME
codex_home() {
    local user_home="$1" home="${RUN_DIR}/codex-home" model effort
    model="${CODEX_MODEL:-$(toml_value "${user_home}/config.toml" "" model)}"
    effort="${PICK_EFFORT:-$(toml_value "${user_home}/config.toml" "" model_reasoning_effort)}"
    mkdir -p "$home"
    {
        [[ -n "$model" ]] && toml_line model "$model"
        [[ -n "$effort" ]] && toml_line model_reasoning_effort "$effort"
        [[ -n "$model$effort" ]] && echo
        cat <<'EOF'
[skills]
include_instructions = false

[skills.bundled]
enabled = false

[features]
plugins = false
apps = false
hooks = false
memories = false
EOF
    } > "${home}/config.toml"
}

# Why the user's codex setup cannot be carried into the check's own home, on
# one line; nothing when it can. Without a file login (the keyring store, or
# not logged in) there is nothing to link to.
# Usage: codex_home_refusal USER_HOME
codex_home_refusal() {
    local user_home="$1" config="${1}/config.toml" provider profile
    if [[ ! -f "${user_home}/auth.json" ]]; then
        printf "codex: no auth.json in %s; the heads-up seat needs codex's file credential store" "$user_home"
        return 0
    fi
    # A custom provider's table can carry headers, an env key the scrub drops
    # and nested tables, so it is refused rather than copied.
    provider=$(toml_value "$config" "" model_provider)
    if [[ -n "$provider" && "$provider" != openai ]]; then
        printf "codex: %s sets model_provider \"%s\"; the heads-up seat runs codex's built-in openai provider only" "$config" "$provider"
        return 0
    fi
    # A profile can name its own model, effort and provider; the home copies
    # the root keys only, so it would run something other than the user's codex.
    profile=$(toml_value "$config" "" profile)
    if [[ -n "$profile" ]]; then
        printf "codex: %s sets profile \"%s\"; the heads-up seat reads only the root model and effort" "$config" "$profile"
    fi
}

# Links the user's auth.json into the check's home. codex refreshes its token
# by rewriting auth.json in place, so through a link the refresh lands in the
# user's login; in a copy it would vanish with the run dir. A hard link where a
# symlink is refused (Windows without developer mode) or comes out as a copy
# (as Git Bash can make one).
# Usage: link_login USER_HOME
link_login() {
    local login="${1}/auth.json" link="${RUN_DIR}/codex-home/auth.json"
    if ln -s "$login" "$link" 2> /dev/null && [[ "$link" -ef "$login" ]]; then
        return 0
    fi
    rm -f "$link"
    ln "$login" "$link" 2> "${RUN_DIR}/link.err"
}

# codex in the run dir, so no repository's AGENTS.md or skills load.
codex_call() {
    local args=(exec --json --skip-git-repo-check -s read-only
        --output-schema "${SCRIPT_DIR}/heads-up.schema.json" -o "${RUN_DIR}/seat.out" -)
    ( provider_env_scrub codex
      cd "$RUN_DIR"
      CODEX_HOME="${RUN_DIR}/codex-home" exec codex "${args[@]}" ) \
        < "${RUN_DIR}/prompt.md" > "${RUN_DIR}/seat.events" 2> "${RUN_DIR}/seat.err"
}

# Wording in a turn.failed message that means the seat's account has run dry,
# matched case-insensitively: every later check this session would fail the same way.
QUOTA_WORDING='out of credits|usage limit'

is_quota() {
    grep -qiE -- "$QUOTA_WORDING" <<< "$1"
}

# The message of codex's last turn.failed event, on one line and at most 300
# characters; empty when there is none. A line that is not JSON is passed over.
turn_failure() {
    local text
    text=$(jq -Rr 'fromjson? | select(type == "object" and .type == "turn.failed") | .error.message? | strings | gsub("[\\r\\n\\t]+"; " ")' "$1" | tail -n 1 | tr -d '\r')
    printf '%s' "${text:0:300}"
}

# codex's last turn.completed usage, into the seat's usage file. input_tokens
# counts the cached tokens and cache writes, output_tokens the reasoning.
codex_usage() {
    COUNCIL_USAGE_FILE="${RUN_DIR}/seat.usage.json" emit_usage -nR \
        '[inputs | fromjson? | objects | select(.type == "turn.completed")] | last | .usage
         | {input: .input_tokens, cached: .cached_input_tokens, output: .output_tokens, reasoning: .reasoning_output_tokens}' \
        "${RUN_DIR}/seat.events"
}

# codex: structured output. Success only on a "turn.completed" event, since
# codex exits 0 on SIGTERM. Sets OUTCOME (none|note|error|timeout|quota), DETAIL and,
# for a note, TAG, TOPIC, HEADLINE, TITLE and POINTS_JSON (a JSON array).
# A turn.failed message is the reason when codex gave one; its stderr can hold
# unrelated noise (MCP servers it failed to reach), so it is only the fallback.
ask_codex() {
    local limit="$1" answer="${RUN_DIR}/seat.out" rc=0 user_home="${CODEX_HOME:-$HOME/.codex}"
    DETAIL=$(codex_home_refusal "$user_home")
    if [[ -n "$DETAIL" ]]; then
        OUTCOME=error
        return 0
    fi
    codex_home "$user_home"
    if ! link_login "$user_home"; then
        OUTCOME=error DETAIL="codex: could not link ${user_home}/auth.json into ${RUN_DIR}/codex-home: $(error_excerpt "${RUN_DIR}/link.err")"
        return 0
    fi
    run_with_deadline "$limit" codex_call || rc=$?
    codex_usage
    if (( rc == 143 )); then
        OUTCOME=timeout DETAIL="no answer in ${limit}s"
        return 0
    fi
    if ! grep -q '"type":"turn.completed"' "${RUN_DIR}/seat.events" 2>/dev/null; then
        DETAIL=$(turn_failure "${RUN_DIR}/seat.events")
        if [[ -n "$DETAIL" ]]; then
            OUTCOME=error
            if is_quota "$DETAIL"; then OUTCOME=quota; fi
            return 0
        fi
        DETAIL=$(error_excerpt "${RUN_DIR}/seat.err")
        OUTCOME=error DETAIL="exit ${rc} without turn.completed${DETAIL:+: $DETAIL}"
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
# first would decide whether the seat logs a timeout or an error. A provider
# that reports its tokens writes them to COUNCIL_USAGE_FILE.
text_call() {
    local limit="$1"
    ( provider_env_scrub "$SEAT"
      COUNCIL_TIMEOUT="$(( limit + 5 ))" COUNCIL_USAGE_FILE="${RUN_DIR}/seat.usage.json" \
          exec bash "${SCRIPT_DIR}/providers/${SEAT}.sh" --prompt-file "${RUN_DIR}/prompt.md" ) \
        > "${RUN_DIR}/seat.out" 2> "${RUN_DIR}/seat.err"
}

# Any other seat: its provider script under the scrubbed env; the first line
# decides. NONE by the builtin's regex; "NOTE: <headline>" then "TAG: ...",
# "TOPIC: ...", "TITLE: ..." and "POINT: ..." lines; anything else is an error, never a note.
ask_text_seat() {
    local limit="$1" first line rc=0 points=()
    run_with_deadline "$limit" text_call "$limit" || rc=$?
    if (( rc == 143 )); then
        OUTCOME=timeout DETAIL="no answer in ${limit}s"
        return 0
    fi
    if (( rc != 0 )); then
        DETAIL=$(error_excerpt "${RUN_DIR}/seat.err")
        OUTCOME=error DETAIL="exit ${rc}${DETAIL:+: $DETAIL}"
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
        HEADLINE="${BASH_REMATCH[1]}" TOPIC="" TITLE="" TAG=""
        while IFS= read -r line; do
            line="${line%$'\r'}"
            if [[ -z "$TAG" && "$line" =~ ^TAG:[[:space:]]*(.+)$ ]]; then
                TAG="${BASH_REMATCH[1]}"
            elif [[ -z "$TOPIC" && "$line" =~ ^TOPIC:[[:space:]]*(.+)$ ]]; then
                TOPIC="${BASH_REMATCH[1]}"
            elif [[ -z "$TITLE" && "$line" =~ ^TITLE:[[:space:]]*(.+)$ ]]; then
                TITLE="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^POINT:[[:space:]]*(.+)$ ]]; then
                points+=("${BASH_REMATCH[1]}")
            fi
        done < <(tail -n +2 "${RUN_DIR}/seat.out")
        POINTS_JSON=$(jq -nc '$ARGS.positional' --args -- ${points[@]+"${points[@]}"})
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

# The seat's outcome, with the tokens its call used when it reported them. A
# usage file off the record's shape is left out rather than failing the check.
record_seat() {
    local usage
    usage=$(jq -c "$USAGE_SHAPE" "${RUN_DIR}/seat.usage.json" 2>/dev/null) || usage=""
    SEATS_JSON=$(jq -c --arg seat "$1" --arg outcome "$2" --argjson ms "$3" --arg detail "$4" --argjson usage "${usage:-null}" \
        '. + [{seat: $seat, outcome: $outcome, ms: $ms} + (if $detail == "" then {} else {detail: $detail} end)
              + (if $usage == null then {} else {usage: $usage} end)]' \
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
    FAILURE="" BYTES=0 KIND=failed
    if ! build_digest; then
        write_result "$KIND"
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
        quota) write_result quota ;;
        *) write_result failed ;;
    esac
}

main() {
    parse_args "$@"
    ( worker ) </dev/null >/dev/null 2>&1 &
    local pid="$!"
    echo "$pid" > "${RUN_DIR}/pid"
    echo "$pid"
}

main "$@"
