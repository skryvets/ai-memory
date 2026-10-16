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
| 8 | Agent-neutral layout: `ai-memory/sessions/` + `ai-memory/README.md`, frontmatter `agent:` field | Other agents can write here later |
| 9 | Note sections: Goal, Decisions (`<decision> - <why>`), Findings (research only), Open threads | The why is what makes a recalled decision useful |
| 10 | One note per session, overwritten on resume (matched by `session_id`) | One session always maps to one note |
| 11 | Summarizer never writes secrets | The vault syncs through Obsidian Sync |
| 12 | Summarizer model is the session's own model from the transcript, falling back to `claude-opus-5-5` | Missed decisions defeat the purpose |
| 13 | `recall` is a skill, not a plain command | It also triggers on plain questions like "what did we decide about X" |
| 14 | Code in `~/Code/ai-memory`, private GitHub repo, pushed to `main`. `install.sh` symlinks into `~/.claude` | A plugin's manifest and marketplace are overkill for one user |
| 15 | Summaries always bill the Claude subscription, never the API | Your call. A stale exported key also broke every run |

### Round 2 - decision history, and a simpler version of it

The main need: six months later, it's tempting to make the "obvious" choice again and rediscover an edge case that was already found and forgotten. So the history of why a decision changed has to be kept

We first borrowed [Golden Thread](https://github.com/shaven/golden-thread)'s layout:
- Per-project and per-topic pages (`decisions.md` with numbered ADRs and supersede chains, `research.md`, `design.md`, `index.md`)
- A second, read-only AI step that merged each summary into those pages, under a lock with a git commit per merge

That was built (commit `3aca140`) and then removed. It added a second AI call, a lock, git, a path allowlist and a new way to be wrong: the merge copied a stale fact into the pages. All of that complexity served one need, and the summary step can meet it alone

| # | Decision | Why |
| - | - | - |
| 16 | Decision history lives in the session summary. Each decision can have `Replaced: <earlier choice> - <what made it wrong>` and `Rejected: <alternative> - <why not>` lines | The edge case that ruled a choice out is almost always found inside one session, and the summarizer reads the whole session. One AI step, no extra pages |
| 17 | A replaced decision from an earlier session gets that session's date and `[[sessions/<note>]]` link, when the transcript names it | Links history across sessions whenever the old decision came up |
| 18 | `recall` lists decisions on a topic oldest to newest, with their Replaced and Rejected lines. The newest is current. It warns when the user is about to choose something already dropped | Notes that never got linked still form a timeline |
| 19 | The global `CLAUDE.md` says to check `/recall` before recommending a design or tool choice | Storage doesn't prevent re-deciding. Checking at the moment of choice does, and it puts the old decision in the transcript, so decision 17 can link it |
| 20 | Summary tags name the topics a session covered (project, tool, technology, domain) | So notes on the same topic are easy to find, without topic pages |
| 21 | A resumed session keeps its note's original file name | Renaming would break `[[sessions/...]]` links from later notes |
| 22 | No merge agent, topic pages, index, lock or vault git | Removed, see above. Golden Thread's approach can return if grep over notes stops scaling, at several hundred notes or more |

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
6. Every outcome is logged to `~/.claude/ai-memory.log`

Docs used:
- https://code.claude.com/docs/en/hooks#sessionend
- https://code.claude.com/docs/en/cli-reference
- https://code.claude.com/docs/en/headless#get-structured-output
- https://code.claude.com/docs/en/skills

## Out of scope for now

- SessionStart injection of past decisions
- Topic pages or an index, if grep over notes stops scaling
- Writers for other agents
- Saving before compaction
- Chunked summarizing for transcripts over ~8MB of text (currently only the tail is kept)
