has() { command -v "$1" >/dev/null; }

# Summaries must bill the Claude subscription, never the API. -p always uses these credentials
# when present and they outrank the /login session (https://code.claude.com/docs/en/authentication#authentication-precedence)
SUBSCRIPTION_ONLY=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u ANTHROPIC_PROFILE
  -u ANTHROPIC_FEDERATION_RULE_ID -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY)

claude_auth_method() {
  "${SUBSCRIPTION_ONLY[@]}" "$CLAUDE_BIN" auth status 2>/dev/null | jq -r '.authMethod // empty' 2>/dev/null || true
}

is_subscription() {
  case "$1" in claude.ai | oauth_token) ;; *) return 1 ;; esac
}

# The desktop app can run OpenCode without an opencode binary on PATH, its config folder still shows it's in use
has_opencode() { has "$OPENCODE_BIN" || [ -d "$OPENCODE_DIR" ]; }

check_prereqs() {
  [ "$(uname)" = Darwin ] || die "macOS only, the qmd search server runs under launchd"
  has "$CLAUDE_BIN" || has_opencode || die "install Claude Code (https://code.claude.com/docs/en/setup) or OpenCode (https://opencode.ai) first"
}
