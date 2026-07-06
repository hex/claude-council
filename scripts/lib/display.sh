#!/bin/bash
# ABOUTME: Streaming tmux pane + iTerm2 lifecycle features for council responses
# ABOUTME: Source from query-council.sh; capability checks gate everything

# ----- Shipped sibling programs -----

# The markdown renderers and the pane watcher are static files next to this
# lib. Paths resolve absolutely at source time: the tmux pane and the render
# wrapper run as separate processes that inherit the tmux server's PATH and
# cwd, so a relative path would not survive the hop.
COUNCIL_DISPLAY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COUNCIL_RENDER_PL="$COUNCIL_DISPLAY_DIR/render.pl"
COUNCIL_RENDER_PY="$COUNCIL_DISPLAY_DIR/render.py"
COUNCIL_PANE_WATCHER="$COUNCIL_DISPLAY_DIR/pane-watcher.sh"

# ----- Detection -----

is_tmux() {
    [[ -n "${TMUX:-}" ]]
}

is_iterm2_outer() {
    [[ "${LC_TERMINAL:-}" == "iTerm2" || -n "${ITERM_SESSION_ID:-}" ]]
}

# True when a `tmux -V` output string denotes a version that understands
# `split-window -l '<pct>%'` (length as a percentage), added in tmux 3.1.
# Accepts forms like "tmux 3.1", "tmux 3.6a", "tmux next-3.4"; unparseable
# input (empty, non-numeric) is treated as unsupported.
tmux_version_supports_pane() {
    local ver="$1"
    ver=${ver#tmux }
    ver=${ver#next-}
    local major=${ver%%.*}
    local minor=${ver#*.}
    major=${major%%[!0-9]*}
    minor=${minor%%[!0-9]*}
    [[ -n "$major" && -n "$minor" ]] || return 1
    (( 10#$major > 3 || (10#$major == 3 && 10#$minor >= 1) ))
}

should_open_pane() {
    is_tmux || return 1
    [[ "${COUNCIL_NO_PANE:-}" == "1" ]] && return 1
    return 0
}

# ----- iTerm2 wrappers (no-op outside iTerm2) -----

it2_set_tab_color() {
    is_iterm2_outer || return 0
    command -v it2setcolor &>/dev/null || return 0
    it2setcolor tab "$1" 2>/dev/null || true
}

it2_attention() {
    is_iterm2_outer || return 0
    command -v it2attention &>/dev/null || return 0
    it2attention "$1" 2>/dev/null || true
}

# ----- Lifecycle signal helpers (consolidate tty-probe + redirect pattern) -----

# Probes whether a controlling tty is writable. A bare `-w /dev/tty` test passes
# for the device node even when there is no controlling terminal, so we attempt
# an actual no-op write and let the open succeed or fail. stderr is silenced
# BEFORE the write redirect because bash applies redirects left to right: a
# trailing `2>/dev/null` would not catch the failed open of an absent tty, which
# reports "Device not configured" (ENXIO) on the still-live stderr. Callers cache
# the result in COUNCIL_HAS_TTY for the council_signal_* helpers below.
council_probe_tty() {
    : 2>/dev/null >"${1:-/dev/tty}"
}

# Sets the iTerm2 tab color via /dev/tty when a controlling tty is available.
# Caller must have set COUNCIL_HAS_TTY=1 after probing earlier in the flow.
council_signal_state() {
    [[ "${COUNCIL_HAS_TTY:-0}" -eq 1 ]] || return 0
    it2_set_tab_color "$1" >/dev/tty 2>&1
}

council_signal_attention() {
    [[ "${COUNCIL_HAS_TTY:-0}" -eq 1 ]] || return 0
    it2_attention start >/dev/tty 2>&1
}

# ----- Manifest writes -----

pane_status_event() {
    local pane_dir="$1"
    local provider="$2"
    local state="$3"
    local ms="${4:-}"
    local model="${5:-}"
    [[ -d "$pane_dir" ]] || return 0
    printf '%s\t%s\t%s\t%s\n' "$provider" "$state" "$ms" "$model" >> "$pane_dir/status"
}

pane_response_write() {
    local pane_dir="$1"
    local provider="$2"
    local content="$3"
    [[ -d "$pane_dir" ]] || return 0
    mkdir -p "$pane_dir/responses"
    # Write to a dot-prefixed temp then rename: the watcher globs responses/*.md,
    # which never matches the .tmp, so it never renders a half-written file.
    local tmp="$pane_dir/responses/.${provider}.md.tmp"
    printf '%s' "$content" > "$tmp"
    mv -f "$tmp" "$pane_dir/responses/${provider}.md"
}

pane_error_write() {
    local pane_dir="$1"
    local provider="$2"
    local message="$3"
    [[ -d "$pane_dir" ]] || return 0
    mkdir -p "$pane_dir/errors"
    printf '%s' "$message" > "$pane_dir/errors/${provider}.txt"
}


# ----- Pane lifecycle -----

# Maps an OSC 11 background-color reply to "light" or "dark" by perceived
# luminance (Rec. 601), or echoes nothing when the reply holds no parseable
# rgb:R/G/B triplet. Pure (no tty) so every branch is unit-testable. Reads the
# top two hex digits of each channel, so both 8-bit (rgb:RR/GG/BB) and 16-bit
# (rgb:RRRR/GGGG/BBBB) replies work. Threshold: luminance > 127 is light.
council_theme_from_osc_reply() {
    local reply="$1"
    if [[ "$reply" =~ rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+) ]]; then
        local r=$((16#${BASH_REMATCH[1]:0:2}))
        local g=$((16#${BASH_REMATCH[2]:0:2}))
        local b=$((16#${BASH_REMATCH[3]:0:2}))
        local lum=$(( (r * 299 + g * 587 + b * 114) / 1000 ))
        if (( lum > 127 )); then echo light; else echo dark; fi
    fi
}

# Detect the terminal's background theme: "light", "dark", or "unknown".
# Order: explicit COUNCIL_THEME, OSC 11 background-color query on the
# controlling tty, COLORFGBG hint, else unknown. The OSC query outranks
# COLORFGBG because the env var goes stale when the user switches terminal
# themes mid-session, while the query reflects the live background.
# COUNCIL_NO_TTY_QUERY=1 skips the tty query (tests, non-interactive runs).
council_detect_theme() {
    case "${COUNCIL_THEME:-}" in
        light|dark) echo "$COUNCIL_THEME"; return ;;
    esac

    if [[ "${COUNCIL_NO_TTY_QUERY:-0}" != 1 && -r /dev/tty && -w /dev/tty ]]; then
        printf '\033]11;?\033\\' > /dev/tty 2>/dev/null || true
        # Read the reply one byte at a time. bash 3.2 rejects a fractional
        # read -t, and its -d captures only an ST (ESC \) terminator — so a
        # BEL-terminated reply (which many terminals send) was never seen and
        # detection silently no-oped. Break on either terminator; the 1s cap
        # per byte keeps a non-answering terminal from hanging the pane.
        local reply="" ch
        while IFS= read -rs -t 1 -n 1 ch 2>/dev/null; do
            [[ "$ch" == $'\a' ]] && break         # BEL terminator
            reply+="$ch"
            [[ "$reply" == *$'\033\\' ]] && break # ST terminator (ESC \)
        done < /dev/tty
        local theme
        theme=$(council_theme_from_osc_reply "$reply")
        if [[ -n "$theme" ]]; then
            echo "$theme"
            return
        fi
    fi

    # COLORFGBG may only assert "light" (background 7 or 15). It is too
    # unreliable to assert "dark": it goes stale when the user switches themes
    # (reporting e.g. "15;0" on a now-light terminal), and a wrong "dark" pick
    # renders bright-white emphasis that is invisible on a light background. An
    # ambiguous value therefore falls through to "unknown", where emphasis is
    # attribute-only and inherits the terminal's real foreground — readable on
    # any theme.
    if [[ -n "${COLORFGBG:-}" ]]; then
        local bg="${COLORFGBG##*;}"
        case "$bg" in
            7|15) echo light; return ;;
        esac
    fi

    echo unknown
}

# Writes the perl markdown renderer to the given path — dependency-free,
# matches the council's visual language (cyan headings, yellow code, etc).
# Used when no Rich-capable Python exists, and as the Rich wrapper's
# runtime fallback.
# Emphasis adapts to COUNCIL_THEME_RESOLVED: bright white on dark themes,
# black on light themes, attribute-only (inherits foreground) when unknown.
display_write_perl_renderer() {
    local path="$1"
    cp "$COUNCIL_RENDER_PL" "$path"
    chmod +x "$path"
}

# Prints a command line that runs Python with a Rich modern enough for the
# council renderer, preferring an interpreter that already has it over uv's
# on-demand resolve. The probe feature-detects Markdown.elements["heading_open"]
# rather than importing rich: before Rich 13 that key does not exist, tables
# render as collapsed inline text, and the heading override is dead — all with
# exit 0, so an import-only probe would silently pick a mangling renderer.
# Paths are absolute because the pane that runs the result inherits the tmux
# server's PATH, not this shell's.
# The uv probe is bounded by a perl alarm (COUNCIL_RICH_PROBE_TIMEOUT, default
# 10s): a cold cache on a dead network otherwise stalls pane opening ~45s
# before any provider is queried. --no-project keeps uv from resolving — and
# syncing .venv/uv.lock into — whatever pyproject.toml the cwd contains. The
# baked render command adds --offline: a passing probe proves the cache can
# satisfy rich, and rendering must never wait on the network.
# Returns 1 when neither route works.
council_rich_python() {
    local probe='from rich.markdown import Markdown; Markdown.elements["heading_open"]'
    local py uv
    py=$(command -v python3 2>/dev/null) || py=""
    if [[ -n "$py" ]] && "$py" -c "$probe" 2>/dev/null; then
        printf '%q' "$py"
        return 0
    fi
    uv=$(command -v uv 2>/dev/null) || uv=""
    if [[ -n "$uv" ]] && perl -e 'alarm shift; exec @ARGV' "${COUNCIL_RICH_PROBE_TIMEOUT:-10}" \
        "$uv" run --quiet --no-project --with rich python3 -c "$probe" 2>/dev/null; then
        printf '%q %s' "$uv" 'run --quiet --no-project --offline --with rich python3'
        return 0
    fi
    return 1
}

# Writes the Rich markdown renderer: render.py (the renderer), a render.sh
# wrapper that invokes it, and the perl renderer as the wrapper's runtime
# fallback. Rich brings a real layout engine — word-wrapped prose, tables
# fitted to the pane by wrapping inside cells, syntax-highlighted code —
# styled to the council's visual language with the terminal's own palette.
display_write_rich_renderer() {
    local path="$1" py_cmd="$2"
    local base="${path%.sh}"

    display_write_perl_renderer "${base}_fallback.sh"

    cp "$COUNCIL_RENDER_PY" "${base}.py"

    # Runtime vars are escaped (\$); the python command, script, and fallback
    # paths are baked in at write time.
    cat > "$path" <<WRAPEOF
#!/bin/bash
# Captures the Rich render so a runtime failure (uv without its cache or
# network, a Rich API break) falls back to the perl renderer — the pane never
# goes blank. Width is read from the pane tty because a captured renderer
# cannot detect it, and exported as COLUMNS for Rich.
input=\$(cat)
# 2> before < : redirections apply left to right, and a failed /dev/tty open
# (headless run) must land in /dev/null, not leak to the pane.
read -r _ cols < <(stty size 2>/dev/null </dev/tty) || true
# Reject 0, not just non-numbers: stty reports "0 0" on a tty whose winsize
# was never set, and COLUMNS=0 makes Rich emit nothing with exit 0.
[[ "\$cols" =~ ^[1-9][0-9]*\$ ]] || cols=80
if out=\$(printf '%s\n' "\$input" | COLUMNS="\$cols" $py_cmd "${base}.py" 2>/dev/null); then
    printf '%s\n' "\$out"
else
    printf '%s\n' "\$input" | "${base}_fallback.sh"
fi
WRAPEOF
    chmod +x "$path"
}

# Writes the pane's per-response markdown renderer to the given path,
# preferring Rich when a Rich-capable Python exists, else the perl renderer.
# COUNCIL_RENDERER=perl forces the perl path.
display_write_renderer() {
    local path="$1" py_cmd=""
    if [[ "${COUNCIL_RENDERER:-auto}" != "perl" ]]; then
        py_cmd=$(council_rich_python 2>/dev/null) || py_cmd=""
    fi
    if [[ -n "$py_cmd" ]]; then
        display_write_rich_renderer "$path" "$py_cmd"
    else
        display_write_perl_renderer "$path"
    fi
}

# Emits the `-e VAR=VAL` flags to forward into the streaming pane, one token
# per line (read back into an array by the caller — bash 3.2 has no mapfile).
# A new tmux pane inherits the tmux server's environment, not this shell's, so
# values we depend on are passed explicitly. COUNCIL_THEME is forwarded ONLY
# when set: an empty `-e COUNCIL_THEME=` would overwrite a theme the pane could
# otherwise inherit from the server environment or auto-detect via OSC 11.
council_pane_env_args() {
    printf '%s\n' -e "COUNCIL_AUTO_CLOSE=${COUNCIL_AUTO_CLOSE:-0}"
    if [[ -n "${COUNCIL_THEME:-}" ]]; then
        printf '%s\n' -e "COUNCIL_THEME=$COUNCIL_THEME"
    fi
}

# Provider vendor RGB triplet for 24-bit foreground text over the user's unknown
# terminal background — each a mid-tone shade readable on light and dark themes.
# Writes the triplet into the variable named by $1 (printf -v avoids a subshell).
provider_color_rgb() {
    local __out="$1"
    case "$2" in
        gemini|antigravity) printf -v "$__out" '59;130;246'   ;;  # blue-500
        openai|codex)      printf -v "$__out" '100;116;139'  ;;  # slate-500
        grok)              printf -v "$__out" '239;68;68'    ;;  # red-500
        perplexity)        printf -v "$__out" '22;163;74'    ;;  # green-600
        *)                 printf -v "$__out" '113;113;122'  ;;  # zinc-500
    esac
}

# SGR parameter for muted/faint text (separators, the "waiting on" label).
# ANSI 2 (faint) washes out on a light background, so light uses a dark-gray
# 256-color that holds contrast; dark and unknown keep faint. Reads the theme
# the watcher resolved into COUNCIL_THEME_RESOLVED.
council_faint_sgr() {
    [[ "${COUNCIL_THEME_RESOLVED:-}" == light ]] && echo '38;5;240' || echo '2'
}

# Build the colored "waiting on" provider list, fit to <budget> visible columns.
# Names join with ", " in vendor color; a dim "…" stands in for the overflow so
# the rendered line never needs more than <budget> columns. Provider names are
# ASCII, so byte length equals column width. Writes the result into $1.
# Usage: council_waiting_list <out_var> <budget> <name>...
council_waiting_list() {
    local __out="$1" __budget="$2"; shift 2
    # All internals are __-prefixed so the caller's chosen output-var name (and
    # any normal var) cannot collide with and shadow them.
    local __names=("$@") __n=$# __i __vis=0 __first=1 __acc="" __rgb __chunk __p __sep __reserve
    local __mo __r0=$'\033[0m'                            # muted-open / reset sequences
    __mo=$'\033['"$(council_faint_sgr)"m
    for (( __i = 0; __i < __n; __i++ )); do
        __p="${__names[$__i]}"
        __sep=0; (( __first == 0 )) && __sep=2          # width of ", "
        __reserve=0; (( __i < __n - 1 )) && __reserve=2 # leave room for ", …"
        if (( __vis + __sep + ${#__p} + __reserve > __budget )); then
            if (( __first == 0 )); then __acc+="${__mo}, …${__r0}"; else __acc+="${__mo}…${__r0}"; fi
            printf -v "$__out" '%s' "$__acc"
            return
        fi
        if (( __first == 1 )); then __first=0; else __acc+="${__mo}, ${__r0}"; fi
        provider_color_rgb __rgb "$__p"
        printf -v __chunk '\033[1;38;2;%sm%s\033[0m' "$__rgb" "$__p"
        __acc+="$__chunk"
        __vis=$(( __vis + __sep + ${#__p} ))
    done
    printf -v "$__out" '%s' "$__acc"
}

# Opens a tmux split pane with a watcher that streams status + responses.
# Prints the watch directory path to stdout (caller stores in COUNCIL_PANE_DIR).
# Returns 1 if pane could not be opened (caller falls back gracefully).
display_pane_open() {
    should_open_pane || return 1

    local watch_dir
    watch_dir=$(mktemp -d "${TMPDIR:-/tmp}/council_pane.XXXXXX")
    mkdir -p "$watch_dir/responses"

    display_write_renderer "$watch_dir/render.sh"

    # The watcher (pane-watcher.sh) runs inside the tmux pane. It tracks
    # provider state/timing silently; only prints when a response arrives
    # (full colored banner + rendered markdown) or when a provider errors
    # with no response (inline notice). The banner shows timing inline
    # next to the title, so no separate status block is needed.
    local safe_dir safe_watcher safe_lib
    safe_dir=$(printf '%q' "$watch_dir")
    safe_watcher=$(printf '%q' "$COUNCIL_PANE_WATCHER")
    safe_lib=$(printf '%q' "${BASH_SOURCE[0]}")

    local -a target_args=()
    if [[ -n "${TMUX_PANE:-}" ]]; then
        target_args=(-t "$TMUX_PANE")
    fi

    # Forward env the new pane needs explicitly — it inherits the tmux server's
    # environment, not this shell's. council_pane_env_args omits COUNCIL_THEME
    # when unset so it never clobbers an inherited/auto-detected theme.
    local -a pane_env=()
    while IFS= read -r tok; do pane_env+=("$tok"); done < <(council_pane_env_args)
    if ! tmux split-window -h -l '40%' "${target_args[@]}" \
        "${pane_env[@]}" \
        "bash $safe_watcher $safe_dir $safe_lib" >/dev/null 2>&1; then
        if ! tmux_version_supports_pane "$(tmux -V 2>/dev/null)"; then
            printf 'council: streaming pane disabled (tmux >= 3.1 required); showing inline output\n' >&2
        fi
        rm -rf "$watch_dir"
        return 1
    fi

    printf '%s' "$watch_dir"
}

# Signals the watcher to stop polling and switch to interactive close prompt.
display_pane_close() {
    local pane_dir="$1"
    # A missing dir means the watcher already exited and cleaned up;
    # closed is closed, so this never reports failure
    [[ -d "$pane_dir" ]] || return 0
    touch "$pane_dir/.done"
}
