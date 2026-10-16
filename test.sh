#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
HOOK="$REPO/hooks/ai-memory-save.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export AI_MEMORY_DIR="$WORK/vault"
export AI_MEMORY_LOG="$WORK/hook.log"
export AI_MEMORY_CLAUDE_BIN="$WORK/fake-claude"
export AI_MEMORY_LOCK="$WORK/merge.lock"
SESSIONS="$AI_MEMORY_DIR/sessions"

cat >"$AI_MEMORY_CLAUDE_BIN" <<'EOF'
#!/usr/bin/env bash
dir="$(dirname "$0")"
if [ "$1 $2" = "auth status" ]; then
  env | grep -E '^(ANTHROPIC_(API_KEY|AUTH_TOKEN|BASE_URL|PROFILE|FEDERATION_RULE_ID)|CLAUDE_CODE_USE_(BEDROCK|VERTEX|FOUNDRY))=' >"$dir/auth-env" || true
  jq -n --arg m "${FAKE_AUTH-claude.ai}" '{loggedIn: true, authMethod: $m}'
  exit 0
fi
if [[ "$*" == *"Read,Glob,Grep"* ]]; then
  printf '%s\n' "$@" >"$dir/merge-args"
  pwd >"$dir/merge-cwd"
  env | grep -E '^(ANTHROPIC_(API_KEY|AUTH_TOKEN|BASE_URL|PROFILE|FEDERATION_RULE_ID)|CLAUDE_CODE_USE_(BEDROCK|VERTEX|FOUNDRY))=' >"$dir/merge-env" || true
  echo "start $$" >>"$dir/merge-trace"
  sleep "${FAKE_MERGE_SLEEP:-0}"
  echo "end $$" >>"$dir/merge-trace"
  [ "${FAKE_MERGE:-ok}" = ok ] || { echo '{"is_error":true,"result":"merge exploded"}'; exit 1; }
  jq -n --arg t "${FAKE_TITLE:-Session Memory Hook}" '{structured_output: {changes: [
    {path: "index.md", content: "# ai-memory index\n- [[projects/demo/README|Demo]]\n", summary: "index"},
    {path: "projects/demo/decisions.md", content: ("## ADR-001: " + $t + "\n"), summary: "adr"},
    {path: "topics/go/research.md", content: "## finding\n", summary: "research"},
    {path: "knowledge/shell-env.md", content: "fact\n", summary: "knowledge"},
    {path: "../escape.md", content: "x", summary: "evil"},
    {path: "/tmp/abs.md", content: "x", summary: "evil"},
    {path: "sessions/evil.md", content: "x", summary: "evil"},
    {path: "README.md", content: "x", summary: "evil"},
    {path: "projects/demo/notes.md", content: "x", summary: "evil"},
    {path: "projects/../demo/README.md", content: "x", summary: "evil"},
    {path: "topics/Go/README.md", content: "x", summary: "evil"}
  ]}}'
  exit 0
fi
printf '%s\n' "$@" >"$dir/claude-args"
env | grep -E '^(ANTHROPIC_(API_KEY|AUTH_TOKEN|BASE_URL|PROFILE|FEDERATION_RULE_ID)|CLAUDE_CODE_USE_(BEDROCK|VERTEX|FOUNDRY))=' >"$dir/summarize-env" || true
cat >"$dir/claude-stdin"
case "${FAKE_MODE:-ok}" in
  fail) echo '{"is_error":true,"result":"Invalid API key"}'; exit 1 ;;
  slow) sleep 2 ;;
esac
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
ANTHROPIC_API_KEY=k ANTHROPIC_AUTH_TOKEN=t ANTHROPIC_BASE_URL=http://proxy ANTHROPIC_PROFILE=p \
  ANTHROPIC_FEDERATION_RULE_ID=r CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_VERTEX=1 CLAUDE_CODE_USE_FOUNDRY=1 \
  run_worker long-1 "$WORK/long.jsonl"
[ ! -s "$WORK/summarize-env" ] || fail "non-subscription credentials leaked to summarizer: $(cat "$WORK/summarize-env")"
[ ! -s "$WORK/auth-env" ] || fail "non-subscription credentials leaked to auth check: $(cat "$WORK/auth-env")"
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

