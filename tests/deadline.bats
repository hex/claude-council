#!/usr/bin/env bats
# ABOUTME: Tests for scripts/lib/deadline.sh
# ABOUTME: Pins run_with_deadline's passthrough and its kill at the deadline

load test_helper

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
    run run_with_deadline 1 sleep 20
    [ "$status" -eq 143 ]
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
