#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
VAULT="${AI_MEMORY_DIR:-$HOME/obsidian/Personal/ai-memory}"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK="$CLAUDE_DIR/hooks/ai-memory-save.sh"

for bin in jq perl claude; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 1; }
done

mkdir -p "$VAULT/sessions" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/skills"
cp "$REPO/vault/README.md" "$VAULT/README.md"

chmod +x "$REPO/hooks/ai-memory-save.sh"
ln -sfn "$REPO/hooks/ai-memory-save.sh" "$HOOK"
ln -sfn "$REPO/skills/recall" "$CLAUDE_DIR/skills/recall"

[ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
cp "$SETTINGS" "$SETTINGS.ai-memory.bak"
updated=$(jq --arg cmd "$HOOK" '
  .hooks.SessionEnd = (
    [(.hooks.SessionEnd // [])[] | .hooks |= map(select(.command != $cmd)) | select(.hooks | length > 0)]
    + [{hooks: [{type: "command", command: $cmd}]}]
  )' "$SETTINGS")
printf '%s\n' "$updated" >"$SETTINGS"

echo "installed: hook -> $HOOK, skill -> $CLAUDE_DIR/skills/recall, vault -> $VAULT"
echo "settings backup: $SETTINGS.ai-memory.bak"
