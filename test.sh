#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
HOOK="$REPO/hooks/ai-memory-save.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export AI_MEMORY_DIR="$WORK/vault"
export AI_MEMORY_LOG="$WORK/hook.log"
export AI_MEMORY_CLAUDE_BIN="$WORK/fake-claude"
SESSIONS="$AI_MEMORY_DIR/sessions"

cat >"$AI_MEMORY_CLAUDE_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$(dirname "$0")/claude-args"
echo "${ANTHROPIC_API_KEY-unset}" >"$(dirname "$0")/claude-api-key"
cat >"$(dirname "$0")/claude-stdin"
jq -n --arg t "${FAKE_TITLE:-Session Memory Hook}" \
  '{structured_output: {title: $t, tags: ["hooks", "obsidian"], body: "## Goal\nBuild it\n## Decisions\n- Use Obsidian - plain files"}}'
EOF
chmod +x "$AI_MEMORY_CLAUDE_BIN"

fail() { echo "FAIL: $*" >&2; cat "$AI_MEMORY_LOG" >&2 2>/dev/null || true; exit 1; }

make_transcript() {
  local path="$1" n="$2"
  : >"$path"
  for i in $(seq 1 "$n"); do
    jq -nc --arg c "question $i" '{type: "user", message: {role: "user", content: $c}}' >>"$path"
    jq -nc --arg t "answer $i" '{type: "assistant", message: {model: "claude-sonnet-5-5", content: [{type: "text", text: $t}, {type: "tool_use", name: "Bash"}]}}' >>"$path"
  done
  jq -nc '{type: "user", isMeta: true, message: {content: "meta noise"}}' >>"$path"
  jq -nc '{type: "user", message: {content: "<command-name>/clear</command-name>"}}' >>"$path"
  jq -nc '{type: "user", message: {content: [{type: "tool_result", content: "tool noise"}]}}' >>"$path"
}

run_worker() {
  local input
  input=$(mktemp "$WORK/input.XXXXXX")
  jq -n --arg s "$1" --arg t "$2" '{session_id: $s, transcript_path: $t, cwd: "/tmp/project", hook_event_name: "SessionEnd", reason: "other"}' >"$input"
  "$HOOK" run "$input" >>"$AI_MEMORY_LOG" 2>&1
}

echo "test: short sessions are skipped"
make_transcript "$WORK/short.jsonl" 3
run_worker short-1 "$WORK/short.jsonl"
[ ! -d "$SESSIONS" ] || [ -z "$(ls -A "$SESSIONS")" ] || fail "short session wrote a note"
grep -q "skipped, 3 user messages" "$AI_MEMORY_LOG" || fail "skip not logged"

echo "test: writes a note with frontmatter and body"
make_transcript "$WORK/long.jsonl" 4
ANTHROPIC_API_KEY=stale-key run_worker long-1 "$WORK/long.jsonl"
[ "$(cat "$WORK/claude-api-key")" = unset ] || fail "ANTHROPIC_API_KEY leaked to summarizer"
note="$SESSIONS/$(date +%F)-session-memory-hook.md"
[ -f "$note" ] || fail "note not written at $note"
grep -qx "session_id: long-1" "$note" || fail "session_id missing"
grep -qx "agent: claude-code" "$note" || fail "agent missing"
grep -qx "model: claude-sonnet-5-5" "$note" || fail "session model not used"
grep -qx "project: /tmp/project" "$note" || fail "project missing"
grep -qx "tags: \[claude-session, hooks, obsidian\]" "$note" || fail "tags wrong: $(grep tags "$note")"
grep -qx "# Session Memory Hook" "$note" || fail "title missing"
grep -qx "## Decisions" "$note" || fail "body missing"

