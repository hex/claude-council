#!/bin/bash
# ABOUTME: Runs a command under a wall-clock deadline without GNU timeout
# ABOUTME: Portable to macOS and Git Bash; exit 143 means the deadline ended it

# Run the command after the seconds argument, ending it once the deadline
# passes. Stdin, stdout and stderr pass through untouched (a background job
# would otherwise read /dev/null on bash 3.2); the status is the command's
# own, or 143 (128 + SIGTERM) when the watchdog killed it. GNU `timeout` is
# absent on stock macOS and on Git Bash, and a perl alarm never reaches the
# child on Windows, where perl emulates exec by spawning and waiting. The
# watchdog ticks once a second and leaves as soon as the command is gone, so no
# sleeping process outlives a fast call — bats, for one, holds a test file open
# until every process a test spawned has exited. Its own stdio is closed off so
# a caller capturing the command's stdout is not held open by the watchdog.
# Usage: run_with_deadline <seconds> <command> [args...]
run_with_deadline() {
    local secs="$1"
    shift
    local pid rc=0
    "$@" <&0 &
    pid=$!
    (
        t="$secs"
        while (( t-- > 0 )); do
            sleep 1
            kill -0 "$pid" 2>/dev/null || exit 0
        done
        kill "$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    wait "$pid" || rc=$?
    return "$rc"
}
