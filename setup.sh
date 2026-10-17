#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
. "$REPO/lib.sh"
CONFIG="${AI_MEMORY_CONFIG:-$HOME/.config/ai-memory/env}"
[ ! -f "$CONFIG" ] || . "$CONFIG"
CLAUDE_BIN="${AI_MEMORY_CLAUDE_BIN:-claude}"
OPENCODE_BIN="${AI_MEMORY_OPENCODE_BIN:-opencode}"
OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
SAVED_AGENTS="${AI_MEMORY_AGENTS:-}"
SAVED_SUMMARIZER="${AI_MEMORY_SUMMARIZER:-}"
SAVED_MODEL="${AI_MEMORY_SUMMARY_MODEL:-}"
MAX_LISTED=25

die() { echo "ai-memory setup: $*" >&2; exit 1; }
say() { printf '%s\n' "$@" >&2; }

ask() {
  local reply
  printf '%s%s: ' "$1" "${2:+ [$2]}" >&2
  IFS= read -r reply || die "no answer, setup cancelled"
  echo "${reply:-${2:-}}"
}

# choose QUESTION DEFAULT OPTION... where DEFAULT is the option Enter picks, or the first one when no option matches
choose() {
  local question="$1" wanted="$2" default=1 reply n=0 option
  shift 2
  say "" "$question"
  for option in "$@"; do
    n=$((n + 1))
    say "  $n) $option"
    [ "$option" != "$wanted" ] || default=$n
  done
  while :; do
    printf 'Choose 1-%s [%s]: ' "$#" "$default" >&2
    IFS= read -r reply || die "no answer, setup cancelled"
    reply="${reply:-$default}"
    if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le $# ]; then break; fi
    say "Type a number from 1 to $#"
  done
  echo "${!reply}"
}

check_prereqs
has jq || { has brew && brew install jq; } || die "install Homebrew first: https://brew.sh"

say "ai-memory setup. Press Enter to take the answer in [brackets]"

say "" "1. Memory folder. Notes are plain Markdown files, so a folder inside your Obsidian vault works well"
dir=$(ask "Folder" "${AI_MEMORY_DIR:-$HOME/obsidian/Personal/ai-memory}")
dir="${dir/#\~/$HOME}"
case "$dir" in /*) ;; *) dir="$PWD/$dir" ;; esac

say "" "2. Agents"
if has "$CLAUDE_BIN" && has_opencode; then
  case "$SAVED_AGENTS" in
    claude) saved="Claude Code only" ;;
    opencode) saved="OpenCode only" ;;
    *) saved=Both ;;
  esac
  case $(choose "Which agents should save and recall memory?" "$saved" "Both" "Claude Code only" "OpenCode only") in
    Both) agents="claude opencode" ;;
    "Claude Code only") agents=claude ;;
    *) agents=opencode ;;
  esac
elif has "$CLAUDE_BIN"; then
  agents=claude
  say "Found Claude Code (OpenCode isn't installed)"
else
  agents=opencode
  say "Found OpenCode (Claude Code isn't installed)"
fi

say "" "3. Summaries. When a session ends, a model reads it and writes the memory note. Use the strongest model you have"
summarizer=opencode
if has "$CLAUDE_BIN" && has "$OPENCODE_BIN"; then
  by_claude="Claude Code, with your Claude subscription"
  by_opencode="OpenCode, with a model you pick (for example through GitHub Copilot or OpenRouter)"
  saved="$by_claude"
  [ "$SAVED_SUMMARIZER" != opencode ] || saved="$by_opencode"
  case $(choose "Who writes the summaries?" "$saved" "$by_claude" "$by_opencode") in
    Claude*) summarizer=claude ;;
  esac
elif has "$CLAUDE_BIN"; then
  summarizer=claude
elif ! has "$OPENCODE_BIN"; then
  die "summaries need the claude or opencode command on PATH, install one of them first"
fi

model=""
if [ "$summarizer" = claude ]; then
  say "Claude Code writes summaries with your Claude subscription. It never uses an API key, so nothing is billed per token"
  if is_subscription "$(claude_auth_method)"; then
    say "Claude Code is logged in with a subscription"
  else
    say "Claude Code isn't logged in with a subscription. Opening the Claude login"
    "${SUBSCRIPTION_ONLY[@]}" "$CLAUDE_BIN" auth login --claudeai || true
    is_subscription "$(claude_auth_method)" || die "still not logged in with a Claude subscription, run: claude auth login --claudeai, then run setup again"
    say "Logged in"
  fi
else
  models=$("$OPENCODE_BIN" models 2>/dev/null || true)
  while :; do
    providers=$(cut -d/ -f1 <<<"$models" | sed '/^$/d' | sort -u | tr '\n' ' ')
    provider=$(choose "Which provider should run the summary model?" "${SAVED_MODEL%%/*}" $providers "Connect another provider (asks for its API key or login)")
    case "$provider" in
      Connect*)
        "$OPENCODE_BIN" auth login || say "Login didn't finish, pick again"
        models=$("$OPENCODE_BIN" models 2>/dev/null || true) ;;
      *) break ;;
    esac
  done

  # A key that only lives in a shell variable can be missing in the background job that writes summaries
  if "$OPENCODE_BIN" auth list --format json 2>/dev/null |
    jq -e --arg p "$provider" '.[] | select(.id == $p) | [.connections[].type] | index("credential") | not' >/dev/null 2>&1; then
    say "" "The $provider key is only in an environment variable. Summaries are written in the background, where that variable may be missing"
    case $(choose "Save the key in OpenCode's own credential store?" "" "Yes, enter it now" "No, keep using the variable") in
      Yes*) "$OPENCODE_BIN" auth login "$provider" || die "saving the $provider key failed, run: opencode auth login $provider" ;;
    esac
  fi

  saved_name=""
  [ "${SAVED_MODEL%%/*}" != "$provider" ] || saved_name="${SAVED_MODEL#*/}"
  say "" "Pick the strongest model you have, for example the newest Claude Opus or GPT"
  while :; do
    search=$(ask "Type part of the model name to search, or Enter to list all" "$saved_name")
    matches=$(awk -v p="$provider/" 'index($0, p) == 1' <<<"$models" | grep -iF -- "$search" | tr '\n' ' ' || true)
    count=$(wc -w <<<"$matches" | tr -d ' ')
    if [ "$count" -eq 0 ]; then
      say "No $provider model matches '$search'"
    elif [ "$count" -gt "$MAX_LISTED" ]; then
      say "$count models match, type more of the name"
    else
      model=$(choose "Which model writes the summaries?" "$SAVED_MODEL" $matches)
      break
    fi
  done
fi

summary_line="Claude Code with your Claude subscription"
[ "$summarizer" = claude ] || summary_line="OpenCode with $model"
say "" "Ready to install:" "  Memory folder: $dir" "  Agents: $agents" "  Summaries: $summary_line"
case $(choose "Install now?" "" "Yes" "No") in
  Yes) ;;
  *) die "cancelled, nothing was changed" ;;
esac

AI_MEMORY_DIR="$dir" AI_MEMORY_AGENTS="$agents" AI_MEMORY_SUMMARIZER="$summarizer" AI_MEMORY_SUMMARY_MODEL="$model" exec "$REPO/install.sh"
