#!/usr/bin/env bash
set -euo pipefail

CONFIG="${AI_MEMORY_CONFIG:-$HOME/.config/ai-memory/env}"
[ ! -f "$CONFIG" ] || . "$CONFIG"
VAULT="${AI_MEMORY_DIR:-$HOME/obsidian/Personal/ai-memory}"
LOG="${AI_MEMORY_LOG:-$HOME/.claude/ai-memory.log}"
CLAUDE_BIN="${AI_MEMORY_CLAUDE_BIN:-claude}"
OPENCODE_BIN="${AI_MEMORY_OPENCODE_BIN:-opencode}"
QMD_BIN="${AI_MEMORY_QMD_BIN:-qmd}"
CLAUDE_PROJECTS="${AI_MEMORY_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
QUIET_SECONDS="${AI_MEMORY_QUIET_SECONDS:-600}"
SUMMARIZER="${AI_MEMORY_SUMMARIZER:-claude}"
SUMMARY_MODEL="${AI_MEMORY_SUMMARY_MODEL:-}"
MIN_USER_MESSAGES=4
FALLBACK_MODEL=claude-opus-5-5

detach() {
  mkdir -p "$(dirname "$LOG")"
  # SessionEnd hooks get a 1.5s budget and the agent may tear down its process group on exit,
  # so the worker runs in its own session (macOS has no setsid binary, perl's POSIX::setsid does it)
  nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$0" run "$@" </dev/null >>"$LOG" 2>&1 &
}

case "${1:-}" in
  run) ;;
  save) detach claude-code force "$2"; echo "Saving this session to ai-memory in the background"; exit 0 ;;
  opencode-idle) detach opencode idle "$2"; exit 0 ;;
  opencode-save) detach opencode force "$2"; echo "Saving this session to ai-memory in the background"; exit 0 ;;
  *)
    input=$(cat)
    detach claude-code auto "$(jq -r .session_id <<<"$input")" "$(jq -r .transcript_path <<<"$input")" "$(jq -r '.cwd // empty' <<<"$input")"
    exit 0 ;;
esac

agent="$2" mode="$3" session_id="$4" transcript="${5:-}" cwd="${6:-}"
trap 'rm -f "${export_file:-}" "${condensed:-}" "${tmp_note:-}"' EXIT
log() { echo "$(date '+%F %T') [$session_id] $*" >&2; }
condensed=$(mktemp -t ai-memory)
max_chars=8000000
# ponytail: OpenCode models (Copilot) have ~128k-token windows and no stdin cap, keep the last ~100k tokens
[ "$SUMMARIZER" != opencode ] || max_chars=400000

if [ "$agent" = opencode ]; then
  if [ "$mode" = idle ]; then
    sleep "$QUIET_SECONDS"
  fi
  export_file=$(mktemp -t ai-memory)
  "$OPENCODE_BIN" session export "$session_id" >"$export_file" 2>/dev/null || { log "opencode session export failed"; exit 1; }
  if [ "$mode" = idle ] && [ $(($(date +%s) - $(jq '.info.time.updated / 1000 | floor' "$export_file"))) -lt "$QUIET_SECONDS" ]; then
    exit 0
  fi
  transcript="opencode session export $session_id"
  cwd=$(jq -r '.info.location.directory // empty' "$export_file")
  user_count=$(jq '[.messages[] | select(.type == "user")] | length' "$export_file")
  model=$(jq -r '[.messages[] | select(.type == "assistant") | .model.id // empty] | last // .info.model.id // "unknown"' "$export_file")
  summarizer_model="$FALLBACK_MODEL"
  session_tag=opencode-session
  jq -r '.messages[] | if .type == "user" then "### User\n" + .text + "\n"
    elif .type == "assistant" then (.content[]? | select(.type == "text" and .text != "") | "### Assistant\n" + .text + "\n")
    else empty end' "$export_file" | tail -c "$max_chars" >"$condensed"
