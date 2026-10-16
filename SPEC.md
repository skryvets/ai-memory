# ai-memory spec

Decisions agreed in the design interview on 2026-10-16

## Problem

Context from a Claude Code session is lost when it ends. Built-in auto-memory is per project, so it doesn't help. The goal is one shared memory, across all projects and folders, that a human can read and that any agent can search later

## Decisions

| # | Decision | Why |
| - | - | - |
| 1 | One shared memory, not per project | Memory has to cross projects and folders |
| 2 | Stored in `~/obsidian/Personal/ai-memory/`, a dedicated top-level folder | Plain files, no API or auth inside a hook. Kept apart from hand-written notes |
| 3 | Save a summary plus a link to the raw transcript | Summaries are what gets recalled, and the transcript is there for digging |
| 4 | Trigger on SessionEnd, every reason. Skip sessions with fewer than 4 user messages. No PreCompact | The JSONL keeps the full transcript after compaction, so a PreCompact save would just be a duplicate |
| 5 | Summary written by headless `claude -p`, detached from the hook | Hooks have no model, and SessionEnd hooks get a 1.5s budget |
| 6 | Recall on demand with a `recall` skill, no SessionStart injection for now | Asking is fine, and loading everything every session would bloat context. Revisit later |
| 7 | Installed globally in `~/.claude` | It should work wherever Claude starts |
| 8 | Agent-neutral layout: `ai-memory/sessions/` + `ai-memory/README.md`, frontmatter `agent:` field | Other agents can write here later. `knowledge/` comes when notes get promoted into topics |
| 9 | Note sections: Goal, Decisions (`<decision> - <why>`), Findings (research only), Open threads | The why is what makes a recalled decision useful |
| 10 | One note per session, overwritten on resume (matched by `session_id`) | One session always maps to one note |
| 11 | Summarizer never writes secrets | The vault syncs through Obsidian Sync |
| 12 | Summarizer model is the session's own model from the transcript, falling back to `claude-opus-5-5` | Missed decisions defeat the purpose |
| 13 | `recall` is a skill, not a plain command | It also triggers on plain questions like "what did we decide about X" |
| 14 | Code in `~/Code/ai-memory`, private GitHub repo, pushed to `main`. `install.sh` symlinks into `~/.claude` | A plugin's manifest and marketplace are overkill for one user |
| 15 | Summaries always bill the Claude subscription, never the API | Your call. A stale exported key also broke every run |

### Round 2 - topic layout, borrowed from [Golden Thread](https://github.com/shaven/golden-thread)

This reverses decision 10's rejection of topic notes merged over time. Session notes stay as the unchanged source, so a bad merge can be traced and redone

| # | Decision | Why |
| - | - | - |
| 16 | `projects/<slug>/` for things being built, `topics/<slug>/` for learning domains (Go, YouTube, AI), `knowledge/<slug>.md` for facts proven across 2+ of them | General questions and research have to be stored somewhere other than a code folder |
| 17 | The model picks the project or topic from the content, reusing slugs from `index.md`. The working directory is only a hint | Sessions don't map to folders. This one ran in `ai-empty-folder` but was about `ai-memory` |
| 18 | Merge runs automatically at SessionEnd, after the session note, one at a time under a `mkdir` lock | Automatic capture was the original goal. The lock stops two sessions from both writing ADR-6 |
| 19 | `sessions/` is kept unchanged. Topic files link back to it | Raw source for every merged claim |
| 20 | `decisions.md` holds append-only numbered ADRs with `Status`, `Supersedes`, `Superseded by`, `Expires`, `Source`. Only old entries' status lines may change | Decision history becomes traceable |
| 21 | `research.md` gets dated findings with sources appended. `design.md` holds current architecture, rewritten in place, projects only | Same as Golden Thread |
| 22 | Pages go stale on contradiction (`status: stale`, `superseded_by:`) or a passed `Expires:`, never on age | A two-year-old decision is often still true |
| 23 | `ai-memory/` is a local git repo with one commit per merge, under the identity `ai-memory hook`, unsigned | Free undo and an audit trail. Obsidian Sync skips `.git` |
| 24 | `recall` reads `index.md`, then wikilinks, then grep. It follows `Supersedes` chains for "how did we decide X" | Same as Golden Thread |
| 25 | The merge agent is read-only (`Read,Glob,Grep`). It returns whole-file contents as JSON, and the hook writes them only to allowlisted paths | The planned design gave an unattended agent Edit/Write, and Claude Code's auto-mode classifier blocked it as an unsafe agent. Read-only plus a script-side allowlist is safer and easy to test |
| 26 | A resumed session keeps its note's original file name | Renaming would break the `[[sessions/...]]` links in merged pages |