echo "test: merge agent is read-only, runs in the vault, on subscription auth"
grep -qx -- "--safe-mode" "$WORK/merge-args" || fail "merge without --safe-mode"
grep -qx "Read,Glob,Grep" "$WORK/merge-args" || fail "merge tools not read-only"
! grep -qE "Edit|Write|Bash" "$WORK/merge-args" || fail "merge agent got write or shell tools"
grep -qx -- "--permission-prompts" "$WORK/merge-args" || fail "merge may block on permission prompts"
grep -qx "claude-sonnet-5-5" "$WORK/merge-args" || fail "merge not on session model"
grep -q "sessions/$(date +%F)-session-memory-hook.md" "$WORK/merge-args" || fail "merge prompt missing note path"
[ "$(cat "$WORK/merge-cwd")" = "$(cd "$AI_MEMORY_DIR" && pwd)" ] || fail "merge cwd is not the vault"
[ ! -s "$WORK/merge-env" ] || fail "non-subscription credentials leaked to merge: $(cat "$WORK/merge-env")"

echo "test: merge writes allowlisted paths only"
grep -q "ADR-001: Session Memory Hook" "$AI_MEMORY_DIR/projects/demo/decisions.md" || fail "decisions not written"
[ -f "$AI_MEMORY_DIR/index.md" ] || fail "index not written"
[ -f "$AI_MEMORY_DIR/topics/go/research.md" ] || fail "topic not written"
[ -f "$AI_MEMORY_DIR/knowledge/shell-env.md" ] || fail "knowledge not written"
[ ! -e "$WORK/escape.md" ] || fail "path traversal escaped the vault"
[ ! -e /tmp/abs.md ] || fail "absolute path written"
[ ! -e "$SESSIONS/evil.md" ] || fail "merge wrote into sessions/"
[ ! -e "$AI_MEMORY_DIR/README.md" ] || fail "merge overwrote the rulebook"
[ ! -e "$AI_MEMORY_DIR/projects/demo/notes.md" ] || fail "non-allowlisted file name written"
[ "$(grep -c "merge rejected path" "$AI_MEMORY_LOG")" = 7 ] || fail "rejections not logged"

echo "test: every merge is one git commit in the vault"
[ "$(git -C "$AI_MEMORY_DIR" log --format=%s)" = "merge: Session Memory Hook" ] || fail "commit missing: $(git -C "$AI_MEMORY_DIR" log --oneline)"
[ "$(git -C "$AI_MEMORY_DIR" log -1 --format=%an)" = "ai-memory hook" ] || fail "wrong commit author"
[ -z "$(git -C "$AI_MEMORY_DIR" status --porcelain)" ] || fail "uncommitted changes left"
[ ! -e "$AI_MEMORY_LOCK" ] || fail "lock not released"

echo "test: resumed session updates its note in place so links stay valid"
FAKE_TITLE="Renamed After Resume" run_worker long-1 "$WORK/long.jsonl"
[ "$(grep -lx "session_id: long-1" "$SESSIONS"/*.md | wc -l | tr -d ' ')" = 1 ] || fail "duplicate notes for one session"
grep -qx "# Renamed After Resume" "$note" || fail "resumed note not updated in place"

echo "test: other sessions are left alone"
FAKE_TITLE="Another Session" run_worker long-2 "$WORK/long.jsonl"
[ "$(ls "$SESSIONS"/*.md | wc -l | tr -d ' ')" = 2 ] || fail "expected 2 notes"

echo "test: falls back to default model when transcript has none"
grep -v assistant "$WORK/long.jsonl" >"$WORK/nomodel.jsonl"
FAKE_TITLE="No Model" run_worker nomodel-1 "$WORK/nomodel.jsonl"
grep -qx "claude-opus-5-5" "$WORK/claude-args" || fail "fallback model not used"

echo "test: failed merge keeps the session note, commits it and logs why"
FAKE_MERGE=fail FAKE_TITLE="Merge Fails" run_worker mergefail-1 "$WORK/long.jsonl" && fail "worker should fail when merge fails"
[ -f "$SESSIONS/$(date +%F)-merge-fails.md" ] || fail "session note lost on merge failure"
[ "$(git -C "$AI_MEMORY_DIR" log -1 --format=%s)" = "session: Merge Fails (merge failed)" ] || fail "failed merge not committed"
grep -q "\[mergefail-1\] merge failed, session note kept.*merge exploded" "$AI_MEMORY_LOG" || fail "merge failure not logged"
[ ! -e "$AI_MEMORY_LOCK" ] || fail "lock not released after failure"

echo "test: concurrent merges never overlap"
: >"$WORK/merge-trace"
FAKE_MERGE_SLEEP=1 FAKE_TITLE="Parallel A" run_worker par-a "$WORK/long.jsonl" &
FAKE_MERGE_SLEEP=1 FAKE_TITLE="Parallel B" run_worker par-b "$WORK/long.jsonl" &
wait
[ "$(awk '{print $1}' "$WORK/merge-trace" | tr '\n' ' ')" = "start end start end " ] || fail "merges overlapped: $(cat "$WORK/merge-trace")"
[ "$(awk 'NR==1{a=$2} NR==2{b=$2} END{print (a==b)}' "$WORK/merge-trace")" = 1 ] || fail "merge interleaved"

