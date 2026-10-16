#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
LAUNCH_AGENTS="${LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
VAULT="${AI_MEMORY_DIR:-$HOME/obsidian/Personal/ai-memory}"
CLAUDE_BIN="${AI_MEMORY_CLAUDE_BIN:-claude}"
QMD_BIN="${AI_MEMORY_QMD_BIN:-qmd}"
LAUNCHCTL="${AI_MEMORY_LAUNCHCTL:-launchctl}"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK="$CLAUDE_DIR/hooks/ai-memory-save.sh"
QMD_URL=http://localhost:8181/mcp
QMD_LABEL=ai-memory.qmd

for bin in jq perl "$CLAUDE_BIN" "$QMD_BIN"; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin (qmd: npm install -g @tobilu/qmd)" >&2; exit 1; }
done

mkdir -p "$VAULT/sessions" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/skills" "$CLAUDE_DIR/commands"
cp "$REPO/vault/README.md" "$VAULT/README.md"

chmod +x "$REPO/hooks/ai-memory-save.sh"
ln -sfn "$REPO/hooks/ai-memory-save.sh" "$HOOK"
ln -sfn "$REPO/skills/recall" "$CLAUDE_DIR/skills/recall"
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

"$CLAUDE_BIN" mcp get qmd >/dev/null 2>&1 || "$CLAUDE_BIN" mcp add --scope user --transport http qmd "$QMD_URL" >/dev/null

if [ -d "$OPENCODE_DIR" ]; then
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

echo "installed: hook -> $HOOK, skill -> $CLAUDE_DIR/skills/recall, vault -> $VAULT"
echo "qmd search server -> $QMD_URL (launchd $QMD_LABEL), registered in Claude Code and OpenCode"
echo "settings backup: $SETTINGS.ai-memory.bak"
if [ -d "$OPENCODE_DIR" ]; then echo "run 'opencode service restart' when no OpenCode session is busy, to load the plugin"; fi
