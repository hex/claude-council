#!/usr/bin/env bats
# ABOUTME: Tests for scripts/release.sh version bump, commit, and staged-index guard
# ABOUTME: Hermetic — runs a copy of the script inside a throwaway git repo

load test_helper
bats_require_minimum_version 1.5.0

# Build a self-contained repo holding a copy of release.sh, a plugin.json, and a
# fake `claude` on PATH, so the real script runs without touching this repo or
# the network. Echoes the repo path.
make_release_repo() {
    local repo="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "$repo/scripts" "$repo/.claude-plugin" "$repo/fakebin"
    cp "${SCRIPTS_DIR}/release.sh" "$repo/scripts/release.sh"
    printf '{"name":"claude-council","version":"2000.1.1"}\n' \
        > "$repo/.claude-plugin/plugin.json"
    cat > "$repo/fakebin/claude" <<'EOF'
#!/bin/bash
echo "fake claude $*"
EOF
    chmod +x "$repo/fakebin/claude"
    git -C "$repo" init -q
    git -C "$repo" -c user.email=t@t -c user.name=t add -A
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m init
    echo "$repo"
}

@test "release: aborts when the index has staged changes" {
    local repo
    repo=$(make_release_repo)
    # Stage an unrelated change that a version bump must not sweep up
    echo "secret" > "$repo/unrelated.txt"
    git -C "$repo" add unrelated.txt

    run env PATH="$repo/fakebin:$PATH" bash "$repo/scripts/release.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"staged changes present"* ]]

    # No bump commit was made, and plugin.json is untouched on disk
    [[ "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" == "1" ]]
    [[ "$(jq -r '.version' "$repo/.claude-plugin/plugin.json")" == "2000.1.1" ]]
}

@test "release: a clean index bumps, commits, and tags" {
    local repo
    repo=$(make_release_repo)

    run env PATH="$repo/fakebin:$PATH" bash "$repo/scripts/release.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released v"* ]]

    # A new version-bump commit and matching tag exist
    [[ "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" == "2" ]]
    git -C "$repo" log -1 --pretty=%s | grep -q "^Bump version to "
    [ -n "$(git -C "$repo" tag --list 'v*')" ]
}

@test "release: aborts when the test suite fails" {
    local repo
    repo=$(make_release_repo)
    mkdir -p "$repo/tests"
    printf '#!/bin/bash\necho boom\nexit 1\n' > "$repo/tests/run_tests.sh"
    chmod +x "$repo/tests/run_tests.sh"

    run env PATH="$repo/fakebin:$PATH" bash "$repo/scripts/release.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"test suite failed"* ]]
    # No bump commit — the release stopped at the gate
    [[ "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" == "1" ]]
}

@test "release: a passing test suite gate lets the release proceed" {
    local repo
    repo=$(make_release_repo)
    mkdir -p "$repo/tests"
    printf '#!/bin/bash\nexit 0\n' > "$repo/tests/run_tests.sh"
    chmod +x "$repo/tests/run_tests.sh"

    run env PATH="$repo/fakebin:$PATH" bash "$repo/scripts/release.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Running test suite before release"* ]]
    [[ "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" == "2" ]]
}

@test "release: the bump commit carries only plugin.json" {
    local repo
    repo=$(make_release_repo)
    # An unstaged (not added) working-tree change must stay out of the commit
    echo "wip" > "$repo/scratch.txt"

    run env PATH="$repo/fakebin:$PATH" bash "$repo/scripts/release.sh"
    [ "$status" -eq 0 ]

    # Exactly one file in the bump commit: the manifest
    local changed
    changed=$(git -C "$repo" show --name-only --pretty=format: HEAD | grep -c .)
    [ "$changed" -eq 1 ]
    git -C "$repo" show --name-only --pretty=format: HEAD | grep -q "plugin.json"
    # The uncommitted scratch file is still dirty, not swept in
    [[ -n "$(git -C "$repo" status --porcelain scratch.txt)" ]]
}