echo "test: summarizer gets condensed transcript and safe flags"
grep -qx -- "--safe-mode" "$WORK/claude-args" || fail "--safe-mode not passed"
grep -qx -- "--no-session-persistence" "$WORK/claude-args" || fail "--no-session-persistence not passed"
grep -qx "claude-sonnet-5-5" "$WORK/claude-args" || fail "model not passed"
grep -q "question 4" "$WORK/claude-stdin" || fail "user text missing from stdin"
grep -q "answer 4" "$WORK/claude-stdin" || fail "assistant text missing from stdin"
! grep -qE "meta noise|tool noise|command-name" "$WORK/claude-stdin" || fail "noise leaked into stdin"

echo "test: resumed session overwrites its note"
FAKE_TITLE="Renamed After Resume" run_worker long-1 "$WORK/long.jsonl"
[ "$(grep -lx "session_id: long-1" "$SESSIONS"/*.md | wc -l | tr -d ' ')" = 1 ] || fail "duplicate notes for one session"
[ -f "$SESSIONS/$(date +%F)-renamed-after-resume.md" ] || fail "renamed note missing"

echo "test: other sessions are left alone"
FAKE_TITLE="Another Session" run_worker long-2 "$WORK/long.jsonl"
[ "$(ls "$SESSIONS"/*.md | wc -l | tr -d ' ')" = 2 ] || fail "expected 2 notes"

echo "test: falls back to default model when transcript has none"
grep -v assistant "$WORK/long.jsonl" >"$WORK/nomodel.jsonl"
FAKE_TITLE="No Model" run_worker nomodel-1 "$WORK/nomodel.jsonl"
grep -qx "claude-opus-5-5" "$WORK/claude-args" || fail "fallback model not used"

echo "test: failed summarizer keeps existing note and logs why"
printf '#!/usr/bin/env bash\necho "{\\"is_error\\":true,\\"result\\":\\"Invalid API key\\"}"\nexit 1\n' >"$AI_MEMORY_CLAUDE_BIN"
run_worker long-2 "$WORK/long.jsonl" && fail "worker should fail on error output"
[ -f "$SESSIONS/$(date +%F)-another-session.md" ] || fail "existing note lost"
grep -q "\[long-2\] summarizer returned no structured output.*Invalid API key" "$AI_MEMORY_LOG" || fail "failure not logged"

echo "test: hook entry detaches and returns fast"
printf '#!/usr/bin/env bash\nsleep 2\njq -n %s\n' "'{structured_output: {title: \"Detached\", tags: [], body: \"x\"}}'" >"$AI_MEMORY_CLAUDE_BIN"
start=$(date +%s)
jq -n --arg t "$WORK/long.jsonl" '{session_id: "detach-1", transcript_path: $t, cwd: "/tmp"}' | "$HOOK"
[ $(($(date +%s) - start)) -le 1 ] || fail "hook did not return within the SessionEnd budget"
for _ in $(seq 1 50); do [ -f "$SESSIONS/$(date +%F)-detached.md" ] && break; sleep 0.2; done
[ -f "$SESSIONS/$(date +%F)-detached.md" ] || fail "detached worker never wrote note"

echo "test: install.sh is idempotent and keeps other hooks"
export CLAUDE_DIR="$WORK/claude"
mkdir -p "$CLAUDE_DIR"
echo '{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"other.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"stop.sh"}]}]}}' >"$CLAUDE_DIR/settings.json"
"$REPO/install.sh" >/dev/null
"$REPO/install.sh" >/dev/null
s="$CLAUDE_DIR/settings.json"
[ "$(jq '[.hooks.SessionEnd[].hooks[] | select(.command | endswith("ai-memory-save.sh"))] | length' "$s")" = 1 ] || fail "hook not registered exactly once"
[ "$(jq '[.hooks.SessionEnd[].hooks[] | select(.command == "other.sh")] | length' "$s")" = 1 ] || fail "other SessionEnd hook lost"
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" = stop.sh ] || fail "Stop hook lost"
[ -L "$CLAUDE_DIR/skills/recall" ] || fail "skill not linked"
[ -f "$AI_MEMORY_DIR/README.md" ] || fail "vault README not copied"

echo "all tests passed"
