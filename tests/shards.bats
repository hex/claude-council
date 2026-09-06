#!/usr/bin/env bats
# ABOUTME: Guards the shard lists the Windows CI job runs the suite from
# ABOUTME: A bats file missing from tests/shards/*.txt would silently skip Windows

load test_helper

@test "shards: the lists name every bats file exactly once, none of them empty" {
    expected="$(cd "$BATS_TEST_DIRNAME" && printf '%s\n' *.bats)"
    listed="$(cat "$BATS_TEST_DIRNAME"/shards/*.txt | sort)"
    [ "$listed" = "$expected" ]
    for list in "$BATS_TEST_DIRNAME"/shards/*.txt; do
        [ -s "$list" ]
    done
}
