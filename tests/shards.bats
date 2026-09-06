#!/usr/bin/env bats
# The Windows CI job splits the suite across shards listed in tests/shards/.
# A bats file missing from every list would silently stop running on Windows.

setup() {
    TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    SHARDS_DIR="$TESTS_DIR/shards"
}

@test "shards: every bats file is listed exactly once across the shard lists" {
    expected="$(cd "$TESTS_DIR" && ls ./*.bats | sed 's|^\./||' | sort)"
    listed="$(cat "$SHARDS_DIR"/*.txt | sort)"
    [ "$listed" = "$expected" ]
}

@test "shards: every listed file exists" {
    [ -d "$SHARDS_DIR" ]
    while read -r f; do
        [ -f "$TESTS_DIR/$f" ] || { echo "missing: $f"; return 1; }
    done < <(cat "$SHARDS_DIR"/*.txt)
}

@test "shards: no shard list is empty" {
    for list in "$SHARDS_DIR"/*.txt; do
        [ -s "$list" ] || { echo "empty: $list"; return 1; }
    done
}
