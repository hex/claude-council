#!/bin/bash
# ABOUTME: Helper functions for exporting council output to files
# ABOUTME: Strips ANSI codes and writes clean markdown

# Strip ANSI escape sequences from text
strip_ansi() {
    # Remove all ANSI escape sequences
    sed 's/\x1b\[[0-9;]*m//g' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

# Write markdown to file with metadata header
# Usage: write_export <output_path> <prompt> <providers_json>
# Reads markdown content from stdin
write_export() {
    local output_path="$1"
    local prompt="$2"
    local providers="$3"  # Space-separated list like "gemini openai"

    # Ensure directory exists
    local dir=$(dirname "$output_path")
    [[ -d "$dir" ]] || mkdir -p "$dir"

    # Generate metadata header
    {
        echo "# Council Response"
        echo ""
        echo "> **Query:** ${prompt}"
        echo ">"
        echo "> **Date:** $(date '+%Y-%m-%d %H:%M')"
        echo ">"
        echo "> **Providers:** ${providers}"
        echo ""
        echo "---"
        echo ""
        # Read and strip ANSI from stdin
        strip_ansi
    } > "$output_path"

    echo "$output_path"
}

# If run directly, act as a filter
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$1" == "--strip" ]]; then
        strip_ansi
    elif [[ "$1" == "--write" ]] && [[ -n "$2" ]]; then
        write_export "$2" "${3:-}" "${4:-}"
    else
        echo "Usage:"
        echo "  $0 --strip              # Strip ANSI from stdin"
        echo "  $0 --write <path> [prompt] [providers]  # Write with header"
        exit 1
    fi
fi
