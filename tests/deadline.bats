#!/usr/bin/env bats
# ABOUTME: Tests for scripts/lib/deadline.sh
# ABOUTME: Pins run_with_deadline's passthrough and its kill at the deadline

load test_helper
bats_require_minimum_version 1.5.0

LIB="${LIB_DIR}/deadline.sh"

setup() {
    source "$LIB"
}

# The pane-watcher tests feed keystrokes through a process substitution, so
# the command under the deadline must read the caller's stdin. A bare `&`
# gives a background job /dev/null on bash 3.2.
@test "run_with_deadline: the command reads the caller's stdin" {
    run run_with_deadline 5 cat < <(printf 'typed'; sleep 0.2)
    [ "$status" -eq 0 ]
    [ "$output" = "typed" ]
}

@test "run_with_deadline: a command that finishes returns its own status" {
    run run_with_deadline 5 bash -c 'echo done; exit 7'
    [ "$status" -eq 7 ]
    [ "$output" = "done" ]
}

@test "run_with_deadline: a command past the deadline is ended with status 143" {
    local started
    started=$(date +%s)
    # Through a fresh main shell, as kimi-cli.sh calls it: bash reports a
    # signal-ended job ("Terminated: 15 ...") there, never inside a subshell,
    # and a caller capturing stderr would store it as the provider's error.
    run --separate-stderr "$HOST_BASH" -c "source '$LIB'; run_with_deadline 1 sleep 20"
    [ "$status" -eq 143 ]
    [ -z "$stderr" ]
    # Ended at the deadline, not when sleep would have finished on its own.
    [ $(( $(date +%s) - started )) -lt 10 ]
}

# The watchdog leaves as soon as the command is gone. Were it a plain
# `sleep N; kill`, the `wait` here would take the whole 30 seconds, and bats
# would hold the test file open just as long after every fast call.
@test "run_with_deadline: no watchdog outlives a fast command" {
    local started
    started=$(date +%s)
    run bash -c "source '$LIB'; run_with_deadline 30 true; wait"
    [ "$status" -eq 0 ]
    [ $(( $(date +%s) - started )) -lt 10 ]
}

@test "run_with_deadline: a command ended by a signal reports only its status" {
    run --separate-stderr "$HOST_BASH" -c "source '$LIB'; run_with_deadline 5 bash -c 'kill -9 \$\$'"
    [ "$status" -eq 137 ]
    [ -z "$stderr" ]
}

# A deadline of 0 means none, as `alarm 0` did; anything but an integer is a
# misconfiguration to report, not a reason to end the command at once.
@test "run_with_deadline: a deadline of 0 leaves the command unbounded" {
    run run_with_deadline 0 bash -c 'sleep 1; echo finished'
    [ "$status" -eq 0 ]
    [ "$output" = "finished" ]
}

@test "run_with_deadline: a non-integer deadline is rejected before the command runs" {
    run --separate-stderr run_with_deadline 1.5 bash -c 'echo ran'
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"1.5"* ]]
}

# The deadline is the helper's verdict, not the command's: a CLI that handles
# SIGTERM by exiting 0 with nothing on stdout (the codex wrapper does) would
# otherwise be recorded as a successful empty answer.
@test "run_with_deadline: a command that exits 0 on the deadline signal still reports 143" {
    local started
    started=$(date +%s)
    run --separate-stderr run_with_deadline 1 bash -c 'trap "exit 0" TERM; sleep 8 & wait'
    [ "$status" -eq 143 ]
    [ -z "$stderr" ]
    # The command's own sleep must not hold the captured stdout open either.
    # Without pgrep (Git Bash) signal_tree cannot reach it, so there the
    # verdict holds and the bound does not.
    if command -v pgrep >/dev/null 2>&1; then
        [ $(( $(date +%s) - started )) -lt 6 ]
    fi
}

@test "run_with_deadline: a command that ignores the signal is killed after a grace period" {
    local started
    started=$(date +%s)
    run --separate-stderr run_with_deadline 1 perl -e '$SIG{TERM} = "IGNORE"; sleep 30; print "late\n"'
    [ "$status" -eq 143 ]
    [ -z "$output" ]
    [ $(( $(date +%s) - started )) -lt 15 ]
}