else
  if [ -z "$transcript" ]; then
    transcript=$(ls "$CLAUDE_PROJECTS"/*/"$session_id.jsonl" 2>/dev/null | head -1 || true)
  fi
  [ -f "$transcript" ] || { log "no transcript at '$transcript'"; exit 0; }
  [ -n "$cwd" ] || cwd=$(jq -r '.cwd // empty' "$transcript" | tail -1)

  human_message='.type == "user" and (.isMeta | not) and (.message.content | type == "string") and (.message.content | startswith("<") | not)'
  user_count=$(jq -c "select($human_message)" "$transcript" | wc -l | tr -d ' ')
  model=$(jq -r 'select(.type == "assistant") | .message.model // empty' "$transcript" | grep -v '^<' | tail -1 || true)
  model="${model:-$FALLBACK_MODEL}"
  summarizer_model="$model"
  session_tag=claude-session
  jq -r "if $human_message then \"### User\n\" + .message.content + \"\n\"
    elif .type == \"assistant\" then (.message.content[]? | select(.type == \"text\") | \"### Assistant\n\" + .text + \"\n\")
    else empty end" "$transcript" | tail -c "$max_chars" >"$condensed"
fi
# ponytail: tail keeps the end under the 10MB stdin cap, chunked summarizing if huge sessions lose too much

if [ "$mode" != force ] && [ "$user_count" -lt "$MIN_USER_MESSAGES" ]; then
  log "skipped, $user_count user messages"
  exit 0
fi

schema='{"type":"object","required":["title","tags","body"],"properties":{
  "title":{"type":"string","description":"Short descriptive title, under 70 characters"},
  "tags":{"type":"array","items":{"type":"string","pattern":"^[a-z0-9-]+$"},"maxItems":6},
  "body":{"type":"string","description":"Markdown note body without a top-level heading"}}}'

prompt='The stdin is a condensed transcript of an AI coding agent session (user and assistant text only, tool calls removed).
Write a memory note so a future agent can recall what happened without rereading the session.

body must use exactly these markdown sections, in this order:
## Goal
One or two sentences on what the user wanted.
## Decisions
One bullet per decision the user made or confirmed, formatted "<decision> - <why>". Under it, indented sub-bullets when they apply:
  - Replaced: <the earlier choice> - <what made it wrong: the edge case, failure or new fact>. Use this when the session first chose something and then switched, or changed a decision from an earlier session. For an earlier session, add its date and its [[sessions/<note-name>]] link when the transcript names them
  - Rejected: <an alternative considered> - <why not>
These sub-bullets are the most important part of the note: they stop a future session from re-making a choice that was already tried and dropped. Keep the edge case concrete. Write "None" if there were no decisions.
## Findings
Only include this section when the session involved research or investigation. Bullets with concrete facts learned, including sources or file paths when given.
## Open threads
Bullets of unfinished work or unanswered questions. Write "None" if there are none.

Rules:
- Never include secrets, API keys, tokens, passwords, credentials or .env values. Describe them generically if relevant
- Be specific and concise. Prefer exact names, paths, commands and numbers over vague summaries
- tags: 2 to 6 lowercase topic tags, hyphenated, no "claude-session" or "opencode-session" tag. Name the topics the session covered (a project, a tool, a technology, a domain) so later sessions on the same topic find this note'

summarize_with_claude() {
  # Summaries must bill the Claude subscription, never the API. -p always uses these credentials
  # when present and they outrank the /login session (https://code.claude.com/docs/en/authentication#authentication-precedence)
  local subscription_only=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u ANTHROPIC_PROFILE
    -u ANTHROPIC_FEDERATION_RULE_ID -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY)
  local auth_method
  auth_method=$("${subscription_only[@]}" "$CLAUDE_BIN" auth status 2>/dev/null | jq -r '.authMethod // empty' 2>/dev/null || true)
  case "$auth_method" in
    claude.ai | oauth_token) ;;
    *) log "refusing to summarize, auth is '${auth_method:-unknown}' not a Claude subscription, run claude /login"; exit 1 ;;
  esac
  "${subscription_only[@]}" "$CLAUDE_BIN" -p --safe-mode --tools "" --no-session-persistence --model "${SUMMARY_MODEL:-$summarizer_model}" \
    --output-format json --json-schema "$schema" "$prompt" <"$condensed" || true
}

summarize_with_opencode() {
  [ -n "$SUMMARY_MODEL" ] || { log "AI_MEMORY_SUMMARY_MODEL is not set in $CONFIG"; exit 1; }
  local events summary_session
  # AI_MEMORY_DISABLE keeps the plugin in this private server from saving the summarizer's own session
  events=$(AI_MEMORY_DISABLE=1 "$OPENCODE_BIN" run --standalone --model "$SUMMARY_MODEL" --format json --title "ai-memory summary" \
    -f "$condensed" "${prompt/The stdin is/The attached file is}
- title: short descriptive title, under 70 characters
Reply with only one JSON object with the keys title, tags and body. No code fence, no other text. Do not use any tools" 2>/dev/null) || true
  summary_session=$(jq -r '.sessionID // empty' <<<"$events" 2>/dev/null | head -1 || true)
  [ -z "$summary_session" ] || "$OPENCODE_BIN" session delete "$summary_session" >/dev/null 2>&1 || true
  jq -rs '[.[] | select(.part.type == "text") | .part.text] | join("")' <<<"$events" 2>/dev/null |
    perl -0ne 'print $1 if /(\{.*\})/s' |
    jq -c '{structured_output: (.tags |= (map(ascii_downcase | gsub("[^a-z0-9-]+"; "-")) | .[0:6]))}' 2>/dev/null || echo "$events"
}

case "$SUMMARIZER" in
  claude) out=$(summarize_with_claude) || exit 1 ;;
  opencode) out=$(summarize_with_opencode) || exit 1 ;;
  *) log "unknown AI_MEMORY_SUMMARIZER '$SUMMARIZER', use claude or opencode"; exit 1 ;;
esac

title=$(jq -r '.structured_output.title // empty' <<<"$out" 2>/dev/null || true)
[ -n "$title" ] || { log "summarizer returned no structured output: $(head -c 500 <<<"$out")"; exit 1; }
body=$(jq -r '.structured_output.body' <<<"$out")
tags=$(jq -r --arg t "$session_tag" '[$t] + .structured_output.tags | unique | join(", ")' <<<"$out")

mkdir -p "$VAULT/sessions"
old_notes=$(grep -lx "session_id: $session_id" "$VAULT"/sessions/*.md 2>/dev/null || true)
# A resumed session keeps its original file name so [[sessions/...]] links from later notes stay valid
note=$(head -1 <<<"$old_notes")
if [ -z "$note" ]; then
  slug=$(tr '[:upper:]' '[:lower:]' <<<"$title" | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-60 | sed -E 's/-+$//')
  note="$VAULT/sessions/$(date +%F)-$slug.md"
fi

tmp_note=$(mktemp "$VAULT/sessions/.tmp.XXXXXX")
cat >"$tmp_note" <<EOF
---
date: $(date +%F)
agent: $agent
model: $model
project: $cwd
session_id: $session_id
transcript: $transcript
tags: [$tags]
---
# $title

$body
EOF

mv "$tmp_note" "$note"
tmp_note=
while IFS= read -r old; do
  [ -n "$old" ] && [ "$old" != "$note" ] && rm -f "$old"
done <<<"$old_notes"

log "saved $note"

# ponytail: reindexes the whole qmd index each save, fine while ai-memory is its only collection
if command -v "$QMD_BIN" >/dev/null; then
  { "$QMD_BIN" update && "$QMD_BIN" embed; } >/dev/null 2>&1 || log "qmd reindex failed, run: qmd update && qmd embed"
fi
