#!/usr/bin/env bash
set -euo pipefail

VAULT="${AI_MEMORY_DIR:-$HOME/obsidian/Personal/ai-memory}"
LOG="${AI_MEMORY_LOG:-$HOME/.claude/ai-memory.log}"
CLAUDE_BIN="${AI_MEMORY_CLAUDE_BIN:-claude}"
MIN_USER_MESSAGES=4
FALLBACK_MODEL=claude-opus-5-5

if [ "${1:-}" != run ]; then
  input=$(mktemp -t ai-memory)
  cat >"$input"
  mkdir -p "$(dirname "$LOG")"
  # SessionEnd hooks get a 1.5s budget and Claude Code may tear down the process group on exit,
  # so the worker runs in its own session (macOS has no setsid binary, perl's POSIX::setsid does it)
  nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$0" run "$input" </dev/null >>"$LOG" 2>&1 &
  exit 0
fi

input="$2"
trap 'rm -f "$input" "${condensed:-}" "${tmp_note:-}"' EXIT
log() { echo "$(date '+%F %T') [$session_id] $*"; }

session_id=$(jq -r '.session_id' "$input")
transcript=$(jq -r '.transcript_path' "$input")
cwd=$(jq -r '.cwd // empty' "$input")

[ -f "$transcript" ] || { log "no transcript at $transcript"; exit 0; }

human_message='.type == "user" and (.isMeta | not) and (.message.content | type == "string") and (.message.content | startswith("<") | not)'

user_count=$(jq -c "select($human_message)" "$transcript" | wc -l | tr -d ' ')
if [ "$user_count" -lt "$MIN_USER_MESSAGES" ]; then
  log "skipped, $user_count user messages"
  exit 0
fi

model=$(jq -r 'select(.type == "assistant") | .message.model // empty' "$transcript" | grep -v '^<' | tail -1 || true)
model="${model:-$FALLBACK_MODEL}"

condensed=$(mktemp -t ai-memory)
jq -r "if $human_message then \"### User\n\" + .message.content + \"\n\"
  elif .type == \"assistant\" then (.message.content[]? | select(.type == \"text\") | \"### Assistant\n\" + .text + \"\n\")
  else empty end" "$transcript" | tail -c 8000000 >"$condensed"
# ponytail: tail keeps the end under the 10MB stdin cap, chunked summarizing if huge sessions lose too much

schema='{"type":"object","required":["title","tags","body"],"properties":{
  "title":{"type":"string","description":"Short descriptive title, under 70 characters"},
  "tags":{"type":"array","items":{"type":"string","pattern":"^[a-z0-9-]+$"},"maxItems":6},
  "body":{"type":"string","description":"Markdown note body without a top-level heading"}}}'

prompt='The stdin is a condensed transcript of a Claude Code session (user and assistant text only, tool calls removed).
Write a memory note so a future agent can recall what happened without rereading the session.

body must use exactly these markdown sections, in this order:
## Goal
One or two sentences on what the user wanted.
## Decisions
Bullets formatted "<decision> - <why>". Include decisions the user made or confirmed, and anything rejected along with the reason. Write "None" if there were none.
## Findings
Only include this section when the session involved research or investigation. Bullets with concrete facts learned, including sources or file paths when given.
## Open threads
Bullets of unfinished work or unanswered questions. Write "None" if there are none.

Rules:
- Never include secrets, API keys, tokens, passwords, credentials or .env values. Describe them generically if relevant
- Be specific and concise. Prefer exact names, paths, commands and numbers over vague summaries
- tags: 2 to 6 lowercase topic tags, hyphenated, no "claude-session" tag'

# -p prefers ANTHROPIC_API_KEY over the subscription login that interactive sessions use,
# and a stale key in the shell profile makes every summary fail with 401
# TODO: make this opt-out if a valid API key ever becomes the only auth
out=$(env -u ANTHROPIC_API_KEY "$CLAUDE_BIN" -p --safe-mode --tools "" --no-session-persistence --model "$model" \
  --output-format json --json-schema "$schema" "$prompt" <"$condensed") || true

title=$(jq -r '.structured_output.title // empty' <<<"$out" 2>/dev/null || true)
[ -n "$title" ] || { log "summarizer returned no structured output: $(head -c 500 <<<"$out")"; exit 1; }
body=$(jq -r '.structured_output.body' <<<"$out")
tags=$(jq -r '["claude-session"] + .structured_output.tags | unique | join(", ")' <<<"$out")

slug=$(tr '[:upper:]' '[:lower:]' <<<"$title" | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-60 | sed -E 's/-+$//')
mkdir -p "$VAULT/sessions"
note="$VAULT/sessions/$(date +%F)-$slug.md"

tmp_note=$(mktemp "$VAULT/sessions/.tmp.XXXXXX")
cat >"$tmp_note" <<EOF
---
date: $(date +%F)
agent: claude-code
model: $model
project: $cwd
session_id: $session_id
transcript: $transcript
tags: [$tags]
---
# $title

$body
EOF

old_notes=$(grep -lx "session_id: $session_id" "$VAULT"/sessions/*.md 2>/dev/null || true)
mv "$tmp_note" "$note"
tmp_note=
while IFS= read -r old; do
  [ -n "$old" ] && [ "$old" != "$note" ] && rm -f "$old"
done <<<"$old_notes"

log "saved $note"