echo "test: a busy lock gives up after the wait and keeps the note"
mkdir "$AI_MEMORY_LOCK" && echo $$ >"$AI_MEMORY_LOCK/pid"
AI_MEMORY_LOCK_WAIT=1 FAKE_TITLE="Lock Busy" run_worker busy-1 "$WORK/long.jsonl" && fail "worker should fail on busy lock"
grep -q "\[busy-1\] merge lock busy" "$AI_MEMORY_LOG" || fail "busy lock not logged"
[ -f "$SESSIONS/$(date +%F)-lock-busy.md" ] || fail "note lost on busy lock"
[ -d "$AI_MEMORY_LOCK" ] || fail "someone else's lock was removed"

echo "test: a lock left by a dead process is taken over"
echo 99999999 >"$AI_MEMORY_LOCK/pid"
FAKE_TITLE="Stale Lock" run_worker stale-1 "$WORK/long.jsonl" || fail "stale lock not recovered"
[ ! -e "$AI_MEMORY_LOCK" ] || fail "lock not released"

echo "test: failed summarizer keeps existing note and logs why"
FAKE_MODE=fail run_worker long-2 "$WORK/long.jsonl" && fail "worker should fail on error output"
[ -f "$SESSIONS/$(date +%F)-another-session.md" ] || fail "existing note lost"
grep -q "\[long-2\] summarizer returned no structured output.*Invalid API key" "$AI_MEMORY_LOG" || fail "failure not logged"

for method in api_key api_key_helper third_party none ""; do
  echo "test: refuses to summarize when auth is '$method'"
  rm -f "$WORK/claude-args" "$WORK/merge-args"
  FAKE_AUTH="$method" run_worker "auth-$method" "$WORK/long.jsonl" && fail "worker should refuse auth '$method'"
  [ ! -f "$WORK/claude-args" ] || fail "summarizer ran with auth '$method'"
  [ ! -f "$WORK/merge-args" ] || fail "merge ran with auth '$method'"
  grep -q "\[auth-$method\] refusing to summarize, auth is" "$AI_MEMORY_LOG" || fail "refusal not logged for '$method'"
done

echo "test: accepts long-lived subscription token"
FAKE_AUTH=oauth_token FAKE_TITLE="Token Session" run_worker token-1 "$WORK/long.jsonl"
[ -f "$SESSIONS/$(date +%F)-token-session.md" ] || fail "oauth_token auth was refused"

echo "test: hook entry detaches and returns fast"
export FAKE_MODE=slow FAKE_TITLE=Detached
start=$(date +%s)
jq -n --arg t "$WORK/long.jsonl" '{session_id: "detach-1", transcript_path: $t, cwd: "/tmp"}' | "$HOOK"
[ $(($(date +%s) - start)) -le 1 ] || fail "hook did not return within the SessionEnd budget"
for _ in $(seq 1 50); do [ -f "$SESSIONS/$(date +%F)-detached.md" ] && break; sleep 0.2; done
[ -f "$SESSIONS/$(date +%F)-detached.md" ] || fail "detached worker never wrote note"

echo "test: install.sh is idempotent and keeps other hooks"
export CLAUDE_DIR="$WORK/claude"
mkdir -p "$CLAUDE_DIR"
echo '{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"other.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"stop.sh"}]}]}}' >"$CLAUDE_DIR/settings.json"
cp "$CLAUDE_DIR/settings.json" "$WORK/original-settings.json"
"$REPO/install.sh" >/dev/null
"$REPO/install.sh" >/dev/null
s="$CLAUDE_DIR/settings.json"
cmp -s "$s.ai-memory.bak" "$WORK/original-settings.json" || fail "re-install overwrote the pre-install backup"
[ "$(jq '[.hooks.SessionEnd[].hooks[] | select(.command | endswith("ai-memory-save.sh"))] | length' "$s")" = 1 ] || fail "hook not registered exactly once"
[ "$(jq '[.hooks.SessionEnd[].hooks[] | select(.command == "other.sh")] | length' "$s")" = 1 ] || fail "other SessionEnd hook lost"
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" = stop.sh ] || fail "Stop hook lost"
[ -L "$CLAUDE_DIR/skills/recall" ] || fail "skill not linked"
[ -f "$AI_MEMORY_DIR/README.md" ] || fail "vault README not copied"
[ -d "$AI_MEMORY_DIR/.git" ] || fail "vault not a git repo"

echo "all tests passed"
