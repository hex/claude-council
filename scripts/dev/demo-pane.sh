#!/bin/bash
# ABOUTME: Visual test harness for the streaming pane (no real API calls)
# ABOUTME: Drives display.sh primitives with synthetic events to iterate on UX

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/display.sh"

MODE="${1:-default}"

if ! is_tmux; then
    echo "Not inside tmux — pane demo requires tmux. Aborting." >&2
    exit 1
fi

# Demos always auto-close — caller can override by exporting COUNCIL_AUTO_CLOSE=0.
export COUNCIL_AUTO_CLOSE="${COUNCIL_AUTO_CLOSE:-1}"

PANE=$(display_pane_open) || { echo "display_pane_open failed" >&2; exit 1; }
echo "Demo pane opened: $PANE" >&2

cleanup() {
    [[ -d "$PANE" ]] && display_pane_close "$PANE" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

response_md() {
    local provider="$1"
    cat <<MD
## Response from ${provider}

This is **synthetic** content for visual testing — no real API call was made.

\`\`\`bash
echo "demo response from ${provider}"
\`\`\`

- bullet item one
- bullet item two with *emphasis*
- bullet item three with a [link](https://example.com)

> Quoted block, often used for citations or summaries.

| Column A | Column B |
|----------|----------|
| Cell 1   | Cell 2   |
| Cell 3   | Cell 4   |
MD
}

# All providers start "querying"
for p in gemini openai grok perplexity; do
    case "$p" in
        gemini)     m="gemini-3.1-pro-preview" ;;
        openai)     m="gpt-5.5-pro" ;;
        grok)       m="grok-4.20-reasoning" ;;
        perplexity) m="sonar-reasoning-pro" ;;
    esac
    pane_status_event "$PANE" "$p" querying "" "$m"
    sleep 0.15
done

model_for() {
    case "$1" in
        gemini)     echo "gemini-3.1-pro-preview" ;;
        openai)     echo "gpt-5.5-pro" ;;
        grok)       echo "grok-4.20-reasoning" ;;
        perplexity) echo "sonar-reasoning-pro" ;;
    esac
}

case "$MODE" in
    fast)
        sleep 0.5
        pane_status_event "$PANE" gemini complete 187 "$(model_for gemini)"
        pane_response_write "$PANE" gemini "$(response_md gemini)"
        sleep 0.3
        pane_status_event "$PANE" openai complete 240 "$(model_for openai)"
        pane_response_write "$PANE" openai "$(response_md openai)"
        sleep 0.3
        pane_status_event "$PANE" grok complete 195 "$(model_for grok)"
        pane_response_write "$PANE" grok "$(response_md grok)"
        sleep 0.3
        pane_status_event "$PANE" perplexity complete 312 "$(model_for perplexity)"
        pane_response_write "$PANE" perplexity "$(response_md perplexity)"
        ;;
    error)
        sleep 1.2
        pane_status_event "$PANE" gemini complete 187 "$(model_for gemini)"
        pane_response_write "$PANE" gemini "$(response_md gemini)"
        sleep 1.5
        pane_status_event "$PANE" grok cached "" "$(model_for grok)"
        pane_response_write "$PANE" grok "$(response_md grok)"
        sleep 1.0
        pane_error_write "$PANE" openai "HTTP 503: Service unavailable
Retried 3 times with exponential backoff
Final response: {\"error\": {\"message\": \"upstream timeout\"}}"
        pane_status_event "$PANE" openai error "" "$(model_for openai)"
        sleep 2.0
        pane_status_event "$PANE" perplexity complete 4280 "$(model_for perplexity)"
        pane_response_write "$PANE" perplexity "$(response_md perplexity)"
        ;;
    *)
        sleep 1.0
        pane_status_event "$PANE" gemini complete 187 "$(model_for gemini)"
        pane_response_write "$PANE" gemini "$(response_md gemini)"
        sleep 1.5
        pane_status_event "$PANE" openai complete 840 "$(model_for openai)"
        pane_response_write "$PANE" openai "$(response_md openai)"
        sleep 1.0
        pane_status_event "$PANE" grok complete 1240 "$(model_for grok)"
        pane_response_write "$PANE" grok "$(response_md grok)"
        sleep 2.5
        pane_status_event "$PANE" perplexity complete 3920 "$(model_for perplexity)"
        pane_response_write "$PANE" perplexity "$(response_md perplexity)"
        ;;
esac

sleep 0.5
display_pane_close "$PANE"
echo "Demo complete. Esc in the pane to close it." >&2
