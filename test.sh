#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
HOOK="$REPO/hooks/ai-memory-save.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export AI_MEMORY_DIR="$WORK/vault"
export AI_MEMORY_CONFIG="$WORK/config/env"
export AI_MEMORY_LOG="$WORK/hook.log"
export AI_MEMORY_CLAUDE_BIN="$WORK/fake-claude"
export AI_MEMORY_OPENCODE_BIN="$WORK/fake-opencode"
export AI_MEMORY_QMD_BIN="$WORK/fake-qmd"
export AI_MEMORY_LAUNCHCTL="$WORK/fake-launchctl"
export AI_MEMORY_CLAUDE_PROJECTS="$WORK/projects"
SESSIONS="$AI_MEMORY_DIR/sessions"

cat >"$AI_MEMORY_CLAUDE_BIN" <<'EOF'
#!/usr/bin/env bash
dir="$(dirname "$0")"
if [ "$1" = mcp ]; then
  echo "$*" >>"$dir/mcp-calls"
  case "$2" in
    get) [ -f "$dir/mcp-qmd" ] && echo "  URL: http://localhost:8181/mcp" ;;
    add) touch "$dir/mcp-qmd" ;;
    remove) rm -f "$dir/mcp-qmd" ;;
  esac
  exit
fi
if [ "$1 $2" = "auth status" ]; then
  env | grep -E '^(ANTHROPIC_(API_KEY|AUTH_TOKEN|BASE_URL|PROFILE|FEDERATION_RULE_ID)|CLAUDE_CODE_USE_(BEDROCK|VERTEX|FOUNDRY))=' >"$dir/auth-env" || true
  auth="${FAKE_AUTH-claude.ai}"
  [ ! -f "$dir/logged-in" ] || auth=claude.ai
  jq -n --arg m "$auth" '{loggedIn: true, authMethod: $m}'
  exit 0
fi
[ "$1 $2" != "auth login" ] || { echo "$*" >"$dir/logged-in"; exit 0; }
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

cat >"$AI_MEMORY_OPENCODE_BIN" <<'EOF'
#!/usr/bin/env bash
dir="$(dirname "$0")"
case "$1 $2" in
  "session export") cat "$dir/export-$3.json" ;;
  "session delete") echo "$3" >>"$dir/oc-deleted" ;;
  "models ") echo models >>"$dir/oc-models-calls"; printf '%s\n' github-copilot/claude-opus-5-5 github-copilot/claude-opus-5-5-fast github-copilot/gpt-5 my.llm/alpha myxllm/beta openrouter/deepseek ;;
  "auth list") echo '[{"id": "github-copilot", "connections": [{"type": "env", "name": "GITHUB_TOKEN"}]}]' ;;
  "auth login") echo "$*" >>"$dir/oc-login" ;;
  run*)
    printf '%s\n' "$@" >"$dir/oc-run-args"
    while [ $# -gt 0 ]; do [ "$1" = -f ] && cp "$2" "$dir/oc-attached"; shift; done
    echo "AI_MEMORY_DISABLE=${AI_MEMORY_DISABLE:-}" >"$dir/oc-run-env"
    jq -nc '{type: "step_start", sessionID: "ses_summary", part: {type: "step-start"}}'
    jq -nc --arg t 'Here it is:
```json
{"title": "Copilot Summary", "tags": ["Work Laptop", "opencode", "a", "b", "c", "d", "e"], "body": "## Goal\nSummarize"}
```' '{type: "text", sessionID: "ses_summary", part: {type: "text", text: $t}}' ;;
esac
EOF
printf '#!/usr/bin/env bash\necho "$*" >>"$(dirname "$0")/qmd-calls"\n' >"$AI_MEMORY_QMD_BIN"
printf '#!/usr/bin/env bash\necho "$*" >>"$(dirname "$0")/launchctl-calls"\n' >"$AI_MEMORY_LAUNCHCTL"
chmod +x "$AI_MEMORY_OPENCODE_BIN" "$AI_MEMORY_QMD_BIN" "$AI_MEMORY_LAUNCHCTL"

fail() { echo "FAIL: $*" >&2; cat "$AI_MEMORY_LOG" >&2 2>/dev/null || true; exit 1; }

saved() {
  (unset AI_MEMORY_DIR AI_MEMORY_AGENTS AI_MEMORY_SUMMARIZER AI_MEMORY_SUMMARY_MODEL; . "$AI_MEMORY_CONFIG"; printf '%s' "${!1}")
}

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
  "$HOOK" run claude-code auto "$1" "$2" /tmp/project >>"$AI_MEMORY_LOG" 2>&1
}

