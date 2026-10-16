#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${AI_MEMORY_CONFIG:-$HOME/.config/ai-memory/env}"
[ ! -f "$CONFIG" ] || . "$CONFIG"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
LAUNCH_AGENTS="${LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
VAULT="${AI_MEMORY_DIR:-$HOME/obsidian/Personal/ai-memory}"
CLAUDE_BIN="${AI_MEMORY_CLAUDE_BIN:-claude}"
OPENCODE_BIN="${AI_MEMORY_OPENCODE_BIN:-opencode}"
QMD_BIN="${AI_MEMORY_QMD_BIN:-qmd}"
LAUNCHCTL="${AI_MEMORY_LAUNCHCTL:-launchctl}"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK="$CLAUDE_DIR/hooks/ai-memory-save.sh"
QMD_URL=http://localhost:8181/mcp
QMD_LABEL=ai-memory.qmd

die() { echo "ai-memory install: $*" >&2; exit 1; }
has() { command -v "$1" >/dev/null; }

[ "$(uname)" = Darwin ] || die "macOS only, the qmd search server runs under launchd"
has "$CLAUDE_BIN" || has "$OPENCODE_BIN" || die "install Claude Code (https://code.claude.com/docs/en/setup) or OpenCode (https://opencode.ai) first"
has brew || { has jq && has node; } || die "install Homebrew first: https://brew.sh"
has jq || brew install jq
has node || brew install node
[ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ] || die "qmd needs Node.js 22 or newer, run: brew upgrade node"
# qmd needs Homebrew's SQLite on macOS for its vector extension
brew list sqlite >/dev/null 2>&1 || brew install sqlite
has "$QMD_BIN" || npm install -g @tobilu/qmd

SUMMARIZER="${AI_MEMORY_SUMMARIZER:-$(has "$CLAUDE_BIN" && echo claude || echo opencode)}"
SUMMARY_MODEL="${AI_MEMORY_SUMMARY_MODEL:-}"
case "$SUMMARIZER" in
  claude)
    has "$CLAUDE_BIN" || die "AI_MEMORY_SUMMARIZER=claude needs Claude Code"
    auth_method=$(env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN "$CLAUDE_BIN" auth status 2>/dev/null | jq -r '.authMethod // empty' 2>/dev/null || true)
    case "$auth_method" in
      claude.ai | oauth_token) ;;
      *) echo "warning: Claude Code is not logged in with a Claude subscription (auth: '${auth_method:-none}'). Run claude /login, or no notes will be saved" >&2 ;;
    esac ;;
  opencode)
    has "$OPENCODE_BIN" || die "AI_MEMORY_SUMMARIZER=opencode needs OpenCode"
    [ -n "$SUMMARY_MODEL" ] || die "set AI_MEMORY_SUMMARY_MODEL to the OpenCode model that writes summaries (provider/model), pick the strongest from: opencode models" ;;
  *) die "AI_MEMORY_SUMMARIZER must be claude or opencode" ;;
esac

mkdir -p "$(dirname "$CONFIG")"
printf 'AI_MEMORY_DIR="${AI_MEMORY_DIR:-%s}"\nAI_MEMORY_SUMMARIZER="${AI_MEMORY_SUMMARIZER:-%s}"\nAI_MEMORY_SUMMARY_MODEL="${AI_MEMORY_SUMMARY_MODEL:-%s}"\n' \
  "$VAULT" "$SUMMARIZER" "$SUMMARY_MODEL" >"$CONFIG"

mkdir -p "$VAULT/sessions" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/skills"
cp "$REPO/vault/README.md" "$VAULT/README.md"

chmod +x "$REPO/hooks/ai-memory-save.sh"
ln -sfn "$REPO/hooks/ai-memory-save.sh" "$HOOK"
# OpenCode also loads skills from ~/.claude/skills, so this one copy serves both agents
ln -sfn "$REPO/skills/recall" "$CLAUDE_DIR/skills/recall"

add_rule() {
  grep -qs '/recall' "$1" || printf '\n- Before recommending a design or tool choice, check `/recall` for earlier decisions on it. If the choice was already replaced or rejected, say so and give the reason before going further\n' >>"$1"
}
# OpenCode reads ~/.claude/CLAUDE.md only when it has no AGENTS.md of its own
if [ -f "$OPENCODE_DIR/AGENTS.md" ]; then add_rule "$OPENCODE_DIR/AGENTS.md"; fi
if has "$CLAUDE_BIN" || [ ! -f "$OPENCODE_DIR/AGENTS.md" ]; then add_rule "$CLAUDE_DIR/CLAUDE.md"; fi

