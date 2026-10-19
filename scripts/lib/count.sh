#!/bin/bash
# ABOUTME: The check a script runs on a count it was given: a whole number of 1 or more
# ABOUTME: Read base-10, so a padded 08 is not octal and a padded 00 is refused as zero

# Exits 1 saying why when the value is not a whole number of 1 or more.
# Usage: require_count <name> <value>
require_count() {
    case "$2" in
        ''|*[!0-9]*)
            echo "Error: $1 needs a whole number, got: $2" >&2
            exit 1
            ;;
    esac
    if (( 10#$2 == 0 )); then
        echo "Error: $1 needs 1 or more, got: $2" >&2
        exit 1
    fi
}
