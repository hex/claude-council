#!/bin/bash
# ABOUTME: Portable SHA-256 hex helper — shasum (macOS) or sha256sum (GNU-only)
# ABOUTME: Reads data from stdin, prints the lowercase hex digest, no filename

# macOS ships perl's `shasum`; minimal GNU/Linux installs and slim containers
# ship only coreutils' `sha256sum`. Prefer shasum, fall back to sha256sum, so a
# cache-key or jobs-dir hash never dies with 127 under `set -o pipefail`.
sha256_hex() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    else
        sha256sum | cut -d' ' -f1
    fi
}
