#!/bin/bash
# ABOUTME: Runs a command under a wall-clock deadline without GNU timeout
# ABOUTME: Portable to macOS and Git Bash; exit 143 means the deadline ended it

# Run the command after the seconds argument, ending it once the deadline
# passes. Stdin, stdout and stderr pass through untouched (a background job
# would otherwise read /dev/null on bash 3.2); the status is the command's
# own, or 143 (128 + SIGTERM) once the deadline fired — the watchdog's
# verdict, whatever the command did with the signal: the codex wrapper
# handles SIGTERM by exiting 0 with nothing on stdout, agy by exiting 1 with
# "context canceled", and either would otherwise pass for an answer. A
# command still alive five seconds after the signal is killed outright. A
# deadline of 0 means none, as `alarm 0` did; anything but an integer is
# reported and nothing runs (status 2). GNU `timeout` is absent on stock macOS
# and on Git Bash, and a perl alarm never reaches the child on Windows, where
# perl emulates exec by spawning and waiting. The watchdog ticks once a second
# and is ended the moment the command returns, so no sleeping process outlives
# a fast call — bats, for one, holds a test file open until every process a
# test spawned has exited, and a watchdog left to notice on its next tick cost
# every provider call up to a second. Its stdio and bats' fd 3 are closed off
# so a caller capturing the command's stdout is not held open by it. bash's
# own report of a signal-ended job ("Terminated: 15 ...", printed by wait in a
# main shell) is silenced: a caller capturing stderr would store it as the
# provider's error text.
# Send a signal to a process and everything under it, children first, so a
# CLI's own child (the binary a node wrapper spawns, the sleep a shell script
# is in) cannot outlive it holding the caller's captured stdout open. pgrep
# finds the children; Git Bash ships none, so there only the process itself
# is signalled. Never fails: a process that is already gone is the outcome
# wanted, and callers run under errexit.
# Usage: signal_tree <SIG> <pid>
signal_tree() {
    local sig="$1" pid="$2" child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        signal_tree "$sig" "$child"
    done
    kill "-$sig" "$pid" 2>/dev/null || true
}

# Usage: run_with_deadline <seconds> <command> [args...]
run_with_deadline() {
    local secs="$1"
    shift
    local pid watchdog rc=0 verdict=0
    if [[ ! "$secs" =~ ^[0-9]+$ ]]; then
        echo "run_with_deadline: deadline must be a whole number of seconds, got '$secs'" >&2
        return 2
    fi
    if (( secs == 0 )); then
        "$@"
        return
    fi
    "$@" <&0 &
    pid=$!
    (
        while (( secs-- > 0 )); do
            sleep 1
            kill -0 "$pid" 2>/dev/null || exit 0
        done
        # Firing. The caller ends the watchdog once the command returns; from
        # here that must not pre-empt the verdict, so the watchdog exits 99
        # on its own instead.
        trap '' TERM
        signal_tree TERM "$pid"
        grace=5
        while (( grace-- > 0 )); do
            sleep 1
            kill -0 "$pid" 2>/dev/null || exit 99
        done
        signal_tree KILL "$pid"
        exit 99
    ) >/dev/null 2>&1 3>&- &
    watchdog=$!
    wait "$pid" 2>/dev/null || rc=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null || verdict=$?
    if (( verdict == 99 )); then
        rc=143
    fi
    return "$rc"
}
