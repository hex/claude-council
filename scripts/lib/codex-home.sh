#!/bin/bash
# ABOUTME: Builds the CODEX_HOME a codex seat runs under: the user's login and model, none of their plugins, hooks or skills
# ABOUTME: Shared by the council's codex seat and the heads-up check, so both launch codex the same way
#
# Needs toml_value from lib/providers.sh.

# Writes the config.toml of HOME_DIR, so none of the user's plugins, hooks,
# AGENTS.md, skills, memories or MCP servers ride along: it holds MODEL and
# EFFORT and switches the rest off. An empty one is left out for codex to
# choose. Each value is a TOML basic string: JSON's string escapes are all
# valid there, DEL and the other control characters included.
# Usage: codex_home HOME_DIR MODEL EFFORT
codex_home() {
    local home="$1" model="$2" effort="$3" quoted_model quoted_effort
    mkdir -p "$home"
    {
        if [[ -n "$model$effort" ]]; then
            # One line from jq, split on a tab tojson never writes: jq's Windows
            # build ends each line with CRLF, and $(...) strips only the last \r.
            IFS=$'\t' read -r quoted_model quoted_effort <<< "$(jq -rn --arg m "$model" --arg e "$effort" '[$m, $e] | map(tojson) | join("\t")')"
            [[ -n "$model" ]] && printf 'model = %s\n' "$quoted_model"
            [[ -n "$effort" ]] && printf 'model_reasoning_effort = %s\n' "$quoted_effort"
            echo
        fi
        printf '%s\n' '[skills]' 'include_instructions = false' '' \
            '[skills.bundled]' 'enabled = false' '' \
            '[features]' 'plugins = false' 'apps = false' 'hooks = false' 'memories = false'
    } > "${home}/config.toml"
}

# Links the user's auth.json into HOME_DIR, when they have one; an API key
# reaches codex through the environment instead. codex-cli 0.164.0 refreshes its
# token by rewriting auth.json in place (read from its source, not a promise
# codex makes), so through a link the refresh lands in the user's login; in a
# copy it would vanish with the home. A hard link where a symlink is refused
# (Windows without developer mode) or comes out as a copy (as Git Bash can
# make one). ln's complaint goes to ERR_FILE.
# Usage: link_login HOME_DIR USER_HOME ERR_FILE
link_login() {
    local link="${1}/auth.json" login="${2}/auth.json"
    [[ -f "$login" ]] || return 0
    if ln -s "$login" "$link" 2> /dev/null && [[ "$link" -ef "$login" ]]; then
        return 0
    fi
    rm -f "$link"
    ln "$login" "$link" 2> "$3"
}

# Prints the user's cli_auth_credentials_store and returns 0 when their login
# can only be in the system keyring: no auth.json in USER_HOME and the store
# set to keyring or auto. Such a login cannot follow codex into a home of its
# own: codex 0.164.0 names the keyring entry after a hash of the CODEX_HOME
# path (compute_store_key in its login/src/auth/storage.rs). An exported API
# key does not stand in for it, since in that home the key would sign codex
# in, on API billing, in place of the login the user chose. Returns 1 otherwise.
# Usage: keyring_store USER_HOME
keyring_store() {
    local store
    [[ -f "${1}/auth.json" ]] && return 1
    store=$(toml_value "${1}/config.toml" "" cli_auth_credentials_store)
    [[ "$store" == keyring || "$store" == auto ]] || return 1
    printf '%s' "$store"
}

# Builds HOME_DIR, the CODEX_HOME a codex seat runs under, from the user's
# codex home USER_HOME: its config.toml (codex_home) with the model,
# CODEX_MODEL else the user's, and the effort, EFFORT else the user's, then
# their login (link_login). When the user's setup cannot be carried into a home
# of codex's own, or the login cannot be linked, prints why on one line and
# returns 1; EXCERPT names the function that shortens ln's complaint in
# ERR_FILE for that line.
# Usage: codex_seat_home HOME_DIR USER_HOME ERR_FILE EXCERPT [EFFORT]
codex_seat_home() {
    local home="$1" user_home="$2" err="$3" excerpt="$4" config="${2}/config.toml" model effort provider profile store
    if store=$(keyring_store "$user_home"); then
        printf "codex: no auth.json in %s and cli_auth_credentials_store = \"%s\", so the login is in the system keyring, which a home of codex's own cannot read; set it to \"file\" and run codex login again" "$user_home" "$store"
        return 1
    fi
    # With neither a file login to link nor CODEX_API_KEY or OPENAI_API_KEY set
    # (not logged in, or an ephemeral store), codex has nothing to sign in with.
    if [[ ! -f "${user_home}/auth.json" && -z "${CODEX_API_KEY:-}${OPENAI_API_KEY:-}" ]]; then
        printf "codex: no auth.json in %s and no CODEX_API_KEY or OPENAI_API_KEY; the codex seat needs a file login or an API key" "$user_home"
        return 1
    fi
    { IFS= read -r model; IFS= read -r effort; IFS= read -r provider; IFS= read -r profile; } \
        <<< "$(toml_value "$config" "" model model_reasoning_effort model_provider profile)" || true
    # A custom provider's table can carry headers, an env key the scrub drops
    # and nested tables, so it is refused rather than copied.
    if [[ -n "$provider" && "$provider" != openai ]]; then
        printf "codex: %s sets model_provider \"%s\"; the codex seat runs codex's built-in openai provider only" "$config" "$provider"
        return 1
    fi
    # A profile can name its own model, effort and provider; the home copies
    # the root keys only, so it would run something other than the user's codex.
    if [[ -n "$profile" ]]; then
        printf "codex: %s sets profile \"%s\"; the codex seat reads only the root model and effort" "$config" "$profile"
        return 1
    fi
    codex_home "$home" "${CODEX_MODEL:-$model}" "${5:-$effort}"
    if ! link_login "$home" "$user_home" "$err"; then
        printf 'codex: could not link %s/auth.json into %s: %s' "$user_home" "$home" "$("$excerpt" "$err")"
        return 1
    fi
}
