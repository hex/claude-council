#!/bin/bash
# ABOUTME: Visual test harness for the streaming pane (no real API calls)
# ABOUTME: Drives display.sh primitives with synthetic events to iterate on UX

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/display.sh"
# get_model, so the demo advertises the models a real run would query.
source "$SCRIPT_DIR/../lib/providers.sh"

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
    pane_status_event "$PANE" "$p" querying "" "$(get_model "$p")"
    sleep 0.15
done

case "$MODE" in
    fast)
        sleep 0.5
        pane_status_event "$PANE" gemini complete 187 "$(get_model gemini)"
        pane_response_write "$PANE" gemini "$(response_md gemini)"
        sleep 0.3
        pane_status_event "$PANE" openai complete 240 "$(get_model openai)"
        pane_response_write "$PANE" openai "$(response_md openai)"
        sleep 0.3
        pane_status_event "$PANE" grok complete 195 "$(get_model grok)"
        pane_response_write "$PANE" grok "$(response_md grok)"
        sleep 0.3
        pane_status_event "$PANE" perplexity complete 312 "$(get_model perplexity)"
        pane_response_write "$PANE" perplexity "$(response_md perplexity)"
        ;;
    error)
        sleep 1.2
        pane_status_event "$PANE" gemini complete 187 "$(get_model gemini)"
        pane_response_write "$PANE" gemini "$(response_md gemini)"
        sleep 1.5
        pane_status_event "$PANE" grok cached "" "$(get_model grok)"
        pane_response_write "$PANE" grok "$(response_md grok)"
        sleep 1.0
        pane_error_write "$PANE" openai "HTTP 503: Service unavailable
Retried 3 times with exponential backoff
Final response: {\"error\": {\"message\": \"upstream timeout\"}}"
        pane_status_event "$PANE" openai error "" "$(get_model openai)"
        sleep 2.0
        pane_status_event "$PANE" perplexity complete 4280 "$(get_model perplexity)"
        pane_response_write "$PANE" perplexity "$(response_md perplexity)"
        # Offer the retry the way query-council's offer_retry does: open for
        # ten seconds, answered with a re-query when r was pressed.
        pane_retry_offer_write "$PANE" 10 openai
        if pane_retry_await "$PANE" 10; then
            pane_status_event "$PANE" openai querying "" "$(get_model openai)"
            sleep 1.5
            pane_status_event "$PANE" openai complete 1480 "$(get_model openai)"
            pane_response_write "$PANE" openai "$(response_md openai)"
        fi
        ;;
    *)
        sleep 1.0
        pane_status_event "$PANE" gemini complete 187 "$(get_model gemini)"
        pane_response_write "$PANE" gemini "$(response_md gemini)"
        sleep 1.5
        pane_status_event "$PANE" openai complete 840 "$(get_model openai)"
        pane_response_write "$PANE" openai "$(response_md openai)"
        sleep 1.0
        pane_status_event "$PANE" grok complete 1240 "$(get_model grok)"
        pane_response_write "$PANE" grok "$(response_md grok)"
        sleep 2.5
        pane_status_event "$PANE" perplexity complete 3920 "$(get_model perplexity)"
        pane_response_write "$PANE" perplexity "$(response_md perplexity)"
        ;;
esac

sleep 0.5
display_pane_close "$PANE"
echo "Demo complete. Esc in the pane to close it." >&2
