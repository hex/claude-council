#!/usr/bin/env bats
# ABOUTME: Which vendor mark the extension's panels draw beside each council seat, run in node
# ABOUTME: Covers every seat, the OpenRouter seats' model makers, the fallback, and unknown names

# Failure modes covered:
#  - a seat drawn with another vendor's mark, or a CLI seat not sharing its vendor's mark
#  - OpenAI's or xAI's seats and makers drawing no mark, or each other's
#  - an OpenRouter seat drawn with OpenRouter's mark when its model's maker has one, a `~`
#    alias prefix hiding the maker, or both of Meta's prefixes not recognised
#  - a maker with no mark, a model id with no maker part, or no model at all, drawing nothing
#    instead of OpenRouter's mark
#  - an unknown seat drawing some mark, including names that are properties of every
#    JavaScript object (constructor, __proto__), which a plain object lookup would find
#  - a mark name the mapping can return with no drawing behind it, or a colour that is neither
#    a hex value nor currentColor

load test_helper
bats_require_minimum_version 1.5.0

NODE="$(command -v node)"
MARKS_JS="${PROJECT_ROOT}/extension/server/marks.js"

setup() {
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*) skip "the Desktop extension supports macOS and Linux only" ;;
    esac
}

# Each argument is "seat model" (the model may be left out); prints one
# "seat=mark" per argument, with mark empty when the seat has none.
marks_for() {
    "$NODE" -e '
        const { seatMark } = require(process.argv[1])
        for (const pair of process.argv.slice(2)) {
            const [seat, model] = pair.split(" ")
            console.log(`${seat}=${seatMark(seat, model) ?? ""}`)
        }
    ' "$MARKS_JS" "$@"
}

@test "extension marks: each seat shows its vendor's mark, CLI seats sharing it" {
    assert_eq "$(marks_for 'gemini gemini-3-pro' 'antigravity gemini-3-flash' 'perplexity sonar-pro' \
        'kimi kimi-k2.6' 'kimi-cli kimi-k2.6' 'cursor-cli auto' 'copilot-cli gpt-6' 'opencode opencode/big-pickle' \
        'claude-cli claude-fable-5-1' 'ollama llama3.2')" \
        "$(printf '%s\n' gemini=gemini antigravity=gemini perplexity=perplexity kimi=kimi kimi-cli=kimi \
            cursor-cli=cursor copilot-cli=copilot opencode=opencode claude-cli=claude ollama=ollama)"
}

@test "extension marks: an OpenRouter seat shows its model maker's mark, a ~ alias included" {
    assert_eq "$(marks_for 'openrouter-1 deepseek/deepseek-v4.1-flash' 'openrouter-2 ~deepseek/deepseek-pro-latest' \
        'openrouter-3 meta-llama/llama-4-maverick' 'openrouter-4 meta/muse-spark' 'openrouter-5 anthropic/claude-fable-5.1' \
        'openrouter-6 ~anthropic/claude-sonnet-latest' 'openrouter-7 google/gemini-3-pro' 'openrouter-8 mistralai/mistral-large' \
        'openrouter-9 qwen/qwen3-max' 'openrouter-10 moonshotai/kimi-k2.6' 'openrouter-11 perplexity/sonar' \
        'openrouter anthropic/claude-fable-5.1')" \
        "$(printf '%s\n' openrouter-1=deepseek openrouter-2=deepseek openrouter-3=meta openrouter-4=meta \
            openrouter-5=anthropic openrouter-6=anthropic openrouter-7=google openrouter-8=mistral openrouter-9=qwen \
            openrouter-10=moonshot openrouter-11=perplexity openrouter=anthropic)"
}

@test "extension marks: an OpenRouter seat falls back to OpenRouter's mark" {
    assert_eq "$(marks_for 'openrouter-1 z-ai/glm-5' 'openrouter-2 openrouter/auto' 'openrouter-3 no-maker-part' \
        'openrouter-4' 'openrouter' 'openrouter-5 constructor/x' 'openrouter-6 __proto__/x')" \
        "$(printf '%s\n' openrouter-1=openrouter openrouter-2=openrouter openrouter-3=openrouter openrouter-4=openrouter \
            openrouter=openrouter openrouter-5=openrouter openrouter-6=openrouter)"
}

@test "extension marks: an unknown seat shows no mark" {
    assert_eq "$(marks_for 'mystery deepseek/x' 'openrouter-x deepseek/x' 'openrouterx deepseek/x' 'constructor' \
        '__proto__' 'toString' '')" \
        "$(printf '%s\n' mystery= openrouter-x= openrouterx= constructor= __proto__= toString= =)"
}

@test "extension marks: OpenAI's and xAI's seats and makers show OpenAI's and Grok's marks" {
    assert_eq "$(marks_for 'openai gpt-5.5' 'codex gpt-5.5' 'grok grok-latest' 'grok-cli grok-4' \
        'openrouter-7 openai/gpt-6-astra' 'openrouter-8 ~x-ai/grok-latest')" \
        "$(printf '%s\n' openai=openai codex=openai grok=grok grok-cli=grok openrouter-7=openai openrouter-8=grok)"
}

@test "extension marks: every mark the mapping can return has a drawing and a colour" {
    run "$NODE" -e '
        const { MARKS, SEAT_MARKS, MAKER_MARKS } = require(process.argv[1])
        const named = [...new Set([...SEAT_MARKS.values(), ...MAKER_MARKS.values(), "openrouter"])].sort()
        for (const name of named) {
            const mark = MARKS.get(name)
            const fine = mark !== undefined && /^(#[0-9A-F]{6}|currentColor)$/.test(mark.color) && /^[MmZzLlHhVvCcSsQqTtAa0-9.,\s-]+$/.test(mark.path)
            console.log(`${name} ${fine ? "drawable" : "MISSING"}`)
        }
    ' "$MARKS_JS"
    [ "$status" -eq 0 ]
    assert_eq "$output" "$(printf '%s drawable\n' anthropic claude copilot cursor deepseek gemini google grok kimi meta mistral \
        moonshot ollama openai opencode openrouter perplexity qwen)"
}