if has "$CLAUDE_BIN"; then
  mkdir -p "$CLAUDE_DIR/commands"
  ln -sfn "$REPO/claude/commands/save-memory.md" "$CLAUDE_DIR/commands/save-memory.md"
  [ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
  [ -f "$SETTINGS.ai-memory.bak" ] || cp "$SETTINGS" "$SETTINGS.ai-memory.bak"
  updated=$(jq --arg cmd "$HOOK" '
    .hooks.SessionEnd = (
      [(.hooks.SessionEnd // [])[] | .hooks |= map(select(.command != $cmd)) | select(.hooks | length > 0)]
      + [{hooks: [{type: "command", command: $cmd}]}]
    )
    | .permissions.allow = ((.permissions.allow // []) + ["mcp__qmd__query", "mcp__qmd__get", "mcp__qmd__multi_get"] | unique)
    ' "$SETTINGS")
  printf '%s\n' "$updated" >"$SETTINGS"
fi

"$QMD_BIN" collection list 2>/dev/null | grep -q '^ai-memory ' || {
  "$QMD_BIN" collection add "$VAULT/sessions" --name ai-memory >/dev/null
  "$QMD_BIN" context add qmd://ai-memory "Summaries of past AI agent sessions: goals, decisions with what they replaced or rejected and why, findings, open threads" >/dev/null
}
"$QMD_BIN" update >/dev/null
"$QMD_BIN" embed >/dev/null

# One always-on qmd server shared by Claude Code and OpenCode keeps its models loaded,
# a per-client stdio server would reload them (about 25s cold) in every new session
mkdir -p "$LAUNCH_AGENTS"
plist="$LAUNCH_AGENTS/$QMD_LABEL.plist"
cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$QMD_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$(command -v "$QMD_BIN")</string><string>mcp</string><string>--http</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$PATH</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/$QMD_LABEL.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/$QMD_LABEL.log</string>
</dict>
</plist>
EOF
"$LAUNCHCTL" bootout "gui/$(id -u)/$QMD_LABEL" 2>/dev/null || true
"$LAUNCHCTL" bootstrap "gui/$(id -u)" "$plist"

if has "$CLAUDE_BIN"; then
  "$CLAUDE_BIN" mcp get qmd >/dev/null 2>&1 || "$CLAUDE_BIN" mcp add --scope user --transport http qmd "$QMD_URL" >/dev/null
fi

if [ -d "$OPENCODE_DIR" ] || has "$OPENCODE_BIN"; then
  mkdir -p "$OPENCODE_DIR/plugins"
  ln -sfn "$REPO/opencode/plugins/ai-memory.js" "$OPENCODE_DIR/plugins/ai-memory.js"
  config="$OPENCODE_DIR/opencode.jsonc"
  [ -f "$config" ] || config="$OPENCODE_DIR/opencode.json"
  [ -f "$config" ] || echo '{"$schema": "https://opencode.ai/config.json"}' >"$config"
  [ -f "$config.ai-memory.bak" ] || cp "$config" "$config.ai-memory.bak"
  if updated=$(jq --arg url "$QMD_URL" '.mcp.qmd = {type: "remote", url: $url, enabled: true}' "$config" 2>/dev/null); then
    printf '%s\n' "$updated" >"$config"
  else
    echo "could not edit $config (comments?), add this under \"mcp\" by hand: \"qmd\": {\"type\": \"remote\", \"url\": \"$QMD_URL\", \"enabled\": true}" >&2
  fi
fi

echo "installed: vault -> $VAULT, summaries by $SUMMARIZER${SUMMARY_MODEL:+ ($SUMMARY_MODEL)}, settings in $CONFIG"
echo "qmd search server -> $QMD_URL (launchd $QMD_LABEL)"
if has "$CLAUDE_BIN"; then echo "Claude Code: hook, /recall, /save-memory, qmd registered. Settings backup: $SETTINGS.ai-memory.bak"; fi
if [ -d "$OPENCODE_DIR" ]; then echo "run 'opencode service restart' when no OpenCode session is busy, to load the plugin"; fi
