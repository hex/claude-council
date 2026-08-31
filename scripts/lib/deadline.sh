#!/bin/bash
# ABOUTME: Runs a command under a wall-clock deadline without GNU timeout
# ABOUTME: Portable to macOS and Git Bash; exit 143 means the deadline ended it

# Run the command after the seconds argument, ending it once the deadline
# passes. Stdin, stdout and stderr pass through untouched (a background job
# would otherwise read /dev/null on bash 3.2); the status is the command's
# own, or 143 (128 + SIGTERM) when the watchdog killed it. GNU `timeout` is
# absent on stock macOS and on Git Bash, and a perl alarm never reaches the
# child on Windows, where perl emulates exec by spawning and waiting. The
# watchdog ticks once a second and is ended the moment the command returns, so
# no sleeping process outlives a fast call — bats, for one, holds a test file
# open until every process a test spawned has exited, and a watchdog left to
# notice on its next tick cost every provider call up to a second. Its own
# stdio is closed off so a caller capturing the command's stdout is not held
# open by it.
# Usage: run_with_deadline <seconds> <command> [args...]
run_with_deadline() {
    local secs="$1"
    shift
    local pid watchdog rc=0
    "$@" <&0 &
    pid=$!
    (
        while (( secs-- > 0 )); do
            sleep 1
            kill -0 "$pid" 2>/dev/null || exit 0
        done
        kill "$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid" || rc=$?
    # Reaping the watchdog keeps bash 3.2 from reporting the job it just
    # killed ("Terminated: 15") on the caller's stderr.
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null || true
    return "$rc"
}