make_opencode_export() {
  local id="$1" n="$2" updated_ms="$3"
  jq -n --arg id "$id" --argjson n "$n" --argjson u "$updated_ms" '{
    info: {id: $id, model: {id: "x-ai/grok-4.7"}, time: {updated: $u}, location: {directory: "/tmp/oc-project"}},
    messages: ([range($n)] | map(
      {type: "user", text: "oc question \(.)"},
      {type: "assistant", model: {id: "qwen/qwen3.8-27b"}, content: [
        {type: "reasoning", text: "hidden reasoning"},
        {type: "text", text: "oc answer \(.)"},
        {type: "tool", name: "shell", state: {output: "tool noise"}}]},
      {type: "idle", outcome: "succeeded"}))
  }' >"$WORK/export-$id.json"
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

echo "test: summary prompt asks for replaced and rejected decisions with reasons"
grep -q "Replaced: <the earlier choice> - <what made it wrong" "$WORK/claude-args" || fail "prompt lacks Replaced format"
grep -q "Rejected: <an alternative considered> - <why not>" "$WORK/claude-args" || fail "prompt lacks Rejected format"
grep -q "sessions/<note-name>" "$WORK/claude-args" || fail "prompt lacks link to earlier session"

echo "test: resumed session updates its note in place so links stay valid"
FAKE_TITLE="Renamed After Resume" run_worker long-1 "$WORK/long.jsonl"
[ "$(grep -lx "session_id: long-1" "$SESSIONS"/*.md | wc -l | tr -d ' ')" = 1 ] || fail "duplicate notes for one session"
grep -qx "# Renamed After Resume" "$note" || fail "resumed note not updated in place"

echo "test: other sessions are left alone"
FAKE_TITLE="Another Session" run_worker long-2 "$WORK/long.jsonl"
[ "$(ls "$SESSIONS"/*.md | wc -l | tr -d ' ')" = 2 ] || fail "expected 2 notes"
[ ! -e "$AI_MEMORY_DIR/index.md" ] && [ ! -d "$AI_MEMORY_DIR/.git" ] || fail "hook wrote more than the session note"

echo "test: falls back to default model when transcript has none"
grep -v assistant "$WORK/long.jsonl" >"$WORK/nomodel.jsonl"
FAKE_TITLE="No Model" run_worker nomodel-1 "$WORK/nomodel.jsonl"
grep -qx "claude-opus-5-5" "$WORK/claude-args" || fail "fallback model not used"

echo "test: failed summarizer keeps existing note and logs why"
FAKE_MODE=fail run_worker long-2 "$WORK/long.jsonl" && fail "worker should fail on error output"
[ -f "$SESSIONS/$(date +%F)-another-session.md" ] || fail "existing note lost"
grep -q "\[long-2\] summarizer returned no structured output.*Invalid API key" "$AI_MEMORY_LOG" || fail "failure not logged"

for method in api_key api_key_helper third_party none ""; do
  echo "test: refuses to summarize when auth is '$method'"
  rm -f "$WORK/claude-args"
  FAKE_AUTH="$method" run_worker "auth-$method" "$WORK/long.jsonl" && fail "worker should refuse auth '$method'"
  [ ! -f "$WORK/claude-args" ] || fail "summarizer ran with auth '$method'"
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

echo "test: saving reindexes qmd so new notes are searchable"
grep -qx update "$WORK/qmd-calls" && grep -qx embed "$WORK/qmd-calls" || fail "qmd not reindexed after save"

