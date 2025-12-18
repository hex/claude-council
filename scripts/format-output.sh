#!/bin/bash
# ABOUTME: Formats council JSON output for terminal display
# ABOUTME: Creates colored boxes, handles quiet mode, debate mode, and roles

set -euo pipefail

# Colors
BLUE='\033[34m'
WHITE='\033[37m'
RED='\033[31m'
GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
LIGHT_YELLOW='\033[93m'
DIM='\033[2m'
BOLD='\033[1m'
ITALIC='\033[3m'
RESET='\033[0m'

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
        gemini)  echo -e "${BLUE}" ;;
        openai)  echo -e "${WHITE}" ;;
        grok)    echo -e "${RED}" ;;
        *)       echo -e "${CYAN}" ;;
    esac
}

provider_emoji() {
    case "$1" in
        gemini)  echo "🔵" ;;
        openai)  echo "⚪" ;;
        grok)    echo "🔴" ;;
        *)       echo "⚫" ;;
    esac
}

# Draw horizontal line of box characters
draw_hline() {
    local char="$1"
    local count="$2"
    printf "%${count}s" | tr ' ' "$char"
}

# Draw box header
# Args: emoji provider_name model [role] [header_type]
# header_type: normal, rebuttal, synthesis
draw_header() {
    local emoji="$1"
    local provider="$2"
    local model="${3:-}"
    local role="${4:-}"
    local header_type="${5:-normal}"

    local color
    color=$(provider_color "$provider")
    local provider_upper
    provider_upper=$(echo "$provider" | tr '[:lower:]' '[:upper:]')

    # Build left content
    local left_content="${emoji} ${provider_upper}"
    if [[ "$header_type" == "rebuttal" ]]; then
        left_content="${emoji} ${provider_upper} REBUTTAL"
    fi
    if [[ -n "$role" ]] && [[ "$role" != "null" ]] && [[ "$header_type" != "rebuttal" ]]; then
        left_content="${left_content} (${role})"
    fi

    # Build right content (model name)
    local right_content=""
    if [[ -n "$model" ]] && [[ "$model" != "null" ]]; then
        right_content="$model"
    fi

    # Calculate padding
    # Total inner = 78, subtract 4 for margins around content
    # Emojis display as 2 columns but count as 1 char, so add 1 per emoji
    local left_len=${#left_content}
    local right_len=${#right_content}
    local emoji_adjustment=1  # Account for emoji double-width display
    local padding=$((INNER_WIDTH - left_len - right_len - 4 - emoji_adjustment))
    if [[ $padding -lt 1 ]]; then
        padding=1
    fi

    # Draw top border
    echo -e "${DIM}${BOX_TL}$(draw_hline "$BOX_H" $INNER_WIDTH)${BOX_TR}${RESET}"

    # Draw content line with colors
    local line_color="$color"
    if [[ "$header_type" == "rebuttal" ]]; then
        # Yellow for rebuttal
        echo -ne "${DIM}${BOX_V}${RESET}  ${color}${emoji} ${provider_upper}${RESET} ${YELLOW}REBUTTAL${RESET}"
        local rebuttal_left="${emoji} ${provider_upper} REBUTTAL"
        local rebuttal_padding=$((INNER_WIDTH - ${#rebuttal_left} - 4 - 1))  # -1 for emoji width
        printf "%${rebuttal_padding}s" ""
        echo -e "  ${DIM}${BOX_V}${RESET}"
    else
        echo -ne "${DIM}${BOX_V}${RESET}  ${color}${left_content}${RESET}"
        printf "%${padding}s" ""
        echo -e "${ITALIC}${LIGHT_YELLOW}${right_content}${RESET}   ${DIM}${BOX_V}${RESET}"
    fi

    # Draw bottom border
    echo -e "${DIM}${BOX_BL}$(draw_hline "$BOX_H" $INNER_WIDTH)${BOX_BR}${RESET}"
}

# Draw synthesis header
draw_synthesis_header() {
    echo -e "${DIM}${BOX_TL}$(draw_hline "$BOX_H" $INNER_WIDTH)${BOX_TR}${RESET}"
    local content="⚡ SYNTHESIS"
    local padding=$((INNER_WIDTH - ${#content} - 4 - 1))  # -1 for emoji width
    echo -ne "${DIM}${BOX_V}${RESET}  ${CYAN}${BOLD}${content}${RESET}"
    printf "%${padding}s" ""
    echo -e "  ${DIM}${BOX_V}${RESET}"
    echo -e "${DIM}${BOX_BL}$(draw_hline "$BOX_H" $INNER_WIDTH)${BOX_BR}${RESET}"
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
