#!/bin/bash
# ABOUTME: Formats council JSON output for terminal display
# ABOUTME: Creates colored boxes, handles quiet mode, debate mode, and roles

set -euo pipefail

# Colors (only if output is a terminal)
if [[ -t 1 ]]; then
    BLUE='\033[34m'
    WHITE='\033[37m'
    RED='\033[31m'
    GREEN='\033[32m'
    CYAN='\033[36m'
    YELLOW='\033[33m'
    LIGHT_YELLOW='\033[93m'
    LIGHT_PINK='\033[38;5;218m'
    DIM='\033[2m'
    BOLD='\033[1m'
    ITALIC='\033[3m'
    RESET='\033[0m'
else
    # No colors when redirected to file
    BLUE=''
    WHITE=''
    RED=''
    GREEN=''
    CYAN=''
    YELLOW=''
    LIGHT_YELLOW=''
    LIGHT_PINK=''
    DIM=''
    BOLD=''
    ITALIC=''
    RESET=''
fi

# Box drawing characters (Unicode)
BOX_TL='╔'
BOX_TR='╗'
BOX_BL='╚'
BOX_BR='╝'
BOX_H='═'
BOX_V='║'

# Box width (80 chars total, 78 inner)
BOX_WIDTH=80
INNER_WIDTH=78

# Provider styling
provider_color() {
    case "$1" in
        gemini)     echo -e "${BLUE}" ;;
        openai)     echo -e "${WHITE}" ;;
        grok)       echo -e "${RED}" ;;
        perplexity) echo -e "${GREEN}" ;;
        *)          echo -e "${CYAN}" ;;
    esac
}

provider_emoji() {
    case "$1" in
        gemini)     echo "🔵" ;;
        openai)     echo "⚪" ;;
        grok)       echo "🔴" ;;
        perplexity) echo "🟢" ;;
        *)          echo "⚫" ;;
    esac
}

# Draw horizontal line of box characters
draw_hline() {
    local char="$1"
    local count="$2"
    printf "%${count}s" | tr ' ' "$char"
}

# Draw header bar (markdown compatible)
# Args: emoji provider_name model [role] [header_type]
# header_type: normal, rebuttal
draw_header() {
    local emoji="$1"
    local provider="$2"
    local model="${3:-}"
    local role="${4:-}"
    local header_type="${5:-normal}"

    # Capitalize provider name
    local provider_cap
    provider_cap="$(echo "${provider:0:1}" | tr '[:lower:]' '[:upper:]')${provider:1}"

    # Build header text
    local header_text="${emoji} ${provider_cap}"
    if [[ "$header_type" == "rebuttal" ]]; then
        header_text="${emoji} ${provider_cap} REBUTTAL"
    fi
    if [[ -n "$role" ]] && [[ "$role" != "null" ]] && [[ "$header_type" != "rebuttal" ]]; then
        header_text="${header_text} (${role})"
    fi
    if [[ -n "$model" ]] && [[ "$model" != "null" ]]; then
        header_text="${header_text} - ${model}"
    fi

    # Draw markdown header
    echo ""
    echo "---"
    echo "## ${header_text}"
}

# Draw synthesis header (markdown compatible)
draw_synthesis_header() {
    echo ""
    echo "---"
    echo "## Synthesis"
}

# Format and display JSON council output
format_output() {
    local json="$1"

    # Extract metadata
    local quiet
    quiet=$(echo "$json" | jq -r '.metadata.quiet_mode // false')
    local debate
    debate=$(echo "$json" | jq -r '.metadata.debate_mode // false')

    # Get providers list from round1
    local providers
    providers=$(echo "$json" | jq -r '.round1 | keys[]')

    # If quiet mode, skip individual responses
    if [[ "$quiet" != "true" ]]; then
        # Show round 1 header if debate mode
        if [[ "$debate" == "true" ]]; then
            echo ""
            echo -e "${BOLD}## Round 1: Initial Responses${RESET}"
            echo ""
        fi

        # Display each provider's round 1 response
        for provider in $providers; do
            local emoji
            emoji=$(provider_emoji "$provider")
            local model
            model=$(echo "$json" | jq -r ".round1[\"${provider}\"].model // \"unknown\"")
            local role
            role=$(echo "$json" | jq -r ".round1[\"${provider}\"].role // empty")
            local response
            response=$(echo "$json" | jq -r ".round1[\"${provider}\"].response // \"No response\"")
            local status
            status=$(echo "$json" | jq -r ".round1[\"${provider}\"].status")

            draw_header "$emoji" "$provider" "$model" "$role" "normal"

            if [[ "$status" == "error" ]]; then
                local error
                error=$(echo "$json" | jq -r ".round1[\"${provider}\"].error // \"Unknown error\"")
                echo -e "${RED}Error: ${error}${RESET}"
            else
                echo "$response"
            fi
            echo ""
        done

        # Round 2 rebuttals if debate mode
        if [[ "$debate" == "true" ]]; then
            # Check if round2 exists
            local has_round2
            has_round2=$(echo "$json" | jq -r 'has("round2")')

            if [[ "$has_round2" == "true" ]]; then
                echo ""
                echo -e "${BOLD}## Round 2: Rebuttals${RESET}"
                echo ""

                for provider in $providers; do
                    local emoji
                    emoji=$(provider_emoji "$provider")
                    local model
                    model=$(echo "$json" | jq -r ".round2[\"${provider}\"].model // \"unknown\"")
                    local response
                    response=$(echo "$json" | jq -r ".round2[\"${provider}\"].response // \"No rebuttal\"")
                    local status
                    status=$(echo "$json" | jq -r ".round2[\"${provider}\"].status // \"error\"")

                    draw_header "$emoji" "$provider" "$model" "" "rebuttal"

                    if [[ "$status" == "error" ]]; then
                        local error
                        error=$(echo "$json" | jq -r ".round2[\"${provider}\"].error // \"Unknown error\"")
                        echo -e "${RED}Error: ${error}${RESET}"
                    else
                        echo "$response"
                    fi
                    echo ""
                done
            fi
        fi
    fi

    # Always show synthesis header (synthesis content generated by Claude)
    echo ""
    draw_synthesis_header
}

# Main entry point
main() {
    local json

    if [[ $# -eq 0 ]]; then
        # Read JSON from stdin
        json=$(cat)
    elif [[ "$1" == "-" ]]; then
        # Explicit stdin
        json=$(cat)
    elif [[ -f "$1" ]]; then
        # Read from file
        json=$(cat "$1")
    else
        # Assume it's JSON string
        json="$1"
    fi

    # Validate JSON
    if ! echo "$json" | jq -e . >/dev/null 2>&1; then
        echo "Error: Invalid JSON input" >&2
        exit 1
    fi

    format_output "$json"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