echo "test: manual /save-memory finds the transcript and saves short sessions"
mkdir -p "$AI_MEMORY_CLAUDE_PROJECTS/-tmp-manual"
make_transcript "$AI_MEMORY_CLAUDE_PROJECTS/-tmp-manual/manual-1.jsonl" 1
jq -nc '{type: "user", cwd: "/tmp/manual", message: {content: "where am i"}}' >>"$AI_MEMORY_CLAUDE_PROJECTS/-tmp-manual/manual-1.jsonl"
FAKE_TITLE="Manual Save" "$HOOK" run claude-code force manual-1 >>"$AI_MEMORY_LOG" 2>&1
note="$SESSIONS/$(date +%F)-manual-save.md"
[ -f "$note" ] || fail "manual save did not write a note"
grep -qx "project: /tmp/manual" "$note" || fail "manual save lost the project"
grep -qx "transcript: $AI_MEMORY_CLAUDE_PROJECTS/-tmp-manual/manual-1.jsonl" "$note" || fail "manual save lost the transcript"
[ "$("$HOOK" save manual-1)" = "Saving this session to ai-memory in the background" ] || fail "save entry did not confirm"

echo "test: OpenCode session is summarized by Opus and keeps its own model"
make_opencode_export oc-1 4 0
FAKE_TITLE="OpenCode Session" "$HOOK" run opencode force oc-1 >>"$AI_MEMORY_LOG" 2>&1
note="$SESSIONS/$(date +%F)-opencode-session.md"
[ -f "$note" ] || fail "opencode note not written"
grep -qx "agent: opencode" "$note" || fail "opencode agent missing"
grep -qx "model: qwen/qwen3.8-27b" "$note" || fail "opencode session model missing"
grep -qx "project: /tmp/oc-project" "$note" || fail "opencode project missing"
grep -qx "transcript: opencode session export oc-1" "$note" || fail "opencode transcript command missing"
grep -qx "tags: \[hooks, obsidian, opencode-session\]" "$note" || fail "opencode tags wrong: $(grep tags "$note")"
grep -qx "claude-opus-5-5" "$WORK/claude-args" || fail "opencode summary not written by Opus"
grep -q "oc question 3" "$WORK/claude-stdin" && grep -q "oc answer 3" "$WORK/claude-stdin" || fail "opencode text missing from stdin"
! grep -qE "hidden reasoning|tool noise" "$WORK/claude-stdin" || fail "opencode noise leaked into stdin"

echo "test: OpenCode idle save waits for quiet and skips busy or short sessions"
export AI_MEMORY_QUIET_SECONDS=1
make_opencode_export oc-busy 4 $(( ($(date +%s) + 60) * 1000 ))
FAKE_TITLE="Busy Session" "$HOOK" run opencode idle oc-busy >>"$AI_MEMORY_LOG" 2>&1
[ ! -f "$SESSIONS/$(date +%F)-busy-session.md" ] || fail "saved a session that is still active"
make_opencode_export oc-short 3 0
FAKE_TITLE="Short OpenCode" "$HOOK" run opencode idle oc-short >>"$AI_MEMORY_LOG" 2>&1
[ ! -f "$SESSIONS/$(date +%F)-short-opencode.md" ] || fail "saved a short opencode session"
make_opencode_export oc-quiet 4 0
FAKE_TITLE="Quiet Session" "$HOOK" run opencode idle oc-quiet >>"$AI_MEMORY_LOG" 2>&1
[ -f "$SESSIONS/$(date +%F)-quiet-session.md" ] || fail "quiet opencode session not saved"
unset AI_MEMORY_QUIET_SECONDS

if ! command -v bun >/dev/null; then
  echo "skip: OpenCode plugin test needs bun"
else
echo "test: OpenCode plugin saves when a turn ends and on /save-memory"
mkdir -p "$WORK/plugin"
sed "s|\${process.env.HOME}/.claude/hooks/ai-memory-save.sh|$WORK/fake-hook|" "$REPO/opencode/plugins/ai-memory.js" >"$WORK/plugin/ai-memory.js"
printf '#!/usr/bin/env bash\necho "$*" >>"$(dirname "$0")/hook-calls"\n' >"$WORK/fake-hook"
chmod +x "$WORK/fake-hook"
export WORK
bun -e '
const plugin = (await import(process.argv[1])).default
const calls = [], notes = []
const events = [
  { type: "session.execution.started", data: { sessionID: "ses_1" } },
  { type: "session.execution.succeeded", data: { sessionID: "ses_1" } },
  { type: "session.execution.interrupted", data: { sessionID: "ses_3" } },
]
let command
const ctx = {
  event: { subscribe: async function* () { yield* events } },
  command: { transform: async (f) => f({ add: (c) => { command = c } }) },
  session: { synthetic: async (m) => notes.push(m) },
}
await plugin.setup(undefined)
process.env.AI_MEMORY_DISABLE = "1"
if (await plugin.setup(ctx)) { console.error("plugin ran with AI_MEMORY_DISABLE"); process.exit(1) }
delete process.env.AI_MEMORY_DISABLE
const dispose = await plugin.setup(ctx)
await new Promise((r) => setTimeout(r, 300))
await command.execute({ sessionID: "ses_2" })
await new Promise((r) => setTimeout(r, 300))
const got = JSON.stringify({ id: plugin.id, name: command.name, calls: (await Bun.file(process.env.WORK + "/hook-calls").text()).trim().split("\n").sort(), notes })
const want = JSON.stringify({ id: "ai-memory", name: "save-memory", calls: ["opencode-idle ses_1", "opencode-idle ses_3", "opencode-save ses_2"], notes: [{ sessionID: "ses_2", text: "Saving this session to ai-memory in the background" }] })
if (got !== want || typeof dispose !== "function") { console.error(got); process.exit(1) }
' "$WORK/plugin/ai-memory.js" || fail "plugin does not call the hook as expected"
fi