## How it works

1. Claude Code ends a session and runs `~/.claude/hooks/ai-memory-save.sh` with `{session_id, transcript_path, cwd, reason}` on stdin
2. The hook copies stdin to a temp file, starts itself in `run` mode in a new process session (`perl POSIX::setsid`), and returns at once
3. The worker:
   - Counts real user messages, ignoring meta, tool results and `<command>` lines, and exits under 4
   - Condenses the transcript to user and assistant text only
   - Reads the last assistant model
4. It runs `claude -p --safe-mode --tools "" --no-session-persistence --model <model> --output-format json --json-schema <schema>` with the condensed text on stdin:
   - `--safe-mode` turns off hooks, which stops this hook from triggering itself, plus CLAUDE.md, plugins and MCP, while keeping the subscription login
   - Summaries always bill the Claude subscription, never the API. Every credential that [outranks the `/login` session](https://code.claude.com/docs/en/authentication#authentication-precedence) is stripped from the call's environment: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_PROFILE`, `ANTHROPIC_FEDERATION_RULE_ID` and `CLAUDE_CODE_USE_BEDROCK/VERTEX/FOUNDRY`
   - Before summarizing, `claude auth status` runs under that same environment. Anything other than `claude.ai` or `oauth_token` (a `claude setup-token` subscription token), for example an `apiKeyHelper` in settings, makes the worker refuse and log why, so it never falls back to API billing
5. The worker writes `sessions/YYYY-MM-DD-<slug>.md` atomically. A resumed session reuses its existing file name. If the summarizer fails, the existing note is kept
6. It takes the merge lock `~/.claude/ai-memory.lock`:
   - It waits up to 15 minutes
   - It takes over a lock whose owner process is dead
   - On timeout it gives up and keeps the note unmerged
7. The merge agent runs with the vault as its working directory:
   - Command: `claude -p --safe-mode --tools "Read,Glob,Grep" --permission-prompts none --json-schema <changes>`, on the same subscription-only environment and model
   - Prompt: `hooks/merge-prompt.md`
   - Rules: it follows the vault rulebook `vault/README.md`, which `install.sh` installs as `ai-memory/README.md`
   - It returns `{changes: [{path, content, summary}]}`
   - Reads outside the vault are denied, not prompted. This was verified with a real run
8. The hook writes each change only if its path matches `index.md`, `(projects|topics)/<slug>/(README|decisions|research|design).md` or `knowledge/<slug>.md`, and logs every rejected path
9. It commits everything in one git commit: `merge: <title>`, or `session: <title> (merge failed)` when the merge fails
10. Every outcome is logged to `~/.claude/ai-memory.log`

Docs used:
- https://code.claude.com/docs/en/hooks#sessionend
- https://code.claude.com/docs/en/cli-reference
- https://code.claude.com/docs/en/headless#get-structured-output
- https://code.claude.com/docs/en/skills

## Out of scope for now

- SessionStart injection of `index.md`
- Writers for other agents
- Saving before compaction
- Chunked summarizing for transcripts over ~8MB of text (currently only the tail is kept)
