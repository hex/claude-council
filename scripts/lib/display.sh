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

# Opens a tmux split pane with a watcher that streams status + responses.
# Prints the watch directory path to stdout (caller stores in COUNCIL_PANE_DIR).
# Returns 1 if pane could not be opened (caller falls back gracefully).
display_pane_open() {
    should_open_pane || return 1

    local watch_dir
    watch_dir=$(mktemp -d "${TMPDIR:-/tmp}/council_pane.XXXXXX")
    mkdir -p "$watch_dir/responses"

    # Per-response renderer (called by watcher with response file on stdin).
    # In-house perl-based markdown renderer — fast, dependency-free, matches
    # the council's visual language (cyan headings, yellow code, etc).
    cat > "$watch_dir/render.sh" <<'RENDEREOF'
#!/usr/bin/env perl
# ANSI: 1=bold 3=italic 4=under 7=inverse 9=strikethrough
# 36=cyan 33=yellow 35=magenta 90=bright-black 96=bright-cyan 97=bright-white
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
    $s =~ s/\*\*([^*]+)\*\*/\033[1;97m$1\033[0m/g;
    $s =~ s/(?<!\*)\*([^*]+)\*(?!\*)/\033[3;97m$1\033[0m/g;
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
            if ($is_header) { push @parts, "\033[1;96m$cell\033[0m$pad"; }
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
    $line =~ s/^## (.*)$/\033[1;96m$1\033[0m/;
    $line =~ s/^# (.*)$/\033[1;7;96m $1 \033[0m/;
    $line =~ s/^(\s*)(\d+)\. /$1\033[36m$2.\033[0m /;
    $line =~ s/^(\s*)[-*] /$1\033[36m•\033[0m /;
    $line =~ s/^> (.*)$/\033[35m▌\033[0m \033[3m$1\033[0m/;
    $line =~ s/^---+$/\033[90m──────────────────────────────\033[0m/;
    print $line;
}
flush_table();
RENDEREOF
    chmod +x "$watch_dir/render.sh"

    # Watcher script (runs inside the tmux pane).
    # Tracks provider state/timing silently; only prints when a response
    # arrives (full colored banner + rendered markdown) or when a provider
    # errors with no response (inline notice). The banner shows timing
    # inline next to the title, so no separate status block is needed.
    cat > "$watch_dir/watcher.sh" <<'WATCHEREOF'
#!/bin/bash
WATCH="$1"
trap 'rm -rf "$WATCH"' EXIT

declare -A provider_state
declare -A provider_timing
declare -A provider_model
status_lines_processed=0
shown_responses=""
spinner_frame=0
SPINNERS=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# Writes the provider's RGB triplet (for OSC 38;2;R;G;B) into the named
# variable. Avoids subshell forks by using printf -v.
provider_color_rgb() {
    local __out="$1"
    case "$2" in
        gemini)     printf -v "$__out" '59;130;246'   ;;
        openai)     printf -v "$__out" '229;231;235'  ;;
        grok)       printf -v "$__out" '248;113;113'  ;;
        perplexity) printf -v "$__out" '74;222;128'   ;;
        *)          printf -v "$__out" '156;163;175'  ;;
    esac
}

draw_loading() {
    local pending=()
    for p in "${!provider_state[@]}"; do
        [[ "${provider_state[$p]}" == "querying" ]] && pending+=("$p")
    done
    [[ ${#pending[@]} -eq 0 ]] && return 0
    local frame="${SPINNERS[$((spinner_frame % ${#SPINNERS[@]}))]}"

    local list="" first=1 rgb chunk
    for p in "${pending[@]}"; do
        provider_color_rgb rgb "$p"
        if [[ $first -eq 1 ]]; then
            first=0
        else
            list+=$'\033[2m, \033[0m'
        fi
        printf -v chunk '\033[1;38;2;%sm%s\033[0m' "$rgb" "$p"
        list+="$chunk"
    done

    local rgb_first
    provider_color_rgb rgb_first "${pending[0]}"
    printf '\r\033[K   \033[1;38;2;%sm%s\033[0m   \033[2mcouncil is waiting on\033[0m   %s' \
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
    local state="${provider_state[$name]:-}"
    local ms="${provider_timing[$name]:-}"
    local model="${provider_model[$name]:-}"
    # accent is a lighter shade of bg, used for the model name (secondary text).
    local bg fg accent
    case "$name" in
        gemini)     bg='30;64;175';   fg='255;255;255'; accent='147;197;253' ;;  # blue-700/300
        openai)     bg='229;231;235'; fg='31;41;55';    accent='100;116;139' ;;  # gray-200/slate-500
        grok)       bg='185;28;28';   fg='255;255;255'; accent='252;165;165' ;;  # red-700/300
        perplexity) bg='21;128;61';   fg='255;255;255'; accent='134;239;172' ;;  # green-700/300
        *)          bg='55;65;81';    fg='255;255;255'; accent='156;163;175' ;;  # gray-700/400
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
            provider_state[$provider]="$state"
            [[ -n "$ms" ]] && provider_timing[$provider]="$ms"
            [[ -n "$model" ]] && provider_model[$provider]="$model"
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

printf '\n\033[2m[esc/ctrl-d] close\033[0m '
esc=$(printf '\033')
while true; do
    read -n1 -s -r key || break
    [[ "$key" = "$esc" ]] && break
done
WATCHEREOF
    chmod +x "$watch_dir/watcher.sh"

    local safe_dir safe_watcher
    safe_dir=$(printf '%q' "$watch_dir")
    safe_watcher=$(printf '%q' "$watch_dir/watcher.sh")

    local -a target_args=()
    if [[ -n "${TMUX_PANE:-}" ]]; then
        target_args=(-t "$TMUX_PANE")
    fi

    if ! tmux split-window -h -l '40%' "${target_args[@]}" \
        "bash $safe_watcher $safe_dir" >/dev/null 2>&1; then
        rm -rf "$watch_dir"
        return 1
    fi

    printf '%s' "$watch_dir"
}

# Signals the watcher to stop polling and switch to interactive close prompt.
display_pane_close() {
    local pane_dir="$1"
    [[ -d "$pane_dir" ]] || return 1
    touch "$pane_dir/.done"
}