echo "test: OpenCode can write the summary instead of Claude, for machines without a Claude subscription"
rm -f "$WORK/claude-args"
FAKE_AUTH=api_key AI_MEMORY_SUMMARIZER=opencode AI_MEMORY_SUMMARY_MODEL=github-copilot/strong-model \
  "$HOOK" run claude-code auto copilot-1 "$WORK/long.jsonl" /tmp/work >>"$AI_MEMORY_LOG" 2>&1
note="$SESSIONS/$(date +%F)-copilot-summary.md"
[ -f "$note" ] || fail "opencode summarizer did not write a note"
[ ! -f "$WORK/claude-args" ] || fail "claude ran although opencode is the summarizer"
grep -qx "## Goal" "$note" || fail "opencode summary body missing"
grep -qx "tags: \[a, b, c, claude-session, d, opencode, work-laptop\]" "$note" || fail "opencode tags not cleaned: $(grep tags "$note")"
grep -qx -- "--standalone" "$WORK/oc-run-args" && grep -qx "github-copilot/strong-model" "$WORK/oc-run-args" || fail "opencode run flags wrong"
grep -q "question 4" "$WORK/oc-attached" || fail "transcript not attached"
grep -qx "AI_MEMORY_DISABLE=1" "$WORK/oc-run-env" || fail "plugin not disabled for the summarizer session"
grep -qx "ses_summary" "$WORK/oc-deleted" || fail "summarizer session not deleted"

echo "test: OpenCode summarizer needs a model"
AI_MEMORY_SUMMARIZER=opencode "$HOOK" run claude-code auto nomodel-oc "$WORK/long.jsonl" /tmp >>"$AI_MEMORY_LOG" 2>&1 && fail "should fail without a model"
grep -q "\[nomodel-oc\] AI_MEMORY_SUMMARY_MODEL is not set" "$AI_MEMORY_LOG" || fail "missing model not logged"

echo "test: install.sh is idempotent and keeps other hooks"
export CLAUDE_DIR="$WORK/claude" OPENCODE_DIR="$WORK/opencode" LAUNCH_AGENTS="$WORK/agents"
mkdir -p "$CLAUDE_DIR" "$OPENCODE_DIR"
echo '{"model": "local/x", "mcp": {"other": {"type": "local"}}}' >"$OPENCODE_DIR/opencode.jsonc"
echo '{"permissions":{"allow":["Bash(ls *)"]},"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"other.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"stop.sh"}]}]}}' >"$CLAUDE_DIR/settings.json"
cp "$CLAUDE_DIR/settings.json" "$WORK/original-settings.json"
"$REPO/install.sh" >/dev/null
"$REPO/install.sh" >/dev/null
s="$CLAUDE_DIR/settings.json"
cmp -s "$s.ai-memory.bak" "$WORK/original-settings.json" || fail "re-install overwrote the pre-install backup"
[ "$(jq '[.hooks.SessionEnd[].hooks[] | select(.command | endswith("ai-memory-save.sh"))] | length' "$s")" = 1 ] || fail "hook not registered exactly once"
[ "$(jq '[.hooks.SessionEnd[].hooks[] | select(.command == "other.sh")] | length' "$s")" = 1 ] || fail "other SessionEnd hook lost"
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" = stop.sh ] || fail "Stop hook lost"
[ "$(jq -c '[.permissions.allow[] | select(startswith("mcp__qmd__"))]' "$s")" = '["mcp__qmd__get","mcp__qmd__multi_get","mcp__qmd__query"]' ] || fail "read-only qmd tools not allowed exactly once"
jq -e '.permissions.allow | index("Bash(ls *)")' "$s" >/dev/null || fail "existing permissions lost"
[ -L "$CLAUDE_DIR/skills/recall" ] || fail "skill not linked"
[ -f "$AI_MEMORY_DIR/README.md" ] || fail "vault README not copied"
[ -L "$CLAUDE_DIR/commands/save-memory.md" ] || fail "claude save-memory command not linked"
[ "$(grep -c '/recall' "$CLAUDE_DIR/CLAUDE.md")" = 1 ] || fail "recall rule not added to CLAUDE.md exactly once"
[ "$(saved AI_MEMORY_DIR)" = "$AI_MEMORY_DIR" ] || fail "vault path not saved to config: $(cat "$AI_MEMORY_CONFIG")"
[ -z "$(saved AI_MEMORY_AGENTS)" ] || fail "detected agents saved as a choice, agents installed later would be ignored"

