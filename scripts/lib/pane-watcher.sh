#!/bin/bash
# ABOUTME: Runs inside the tmux pane; streams provider status + rendered responses
# ABOUTME: Args: $1=watch dir, $2=display.sh lib path; sources the lib for helpers
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

    local rgb_first faint
    provider_color_rgb rgb_first "${pending[0]}"
    faint=$(council_faint_sgr)   # "waiting on" label: dark gray on light, faint otherwise
    # Disable autowrap (DECAWM, \033[?7l) while drawing the line: a waiting list
    # wider than the pane must CLIP at the right margin, not wrap. \r\033[K only
    # reclaims the current physical row, so a wrapped line would leave a stale
    # row every frame (a waterfall of spinner lines). Re-enable (\033[?7h) after
    # so response text below still wraps for readability.
    printf '\r\033[K\033[?7l   \033[1;38;2;%sm%s\033[0m   \033[%smcouncil is waiting on\033[0m   %s\033[?7h' \
        "$rgb_first" "$frame" "$faint" "$list"
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
        gemini|antigravity) bg='30;64;175';   fg='255;255;255'; accent='147;197;253' ;;  # blue-700/300
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
                        # Scrub raw control bytes (keep tab) from the provider's
                        # error text so it can't drive the terminal on display.
                        err_line=$(printf '%s' "$err_line" | LC_ALL=C tr -d '\000-\010\013-\037\177')
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
            # Drop an iTerm2 mark (cmd-up/down jump target) above each response.
            # Emitted unconditionally: iTerm2 detection is unreliable inside a
            # tmux pane (ITERM_SESSION_ID/LC_TERMINAL aren't forwarded in), so
            # gating on it would suppress marks that DO work in iTerm2+tmux. The
            # DCS passthrough needs tmux `allow-passthrough on` to reach iTerm2;
            # other terminals safely ignore the unknown OSC 1337.
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
