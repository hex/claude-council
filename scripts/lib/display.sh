#!/bin/bash
# ABOUTME: Streaming tmux pane + iTerm2 lifecycle features for council responses
# ABOUTME: Source from query-council.sh; capability checks gate everything

# ----- Detection -----

is_tmux() {
    [[ -n "${TMUX:-}" ]]
}

is_iterm2_outer() {
    [[ "${LC_TERMINAL:-}" == "iTerm2" || -n "${ITERM_SESSION_ID:-}" ]]
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

it2_set_mark() {
    is_iterm2_outer || return 0
    if [[ "${TERM:-}" == screen* || "${TERM:-}" == tmux* ]]; then
        printf '\033Ptmux;\033\033]1337;SetMark\a\033\\'
    else
        printf '\033]1337;SetMark\a'
    fi
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
    [[ -d "$pane_dir" ]] || return 1
    printf '%s\t%s\t%s\t%s\n' "$provider" "$state" "$ms" "$model" >> "$pane_dir/status"
}

pane_response_write() {
    local pane_dir="$1"
    local provider="$2"
    local content="$3"
    [[ -d "$pane_dir" ]] || return 1
    mkdir -p "$pane_dir/responses"
    printf '%s' "$content" > "$pane_dir/responses/${provider}.md"
}

pane_error_write() {
    local pane_dir="$1"
    local provider="$2"
    local message="$3"
    [[ -d "$pane_dir" ]] || return 1
    mkdir -p "$pane_dir/errors"
    printf '%s' "$message" > "$pane_dir/errors/${provider}.txt"
}


# ----- Pane lifecycle -----

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
        local reply=""
        printf '\033]11;?\033\\' > /dev/tty 2>/dev/null || true
        IFS= read -rs -t 0.2 -d $'\\' reply < /dev/tty 2>/dev/null || true
        if [[ "$reply" =~ rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+) ]]; then
            local r=$((16#${BASH_REMATCH[1]:0:2}))
            local g=$((16#${BASH_REMATCH[2]:0:2}))
            local b=$((16#${BASH_REMATCH[3]:0:2}))
            local lum=$(( (r * 299 + g * 587 + b * 114) / 1000 ))
            if (( lum > 127 )); then echo light; else echo dark; fi
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

# Writes the per-response markdown renderer to the given path.
# In-house perl-based renderer — fast, dependency-free, matches the
# council's visual language (cyan headings, yellow code, etc).
# Emphasis adapts to COUNCIL_THEME_RESOLVED: bright white on dark themes,
# black on light themes, attribute-only (inherits foreground) when unknown.
display_write_renderer() {
    local path="$1"
    cat > "$path" <<'RENDEREOF'
#!/usr/bin/env perl
# ANSI: 1=bold 3=italic 4=under 7=inverse 9=strikethrough
# 36=cyan 33=yellow 35=magenta 90=bright-black 96=bright-cyan 97=bright-white
my $theme  = $ENV{COUNCIL_THEME_RESOLVED} // 'unknown';
my $strong = $theme eq 'dark' ? '1;97' : $theme eq 'light' ? '1;30' : '1';
my $em     = $theme eq 'dark' ? '3;97' : $theme eq 'light' ? '3;30' : '3';
# Headings/table headers: bright cyan pops on dark but washes out on light,
# where plain cyan holds contrast (also the safe pick when unknown)
my $head   = $theme eq 'dark' ? '96' : '36';
my $in_code = 0;
my $in_think = 0;
my @table_buf;
my $had_header_sep = 0;
my $cols = `tput cols 2>/dev/null` || 80;
chomp $cols;
$cols = 80 if $cols !~ /^\d+$/ || $cols < 20;

sub apply_inline {
    my $s = shift;
    $s =~ s/`([^`]+)`/\033[7;33m$1\033[0m/g;
    $s =~ s/\[([^\]]+)\]\(([^)]+)\)/\033[4;36m$1\033[24m \033[90m($2)\033[0m/g;
    $s =~ s/~~([^~]+)~~/\033[9m$1\033[29m/g;
    $s =~ s/\*\*([^*]+)\*\*/\033[${strong}m$1\033[0m/g;
    $s =~ s/(?<!\*)\*([^*]+)\*(?!\*)/\033[${em}m$1\033[0m/g;
    return $s;
}

sub visual_width {
    my $s = shift;
    $s =~ s/\033\[[\d;]*m//g;  # strip ANSI codes
    return length($s);
}

sub flush_table {
    return unless @table_buf;
    my @widths;
    for my $cells (@table_buf) {
        for my $i (0 .. $#$cells) {
            my $w = visual_width($cells->[$i]);
            $widths[$i] = $w if !defined $widths[$i] || $w > $widths[$i];
        }
    }
    # Borderless table: only inner separators (no left/right/top/bottom borders).
    my $sep_v = " \033[90m│\033[0m ";
    my $hsep  = join("\033[90m─┼─\033[0m",
                     map { "\033[90m" . ("─" x $_) . "\033[0m" } @widths) . "\n";

    for my $row_idx (0 .. $#table_buf) {
        my $cells = $table_buf[$row_idx];
        my $is_header = ($row_idx == 0 && $had_header_sep);
        my @parts;
        for my $j (0 .. $#widths) {
            my $cell = $cells->[$j] // '';
            my $pad = ' ' x ($widths[$j] - visual_width($cell));
            if ($is_header) { push @parts, "\033[1;${head}m$cell\033[0m$pad"; }
            else            { push @parts, "$cell$pad"; }
        }
        print join($sep_v, @parts), "\n";
        print $hsep if $is_header && @table_buf > 1;
    }
    @table_buf = ();
    $had_header_sep = 0;
}

while (my $line = <STDIN>) {
    # ----- Reasoning blocks -----
    if ($line =~ /^\s*<think>/) {
        flush_table();
        $in_think = 1;
        print "\033[2;3m▸ thinking\033[0m\n";
        next;
    }
    if ($line =~ /^\s*<\/think>/) {
        $in_think = 0;
        print "\033[2m└─\033[0m\n";
        next;
    }
    if ($in_think) {
        next if $line =~ /^\s*$/;
        chomp(my $content = $line);
        my $wrap_cols = $cols - 4;  # reserve "│ " prefix + a margin
        while (length($content) > $wrap_cols) {
            my $break = rindex($content, ' ', $wrap_cols);
            $break = $wrap_cols if $break < 1;
            my $piece = substr($content, 0, $break);
            $content = substr($content, $break);
            $content =~ s/^\s+//;
            print "\033[2m│\033[0m \033[2;3m$piece\033[0m\n";
        }
        print "\033[2m│\033[0m \033[2;3m$content\033[0m\n";
        next;
    }

    # ----- Fenced code blocks -----
    if ($line =~ /^```(\w*)/) {
        flush_table();
        if ($in_code) { print "\033[33m└─────\033[0m\n"; $in_code = 0; }
        else          { print "\033[33m┌───── \033[0m\033[33;3m$1\033[0m\n"; $in_code = 1; }
        next;
    }
    if ($in_code) { print "\033[33m│\033[0m  $line"; next; }

    # ----- Tables — buffer rows, flush on first non-table line -----
    if ($line =~ /^\s*\|.*\|\s*$/) {
        # Separator row → marks the row above as header
        if ($line =~ /^\s*\|[\s\-:|]+\|\s*$/) {
            $had_header_sep = 1;
            next;
        }
        my $row = $line;
        chomp $row;
        $row =~ s/^\s*\|//;
        $row =~ s/\|\s*$//;
        my @cells = split /\s*\|\s*/, $row;
        s/^\s+|\s+$//g for @cells;
        $_ = apply_inline($_) for @cells;
        push @table_buf, \@cells;
        next;
    }
    flush_table();

    # ----- Non-table line: apply inline subs first, then block subs -----
    $line = apply_inline($line);
    $line =~ s/^###### (.*)$/\033[2;3m$1\033[0m/;
    $line =~ s/^##### (.*)$/\033[1;3m$1\033[0m/;
    $line =~ s/^#### (.*)$/\033[1m$1\033[0m/;
    $line =~ s/^### (.*)$/\033[1;36m$1\033[0m/;
    $line =~ s/^## (.*)$/\033[1;${head}m$1\033[0m/;
    $line =~ s/^# (.*)$/\033[1;7;${head}m $1 \033[0m/;
    $line =~ s/^(\s*)(\d+)\. /$1\033[36m$2.\033[0m /;
    $line =~ s/^(\s*)[-*] /$1\033[36m•\033[0m /;
    $line =~ s/^> (.*)$/\033[35m▌\033[0m \033[3m$1\033[0m/;
    $line =~ s/^---+$/\033[90m──────────────────────────────\033[0m/;
    print $line;
}
flush_table();
RENDEREOF
    chmod +x "$path"
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
        gemini|gemini-cli) printf -v "$__out" '59;130;246'   ;;  # blue-500
        openai|codex)      printf -v "$__out" '100;116;139'  ;;  # slate-500
        grok)              printf -v "$__out" '239;68;68'    ;;  # red-500
        perplexity)        printf -v "$__out" '22;163;74'    ;;  # green-600
        *)                 printf -v "$__out" '113;113;122'  ;;  # zinc-500
    esac
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
    for (( __i = 0; __i < __n; __i++ )); do
        __p="${__names[$__i]}"
        __sep=0; (( __first == 0 )) && __sep=2          # width of ", "
        __reserve=0; (( __i < __n - 1 )) && __reserve=2 # leave room for ", …"
        if (( __vis + __sep + ${#__p} + __reserve > __budget )); then
            if (( __first == 0 )); then __acc+=$'\033[2m, …\033[0m'; else __acc+=$'\033[2m…\033[0m'; fi
            printf -v "$__out" '%s' "$__acc"
            return
        fi
        if (( __first == 1 )); then __first=0; else __acc+=$'\033[2m, \033[0m'; fi
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

    # Watcher script (runs inside the tmux pane).
    # Tracks provider state/timing silently; only prints when a response
    # arrives (full colored banner + rendered markdown) or when a provider
    # errors with no response (inline notice). The banner shows timing
    # inline next to the title, so no separate status block is needed.
    cat > "$watch_dir/watcher.sh" <<'WATCHEREOF'
#!/bin/bash
WATCH="$1"
DISPLAY_LIB="$2"
trap 'rm -rf "$WATCH"' EXIT

# render.sh picks emphasis colors by theme. Detection runs here because the
# pane's own tty answers the OSC 11 background query; an explicit
# COUNCIL_THEME (forwarded via tmux -e) wins inside council_detect_theme.
source "$DISPLAY_LIB"
COUNCIL_THEME_RESOLVED=$(council_detect_theme)
export COUNCIL_THEME_RESOLVED

# Parallel arrays keyed by index in provider_names. bash 3.2 has no
# associative arrays; provider_index() does linear lookup and registers
# new entries on first sight. With <=6 providers, this is effectively free.
provider_names=()
provider_states=()
provider_timings=()
provider_models=()

# Writes the index of $2 in provider_names into the variable named by $1,
# registering a new entry if absent. printf -v avoids the command-substitution
# subshell that would lose array mutations.
provider_index() {
    local __out="$1" name="$2" i=0
    while [[ $i -lt ${#provider_names[@]} ]]; do
        [[ "${provider_names[$i]}" == "$name" ]] && { printf -v "$__out" '%d' "$i"; return; }
        i=$((i + 1))
    done
    provider_names[$i]="$name"
    printf -v "$__out" '%d' "$i"
}

status_lines_processed=0
shown_responses=""
spinner_frame=0
SPINNERS=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

draw_loading() {
    local pending=() i=0
    while [[ $i -lt ${#provider_names[@]} ]]; do
        [[ "${provider_states[$i]}" == "querying" ]] && pending+=("${provider_names[$i]}")
        i=$((i + 1))
    done
    [[ ${#pending[@]} -eq 0 ]] && return 0
    local frame="${SPINNERS[$((spinner_frame % ${#SPINNERS[@]}))]}"

    # Fit the provider list to the pane. The prefix
    # "   <spinner>   council is waiting on   " is 31 visible columns; reserve
    # one more so the line never reaches the right margin. Live width comes from
    # stty size (the pane tty's winsize) — tput cols returns the static terminfo
    # default (usually 80), not the actual pane width.
    local cols=""; read -r _ cols < <(stty size 2>/dev/null) || true
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    local budget=$(( cols - 32 )); (( budget < 8 )) && budget=8
    local list; council_waiting_list list "$budget" "${pending[@]}"

    local rgb_first
    provider_color_rgb rgb_first "${pending[0]}"
    # Disable autowrap (DECAWM, \033[?7l) while drawing the line: a waiting list
    # wider than the pane must CLIP at the right margin, not wrap. \r\033[K only
    # reclaims the current physical row, so a wrapped line would leave a stale
    # row every frame (a waterfall of spinner lines). Re-enable (\033[?7h) after
    # so response text below still wraps for readability.
    printf '\r\033[K\033[?7l   \033[1;38;2;%sm%s\033[0m   \033[2mcouncil is waiting on\033[0m   %s\033[?7h' \
        "$rgb_first" "$frame" "$list"
}

clear_loading() {
    printf '\r\033[K'
}

# Build a banner line into the variable named by $1.
# Includes provider title, model name (if known), and status in italic parens.
# Uses 24-bit RGB for theme-independent WCAG AA contrast.
build_banner_line() {
    local out_var="$1" name="$2"
    local idx
    provider_index idx "$name"
    local state="${provider_states[$idx]}"
    local ms="${provider_timings[$idx]}"
    local model="${provider_models[$idx]}"
    # accent is a lighter shade of bg, used for the model name (secondary text).
    local bg fg accent
    case "$name" in
        gemini|gemini-cli) bg='30;64;175';   fg='255;255;255'; accent='147;197;253' ;;  # blue-700/300
        openai|codex)      bg='229;231;235'; fg='31;41;55';    accent='100;116;139' ;;  # gray-200/slate-500
        grok)              bg='185;28;28';   fg='255;255;255'; accent='252;165;165' ;;  # red-700/300
        perplexity)        bg='21;128;61';   fg='255;255;255'; accent='134;239;172' ;;  # green-700/300
        *)                 bg='55;65;81';    fg='255;255;255'; accent='156;163;175' ;;  # gray-700/400
    esac
    local upper
    upper=$(echo "$name" | tr '[:lower:]' '[:upper:]')

    # Model name in the accent (lighter bg) shade, then restore primary fg.
    local model_inline=""
    if [[ -n "$model" ]]; then
        printf -v model_inline ' \033[22;3;38;2;%sm%s\033[23;1;38;2;%sm' "$accent" "$model" "$fg"
    fi

    # Format timing — switch to seconds (1 decimal) at >= 1s for readability.
    local timing_str=""
    if [[ -n "$ms" && "$ms" =~ ^[0-9]+$ ]]; then
        if (( ms >= 1000 )); then
            printf -v timing_str '%d.%ds' $((ms/1000)) $((ms%1000/100))
        else
            timing_str="${ms}ms"
        fi
    fi

    local status_inline=""
    case "$state" in
        complete) printf -v status_inline ' \033[22;3m(%s)\033[23;1m' "$timing_str" ;;
        cached)   printf -v status_inline ' \033[22;3m(cached)\033[23;1m' ;;
        error)    printf -v status_inline ' \033[22;3;31m(error)\033[23;1m' ;;
    esac

    printf -v "$out_var" '\033[1;38;2;%s;48;2;%sm  %s%s%s  \033[K\033[0m' \
        "$fg" "$bg" "$upper" "$model_inline" "$status_inline"
}


while true; do
    # 1. Track status events silently (state + timing for banners later);
    #    print only error notices since they don't get a response file.
    if [[ -f "$WATCH/status" ]]; then
        new_total=$(wc -l < "$WATCH/status" | tr -d ' ')
        while [[ $status_lines_processed -lt $new_total ]]; do
            status_lines_processed=$((status_lines_processed + 1))
            line=$(sed -n "${status_lines_processed}p" "$WATCH/status")
            IFS=$'\t' read -r provider state ms model <<<"$line"
            provider_index idx "$provider"
            provider_states[$idx]="$state"
            [[ -n "$ms" ]] && provider_timings[$idx]="$ms"
            [[ -n "$model" ]] && provider_models[$idx]="$model"
            if [[ "$state" == "error" ]]; then
                clear_loading
                printf '\n\033[1;38;2;185;28;28m✗ %s error\033[0m\n' "$provider"
                if [[ -f "$WATCH/errors/${provider}.txt" ]]; then
                    while IFS= read -r err_line; do
                        printf '   \033[2;38;2;252;165;165m%s\033[0m\n' "$err_line"
                    done < "$WATCH/errors/${provider}.txt"
                fi
                echo
            fi
        done
    fi

    # 2. Render new responses with full banner above each
    new_responses=()
    for f in "$WATCH/responses/"*.md; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .md)
        case "$shown_responses" in
            *"|$name|"*) continue ;;
        esac
        new_responses+=("$f")
        shown_responses="$shown_responses|$name|"
    done
    if [[ ${#new_responses[@]} -gt 0 ]]; then
        clear_loading
        for f in "${new_responses[@]}"; do
            name=$(basename "$f" .md)
            printf '\033Ptmux;\033\033]1337;SetMark\a\033\\'
            build_banner_line banner_line "$name"
            printf '\n\n%s\n\n' "$banner_line"
            "$WATCH/render.sh" < "$f"
            # Extra blank lines so the loading line below has top margin.
            printf '\n\n'
        done
    fi

    # 3. Animated loading line at the very bottom (single-line in-place update)
    spinner_frame=$((spinner_frame + 1))
    draw_loading

    [[ -f "$WATCH/.done" ]] && break
    sleep 0.12
done

clear_loading

# Skip the keypress wait for tests/demos that set COUNCIL_AUTO_CLOSE=1.
# Interactive runs default to the keypress wait so users can scroll back.
if [[ "${COUNCIL_AUTO_CLOSE:-0}" != 1 ]]; then
    printf '\n\033[2m[esc/ctrl-d] close\033[0m '
    esc=$(printf '\033')
    while true; do
        read -n1 -s -r key || break
        [[ "$key" = "$esc" ]] && break
    done
fi
WATCHEREOF
    chmod +x "$watch_dir/watcher.sh"

    local safe_dir safe_watcher safe_lib
    safe_dir=$(printf '%q' "$watch_dir")
    safe_watcher=$(printf '%q' "$watch_dir/watcher.sh")
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