echo "test: hook reads the vault path from the config"
mkdir -p "$WORK/other-vault"
printf 'AI_MEMORY_DIR="${AI_MEMORY_DIR:-%s}"\n' "$WORK/other-vault" >"$WORK/other-config"
(unset AI_MEMORY_DIR; AI_MEMORY_CONFIG="$WORK/other-config" FAKE_TITLE="Configured Vault" "$HOOK" run claude-code auto cfg-1 "$WORK/long.jsonl" /tmp >>"$AI_MEMORY_LOG" 2>&1)
[ -f "$WORK/other-vault/sessions/$(date +%F)-configured-vault.md" ] || fail "hook ignored the configured vault"
[ -L "$OPENCODE_DIR/plugins/ai-memory.js" ] || fail "opencode plugin not linked"
oc="$OPENCODE_DIR/opencode.jsonc"
[ "$(jq -r '.mcp.qmd.url' "$oc")" = http://localhost:8181/mcp ] || fail "qmd not registered in opencode"
[ "$(jq -r '.mcp.other.type + " " + .model' "$oc")" = "local local/x" ] || fail "opencode config lost existing settings"
[ "$(grep -c "mcp add --scope user --transport http qmd http://localhost:8181/mcp" "$WORK/mcp-calls")" = 1 ] || fail "qmd not registered once in claude code"
grep -q "collection add $AI_MEMORY_DIR/sessions --name ai-memory" "$WORK/qmd-calls" || fail "qmd collection not created"
grep -q "<string>mcp</string><string>--http</string>" "$LAUNCH_AGENTS/ai-memory.qmd.plist" || fail "qmd launch agent not written"
grep -q "^bootstrap gui/" "$WORK/launchctl-calls" || fail "qmd launch agent not started"

echo "test: dropping Claude Code unwires it, OpenCode is found by its folder without a binary on PATH"
rm -f "$OPENCODE_DIR/plugins/ai-memory.js"
AI_MEMORY_AGENTS=opencode AI_MEMORY_OPENCODE_BIN=no-such-opencode "$REPO/install.sh" >/dev/null
[ "$(jq '[.hooks.SessionEnd[].hooks[] | select(.command | endswith("ai-memory-save.sh"))] | length' "$s")" = 0 ] || fail "claude hook left behind"
[ "$(jq '[.hooks.SessionEnd[].hooks[] | select(.command == "other.sh")] | length' "$s")" = 1 ] || fail "unwiring removed another hook"
[ ! -e "$CLAUDE_DIR/commands/save-memory.md" ] || fail "claude save-memory command left behind"
grep -qx "mcp remove qmd --scope user" "$WORK/mcp-calls" || fail "qmd not removed from claude code"
[ -L "$OPENCODE_DIR/plugins/ai-memory.js" ] || fail "opencode with only a config folder was not set up"
[ "$(saved AI_MEMORY_AGENTS)" = opencode ] || fail "explicit agent choice not saved"
grep -q '/recall' "$CLAUDE_DIR/CLAUDE.md" || fail "recall rule removed from CLAUDE.md though OpenCode still reads it"

echo "test: unknown agent names stop the install"
AI_MEMORY_AGENTS=claude,opencode "$REPO/install.sh" >/dev/null 2>"$WORK/install-err" && fail "install accepted claude,opencode"
grep -q "AI_MEMORY_AGENTS must be claude, opencode" "$WORK/install-err" || fail "bad agent name not explained"

echo "test: install works on a machine with OpenCode and no Claude Code"
export CLAUDE_DIR="$WORK/claude2" AI_MEMORY_CONFIG="$WORK/config2/env"
rm -f "$WORK/mcp-calls"
AI_MEMORY_CLAUDE_BIN=no-such-claude "$REPO/install.sh" >/dev/null 2>"$WORK/install-err" && fail "install without a summary model should stop"
grep -q "set AI_MEMORY_SUMMARY_MODEL" "$WORK/install-err" || fail "install did not explain the missing model"
AI_MEMORY_CLAUDE_BIN=no-such-claude AI_MEMORY_SUMMARY_MODEL=github-copilot/strong-model "$REPO/install.sh" >/dev/null
[ "$(saved AI_MEMORY_SUMMARIZER)" = opencode ] || fail "summarizer not saved: $(cat "$AI_MEMORY_CONFIG")"
[ "$(saved AI_MEMORY_SUMMARY_MODEL)" = github-copilot/strong-model ] || fail "summary model not saved"
[ ! -e "$CLAUDE_DIR/settings.json" ] && [ ! -e "$WORK/mcp-calls" ] || fail "touched Claude Code settings without Claude Code"
[ -L "$CLAUDE_DIR/skills/recall" ] && [ -L "$OPENCODE_DIR/plugins/ai-memory.js" ] || fail "recall skill or opencode plugin missing"
grep -q '/recall' "$CLAUDE_DIR/CLAUDE.md" || fail "recall rule missing for OpenCode"

echo "test: an agent installed later is set up on the next run"
"$REPO/install.sh" >/dev/null
[ -f "$CLAUDE_DIR/settings.json" ] || fail "Claude Code installed later was not set up"

echo "test: a saved agent that was uninstalled is skipped, not fatal"
AI_MEMORY_AGENTS="claude opencode" AI_MEMORY_CLAUDE_BIN=no-such-claude "$REPO/install.sh" >/dev/null 2>"$WORK/install-err" || fail "install died on an uninstalled saved agent"
grep -q "skipping claude" "$WORK/install-err" || fail "skipped agent not reported"

echo "test: setup wizard installs OpenCode summaries and saves an env-only key"
export CLAUDE_DIR="$WORK/claude3" OPENCODE_DIR="$WORK/opencode3" AI_MEMORY_CONFIG="$WORK/config3/env"
wiz_vault="$WORK/wiz \"vault\" \$HOME}\`id\`"
rm -f "$WORK/oc-models-calls"
printf '%s\n' "$wiz_vault" 1 2 1 1 opus 1 1 | "$REPO/setup.sh" >/dev/null 2>"$WORK/setup-err" || { cat "$WORK/setup-err" >&2; fail "setup wizard failed"; }
[ "$(saved AI_MEMORY_DIR)" = "$wiz_vault" ] || fail "wizard folder with special characters not saved as typed: $(cat "$AI_MEMORY_CONFIG")"
[ "$(saved AI_MEMORY_AGENTS)" = "claude opencode" ] || fail "wizard agents not saved"
[ "$(saved AI_MEMORY_SUMMARY_MODEL)" = github-copilot/claude-opus-5-5 ] || fail "wizard model not saved"
grep -qx "auth login github-copilot" "$WORK/oc-login" || fail "wizard did not offer to store the env-only key"
[ -L "$OPENCODE_DIR/plugins/ai-memory.js" ] && [ -f "$CLAUDE_DIR/settings.json" ] || fail "wizard did not set up both agents"
[ "$(wc -l <"$WORK/oc-models-calls" | tr -d ' ')" = 1 ] || fail "wizard listed OpenCode models more than once"

echo "test: pressing Enter through the wizard keeps every saved answer"
cp "$AI_MEMORY_CONFIG" "$WORK/config-before"
(unset AI_MEMORY_DIR; printf '\n%.0s' 1 2 3 4 5 6 7 8 | "$REPO/setup.sh" >/dev/null 2>"$WORK/setup-err") || { cat "$WORK/setup-err" >&2; fail "Enter-only wizard failed"; }
cmp -s "$AI_MEMORY_CONFIG" "$WORK/config-before" || fail "Enter changed saved answers: $(diff "$WORK/config-before" "$AI_MEMORY_CONFIG")"

echo "test: wizard lists only the chosen provider's models, even with a dot in its name"
(unset AI_MEMORY_DIR; printf '%s\n' "" 1 2 2 "" 1 2 | "$REPO/setup.sh" >/dev/null 2>"$WORK/setup-err") && fail "cancelled wizard should exit non-zero"
grep -q "1) my.llm/alpha" "$WORK/setup-err" || fail "my.llm model not listed: $(cat "$WORK/setup-err")"
! grep -q "myxllm/beta" "$WORK/setup-err" || fail "my.llm matched another provider's model"

echo "test: setup wizard logs in to Claude, clears the old model and unwires OpenCode"
: >"$OPENCODE_DIR/AGENTS.md"
(unset AI_MEMORY_DIR; printf '%s\n' "" 2 1 1 | FAKE_AUTH=apiKey "$REPO/setup.sh" >/dev/null 2>"$WORK/setup-err") || { cat "$WORK/setup-err" >&2; fail "claude wizard failed"; }
grep -q "auth login --claudeai" "$WORK/logged-in" || fail "wizard did not open the Claude subscription login"
[ "$(saved AI_MEMORY_DIR)" = "$wiz_vault" ] || fail "Enter did not keep the saved folder"
[ "$(saved AI_MEMORY_SUMMARIZER)" = claude ] || fail "claude summarizer not saved"
[ -z "$(saved AI_MEMORY_SUMMARY_MODEL)" ] || fail "old OpenCode model not cleared"
[ ! -e "$OPENCODE_DIR/plugins/ai-memory.js" ] || fail "OpenCode plugin left behind when only Claude Code was chosen"
[ "$(jq -r '.mcp.qmd // "gone"' "$OPENCODE_DIR/opencode.json")" = gone ] || fail "qmd left in the OpenCode config"
! grep -q '/recall' "$OPENCODE_DIR/AGENTS.md" || fail "recall rule added for OpenCode when only Claude Code was chosen"

echo "test: unwiring OpenCode removes only the recall rule from its AGENTS.md"
printf '# My rules\n- keep this\n' >"$OPENCODE_DIR/AGENTS.md"
cp "$OPENCODE_DIR/AGENTS.md" "$WORK/agents-before"
AI_MEMORY_AGENTS="claude opencode" "$REPO/install.sh" >/dev/null
[ "$(grep -c '/recall' "$OPENCODE_DIR/AGENTS.md")" = 1 ] || fail "recall rule not added to OpenCode AGENTS.md"
AI_MEMORY_AGENTS=claude "$REPO/install.sh" >/dev/null
cmp -s "$OPENCODE_DIR/AGENTS.md" "$WORK/agents-before" || fail "OpenCode AGENTS.md not restored: $(cat "$OPENCODE_DIR/AGENTS.md")"
grep -q '/recall' "$CLAUDE_DIR/CLAUDE.md" || fail "recall rule removed from CLAUDE.md though Claude Code still uses it"

echo "test: unwiring Claude Code removes the recall rule OpenCode no longer reads from CLAUDE.md"
printf '# Mine\n' >"$WORK/claude-md-before"
rule=$(grep '/recall' "$CLAUDE_DIR/CLAUDE.md")
printf '%s\n\n%s\n' "$(cat "$WORK/claude-md-before")" "$rule" >"$CLAUDE_DIR/CLAUDE.md"
AI_MEMORY_AGENTS=opencode "$REPO/install.sh" >/dev/null
cmp -s "$CLAUDE_DIR/CLAUDE.md" "$WORK/claude-md-before" || fail "CLAUDE.md not restored: $(cat "$CLAUDE_DIR/CLAUDE.md")"

echo "test: setup wizard changes nothing when cancelled"
cp "$AI_MEMORY_CONFIG" "$WORK/config-before"
printf '%s\n' "" 2 1 2 | "$REPO/setup.sh" >/dev/null 2>&1 && fail "cancelled wizard should exit non-zero"
cmp -s "$AI_MEMORY_CONFIG" "$WORK/config-before" || fail "cancelled wizard changed the config"

echo "all tests passed"
