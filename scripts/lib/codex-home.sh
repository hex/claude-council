#!/bin/bash
# ABOUTME: Builds the CODEX_HOME a codex seat runs under: the user's login and model, none of their plugins, hooks or skills
# ABOUTME: Shared by the council's codex seat and the heads-up check, so both launch codex the same way
#
# Needs toml_value from lib/providers.sh.

# One key of codex's config.toml, its value a TOML basic string: JSON's string
# escapes are all valid there, DEL and the other control characters included.
toml_line() {
    printf '%s = %s\n' "$1" "$(jq -rn --arg v "$2" '$v | tojson')"
}

# Writes the config.toml of HOME_DIR, so none of the user's plugins, hooks,
# AGENTS.md, skills, memories or MCP servers ride along: it holds the model and
# effort and switches the rest off. The model is CODEX_MODEL, else the user's;
# the effort is EFFORT, else the user's; a key neither names is left out for
# codex to choose. A file login is linked in by link_login; an API key
# reaches codex through the environment.
# Usage: codex_home HOME_DIR USER_HOME [EFFORT]
codex_home() {
    local home="$1" user_home="$2" model effort
    model="${CODEX_MODEL:-$(toml_value "${user_home}/config.toml" "" model)}"
    effort="${3:-$(toml_value "${user_home}/config.toml" "" model_reasoning_effort)}"
    mkdir -p "$home"
    {
        [[ -n "$model" ]] && toml_line model "$model"
        [[ -n "$effort" ]] && toml_line model_reasoning_effort "$effort"
        [[ -n "$model$effort" ]] && echo
        cat <<'EOF'
[skills]
include_instructions = false

[skills.bundled]
enabled = false

[features]
plugins = false
apps = false
hooks = false
memories = false
EOF
    } > "${home}/config.toml"
}

# Why the user's codex setup cannot be carried into a home of codex's own, on
# one line; nothing when it can. With neither a file login to link nor
# CODEX_API_KEY or OPENAI_API_KEY set (the keyring store, or not logged in),
# codex has nothing to sign in with there.
# Usage: codex_home_refusal USER_HOME
codex_home_refusal() {
    local user_home="$1" config="${1}/config.toml" provider profile
    if [[ ! -f "${user_home}/auth.json" && -z "${CODEX_API_KEY:-}${OPENAI_API_KEY:-}" ]]; then
        printf "codex: no auth.json in %s and no CODEX_API_KEY or OPENAI_API_KEY; the codex seat needs a file login or an API key" "$user_home"
        return 0
    fi
    # A custom provider's table can carry headers, an env key the scrub drops
    # and nested tables, so it is refused rather than copied.
    provider=$(toml_value "$config" "" model_provider)
    if [[ -n "$provider" && "$provider" != openai ]]; then
        printf "codex: %s sets model_provider \"%s\"; the codex seat runs codex's built-in openai provider only" "$config" "$provider"
        return 0
    fi
    # A profile can name its own model, effort and provider; the home copies
    # the root keys only, so it would run something other than the user's codex.
    profile=$(toml_value "$config" "" profile)
    if [[ -n "$profile" ]]; then
        printf "codex: %s sets profile \"%s\"; the codex seat reads only the root model and effort" "$config" "$profile"
    fi
}

# Links the user's auth.json into HOME_DIR. codex-cli 0.164.0 refreshes its
# token by rewriting auth.json in place (read from its source, not a promise
# codex makes), so through a link the refresh lands in the user's login; in a
# copy it would vanish with the home. A hard link where a symlink is refused
# (Windows without developer mode) or comes out as a copy (as Git Bash can
# make one). ln's complaint goes to ERR_FILE.
# Usage: link_login HOME_DIR USER_HOME ERR_FILE
link_login() {
    local link="${1}/auth.json" login="${2}/auth.json"
    if ln -s "$login" "$link" 2> /dev/null && [[ "$link" -ef "$login" ]]; then
        return 0
    fi
    rm -f "$link"
    ln "$login" "$link" 2> "$3"
}
