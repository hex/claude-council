#!/usr/bin/env bats
# ABOUTME: Reads each provider's model-list answer the way the extension's settings panel does
# ABOUTME: Against one recorded real answer (OpenRouter) and the documented shapes of the others

# Fixtures in tests/fixtures/extension/: *.recorded.json is a real answer, cut
# down to a few entries (OpenRouter's list endpoint, which needs no key,
# recorded 2026-11-12); *.documented.json follows the shape the vendor's API
# reference gives, since recording it needs a key. Failure modes covered:
#  - an id the scripts' environment cannot carry (a space) is dropped
#  - a listed id appearing twice shows once, and the list is sorted
#  - Gemini models that cannot answer (embedding) are dropped, and their models/ prefix is cut
#  - xAI's grok-latest, served but not listed, is offered
#  - Perplexity, which has no list endpoint, offers its five presets in their order
#  - an answer with no list in it is an error, not an empty list

load test_helper
bats_require_minimum_version 1.5.0

NODE="$(command -v node)"
MODELS_JS="${PROJECT_ROOT}/extension/server/models.js"
FIXTURES="${BATS_TEST_DIRNAME}/fixtures/extension"

setup() {
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*) skip "the Desktop extension supports macOS and Linux only" ;;
    esac
}

# The ids the panel would offer for a provider's answer, comma-separated.
ids_for() {
    "$NODE" -e '
        const models = require(process.argv[1])
        const body = process.argv[3] === "" ? undefined : JSON.parse(require("fs").readFileSync(process.argv[3], "utf8"))
        process.stdout.write(models.modelIds(process.argv[2], body).join(","))
    ' "$MODELS_JS" "$1" "${2:-}"
}

@test "extension models: OpenRouter's recorded list, aliases kept, sorted" {
    assert_eq "$(ids_for openrouter "${FIXTURES}/openrouter-models.recorded.json")" \
        'anthropic/claude-fable-5.2,anthropic/claude-fable-5.2:batch,openai/gpt-6-astra,~deepseek/deepseek-pro-latest'
}

@test "extension models: OpenAI's list drops an id with a space and shows a repeated id once" {
    assert_eq "$(ids_for openai "${FIXTURES}/openai-models.documented.json")" 'gpt-5.5-mini,gpt-6-astra'
}

@test "extension models: Gemini keeps only models that answer, without the models/ prefix" {
    assert_eq "$(ids_for gemini "${FIXTURES}/gemini-models.documented.json")" 'gemini-3-pro,gemini-flash-latest'
}

@test "extension models: xAI's list offers grok-latest, which it serves but does not list" {
    assert_eq "$(ids_for grok "${FIXTURES}/xai-models.documented.json")" 'grok-4.7,grok-4.7-fast,grok-latest'
}

@test "extension models: Kimi's list is read like OpenAI's" {
    assert_eq "$(ids_for kimi "${FIXTURES}/kimi-models.documented.json")" 'kimi-k3,moonshot-v1-8k'
}

@test "extension models: Perplexity offers its five presets in order, asking nothing" {
    assert_eq "$(ids_for perplexity)" 'fast,low,medium,high,xhigh'
}

@test "extension models: an answer with no list in it is an error" {
    printf '%s\n' '{"error":{"message":"Incorrect API key provided"}}' > "${BATS_TEST_TMPDIR}/error.json"
    run --separate-stderr ids_for openai "${BATS_TEST_TMPDIR}/error.json"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Error: the answer held no model list"* ]]
}
