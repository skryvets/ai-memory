#!/usr/bin/env bash
set -euo pipefail

VAULT="${AI_MEMORY_DIR:-$HOME/obsidian/Personal/ai-memory}"
LOG="${AI_MEMORY_LOG:-$HOME/.claude/ai-memory.log}"
CLAUDE_BIN="${AI_MEMORY_CLAUDE_BIN:-claude}"
LOCK="${AI_MEMORY_LOCK:-$HOME/.claude/ai-memory.lock}"
LOCK_WAIT_SECONDS="${AI_MEMORY_LOCK_WAIT:-900}"
HOOK_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
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
trap 'rm -f "$input" "${condensed:-}" "${tmp_note:-}"; [ -z "${have_lock:-}" ] || rm -rf "$LOCK"' EXIT
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

# Summaries must bill the Claude subscription, never the API. -p always uses these credentials
# when present and they outrank the /login session (https://code.claude.com/docs/en/authentication#authentication-precedence)
subscription_only=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u ANTHROPIC_PROFILE
  -u ANTHROPIC_FEDERATION_RULE_ID -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY)
auth_method=$("${subscription_only[@]}" "$CLAUDE_BIN" auth status 2>/dev/null | jq -r '.authMethod // empty' 2>/dev/null || true)
case "$auth_method" in
  claude.ai | oauth_token) ;;
  *) log "refusing to summarize, auth is '${auth_method:-unknown}' not a Claude subscription, run claude /login"; exit 1 ;;
esac

out=$("${subscription_only[@]}" "$CLAUDE_BIN" -p --safe-mode --tools "" --no-session-persistence --model "$model" \
  --output-format json --json-schema "$schema" "$prompt" <"$condensed") || true

title=$(jq -r '.structured_output.title // empty' <<<"$out" 2>/dev/null || true)
[ -n "$title" ] || { log "summarizer returned no structured output: $(head -c 500 <<<"$out")"; exit 1; }
body=$(jq -r '.structured_output.body' <<<"$out")
tags=$(jq -r '["claude-session"] + .structured_output.tags | unique | join(", ")' <<<"$out")

mkdir -p "$VAULT/sessions"
old_notes=$(grep -lx "session_id: $session_id" "$VAULT"/sessions/*.md 2>/dev/null || true)
# A resumed session keeps its original file name so [[sessions/...]] links in merged pages stay valid
note=$(head -1 <<<"$old_notes")
if [ -z "$note" ]; then
  slug=$(tr '[:upper:]' '[:lower:]' <<<"$title" | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-60 | sed -E 's/-+$//')
  note="$VAULT/sessions/$(date +%F)-$slug.md"
fi

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

[ -d "$VAULT/.git" ] || git -C "$VAULT" init -q -b main
commit() {
  git -C "$VAULT" add -A
  git -C "$VAULT" diff --cached --quiet && return 0
  # Fixed identity marks agent commits apart from the user's, and no signing so a Touch ID or GPG prompt can't hang a background job
  git -C "$VAULT" -c user.name="ai-memory hook" -c user.email=ai-memory@localhost -c commit.gpgsign=false commit -qm "$1"
}

waited=0
until mkdir "$LOCK" 2>/dev/null; do
  holder=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
    rm -rf "$LOCK"
    continue
  fi
  if [ "$waited" -ge "$LOCK_WAIT_SECONDS" ]; then
    log "merge lock busy for ${LOCK_WAIT_SECONDS}s, session note kept but not merged"
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done
echo $$ >"$LOCK/pid"
have_lock=1

note_link=$(basename "$note" .md)
merge_prompt=$(sed -e "s|{{NOTE}}|sessions/$note_link.md|g" -e "s|{{NOTE_LINK}}|$note_link|g" "$HOOK_DIR/merge-prompt.md")
merge_schema='{"type":"object","required":["changes"],"properties":{"changes":{"type":"array","items":{
  "type":"object","required":["path","content","summary"],"properties":{
  "path":{"type":"string"},"content":{"type":"string"},"summary":{"type":"string"}}}}}}'

# The merge agent can only read the vault (cwd, no Bash, reads elsewhere are denied rather than prompted).
# It proposes whole-file contents and this script does every write, to allowlisted paths only
merge_out=$(cd "$VAULT" && "${subscription_only[@]}" "$CLAUDE_BIN" -p --safe-mode --no-session-persistence --model "$model" \
  --tools "Read,Glob,Grep" --permission-prompts none \
  --output-format json --json-schema "$merge_schema" "$merge_prompt" </dev/null) || true

if ! jq -e '.structured_output.changes | type == "array"' <<<"$merge_out" >/dev/null 2>&1; then
  log "merge failed, session note kept: $(head -c 500 <<<"$merge_out")"
  commit "session: $title (merge failed)"
  exit 1
fi

allowed='^(index\.md|(projects|topics)/[a-z0-9][a-z0-9-]*/(README|decisions|research|design)\.md|knowledge/[a-z0-9][a-z0-9-]*\.md)$'
count=$(jq '.structured_output.changes | length' <<<"$merge_out")
for ((i = 0; i < count; i++)); do
  path=$(jq -r ".structured_output.changes[$i].path" <<<"$merge_out")
  if ! grep -Eq "$allowed" <<<"$path"; then
    log "merge rejected path outside allowlist: $path"
    continue
  fi
  mkdir -p "$VAULT/$(dirname "$path")"
  jq -r ".structured_output.changes[$i].content" <<<"$merge_out" >"$VAULT/$path"
  log "merged $path - $(jq -r ".structured_output.changes[$i].summary" <<<"$merge_out")"
done
commit "merge: $title"
