#!/bin/bash
# ABOUTME: Gives a CLI seat a working directory and a home of its own, so the user's agent config stays out of the seat
# ABOUTME: Both are stable, owner-only directories under TMPDIR; the user's real home is only linked to, never written

# Both directories are fixed names rather than one per run: cursor's --trust,
# grok's trusted folders, kimi's workspace list, agy's projects and copilot's
# trust list each record state per directory, and a new directory every run
# would pile up entries in the user's own state.

# The platform the seat runs on: macos, linux or windows (Git Bash, MSYS,
# Cygwin). The home lever is macOS and Linux only: on Windows the native CLIs
# resolve the home from USERPROFILE, so a HOME swap would change nothing.
seat_platform() {
    case "$(uname -s)" in
        Darwin) echo macos ;;
        MINGW*|MSYS*|CYGWIN*) echo windows ;;
        *) echo linux ;;
    esac
}

# Creates DIR for this user alone, mode 700, and accepts it when it already
# exists as such. On a shared /tmp another user can create the name first: a
# directory of theirs is refused, and so is a symlink, checked first because a
# link to a directory this user owns would pass the ownership test and put the
# seat somewhere else, such as inside the user's home.
# Usage: seat_private_dir DIR
seat_private_dir() {
    local dir="$1"
    if [[ -L "$dir" ]]; then
        echo "Error: ${dir} is a symlink; the council's seats need a directory of their own there. Remove it and retry." >&2
        return 1
    fi
    if ! (umask 077 && mkdir -p "$dir"); then
        echo "Error: could not create ${dir} for the council's seats." >&2
        return 1
    fi
    if [[ ! -d "$dir" || -L "$dir" || ! -O "$dir" ]]; then
        echo "Error: ${dir} exists but is not a directory owned by $(id -un); the council's seats need one of their own there. Remove it or set TMPDIR elsewhere." >&2
        return 1
    fi
    chmod 700 "$dir"
}

# The working directory every CLI seat runs in: empty and outside any
# repository, so no project's instruction files, skills, hooks or MCP servers
# load, and claude adds no git status to its prompt. The seat's prompt and
# files all travel as absolute paths, so leaving the caller's directory loses
# nothing.
seat_scratch_dir() {
    printf '%s\n' "${TMPDIR:-/tmp}/claude-council-seat"
}

# Changes into the seat's working directory, creating it on first use.
seat_enter_scratch() {
    local dir
    dir=$(seat_scratch_dir)
    seat_private_dir "$dir" || return 1
    cd "$dir" || return 1
}

# Points LINK at TARGET, keeping a link that already does and replacing one
# that points elsewhere. Seats of concurrent council runs share the home, so
# two can reach this at once; both write the same target, and the readback
# decides. Never `mv` a fresh link over the old one: when the old link points
# at a directory, mv moves the new link into that directory, which is the
# user's real one. A real file or directory at LINK is refused, never written
# into.
# Usage: seat_link TARGET LINK
seat_link() {
    local target="$1" link="$2"
    for _ in 1 2; do
        [[ -L "$link" && "$(readlink "$link")" == "$target" ]] && return 0
        if [[ -e "$link" && ! -L "$link" ]]; then
            echo "Error: ${link} is not a link; the seat's home holds only links to the user's login." >&2
            return 1
        fi
        ln -sfn "$target" "$link" 2>/dev/null || true
    done
    [[ -L "$link" && "$(readlink "$link")" == "$target" ]] && return 0
    echo "Error: could not link ${link} to ${target} for the seat's login." >&2
    return 1
}

# Prints the home SEAT runs under: a directory holding only the links named,
# each RELATIVE path pointing at its TARGET, which is where that CLI keeps its
# login. Everything else the CLI looks for under HOME (the user's skills,
# plugins, hooks, rules and MCP servers, its own and other vendors') is absent.
# The CLI writes caches and state of its own there, which stay between runs.
# Usage: seat_home SEAT [RELATIVE TARGET]...
seat_home() {
    local root="${TMPDIR:-/tmp}/claude-council-seat-home" home rel
    home="${root}/$1"
    shift
    seat_private_dir "$root" || return 1
    seat_private_dir "$home" || return 1
    while [[ $# -ge 2 ]]; do
        rel="$1"
        if [[ "$rel" == */* ]]; then
            seat_private_dir "${home}/${rel%/*}" || return 1
        fi
        seat_link "$2" "${home}/${rel}" || return 1
        shift 2
    done
    printf '%s\n' "$home"
}
