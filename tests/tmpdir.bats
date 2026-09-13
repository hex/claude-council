#!/usr/bin/env bats
# ABOUTME: Guards that every temp file the scripts create honours TMPDIR.
# ABOUTME: A bare mktemp lands in /var/folders on macOS, which sandboxed hosts refuse.

load test_helper

@test "no script calls mktemp without a TMPDIR-rooted template" {
    run grep -rnE 'mktemp( -d)?\)' "$SCRIPTS_DIR" --include='*.sh'
    echo "$output"
    [ "$status" -ne 0 ]
}
