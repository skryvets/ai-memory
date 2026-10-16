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

### Round 3 - OpenCode and search by meaning

OpenCode is where free and local models run. They are less capable, so they most need to find what a stronger model already decided. Grep only matches exact words, and weaker models are worse at guessing the synonyms

| # | Decision | Why |
| - | - | - |
| 23 | OpenCode sessions are saved to the same `sessions/` folder in the same format, with `agent: opencode` | One memory for every agent |
| 24 | An OpenCode session is saved after 10 minutes with no new messages. Coming back later updates the same note | OpenCode has no session-end event, only turn-end events (`session.execution.succeeded/failed/interrupted` in OpenCode 2) |
| 25 | OpenCode sessions are summarized by `claude-opus-5-5` through the Claude subscription. The note keeps the session's own model in `model:` | The memory free models rely on should be written by a strong model |
| 26 | Free-model sessions are saved too. When notes disagree, recall prefers the newer note, then the stronger model | Their work still matters, and `model:` shows who decided |
| 27 | `/save-memory` saves the current session right away in both tools, ignoring the 4-message minimum | Sometimes you want a save without ending the session |
| 28 | Search by meaning with [qmd](https://github.com/tobi/qmd): local embeddings, keyword search and reranking over the notes | Free models need the most help finding notes, so the grep-catalog step was skipped |
| 29 | One always-on qmd HTTP server (launchd `ai-memory.qmd`, `localhost:8181/mcp`), registered as an MCP server in Claude Code and OpenCode | Models stay loaded: about 0.5s per search, versus about 25s to start qmd per search |
| 30 | qmd indexes only `ai-memory/sessions/` | Personal notes stay out of agent searches |
| 31 | qmd's read-only tools (`query`, `get`, `multi_get`) are pre-allowed in Claude Code | Otherwise every recall asks for permission, and headless sessions can't search at all |
| 32 | Recall falls back to grep when qmd is unavailable | Memory still works if the server is down |

Rejected:
- Supermemory - it moves notes out of Obsidian into its own store and needs an API key (hosted) or an LLM provider key (self-hosted)
- Obsidian Smart Connections - only works while Obsidian is open
- A qmd stdio server per client - each new session reloads the models
- `/save-memory` as a skill - OpenCode also loads `~/.claude/skills/`, where `${CLAUDE_SESSION_ID}` isn't filled in. So Claude Code gets `~/.claude/commands/save-memory.md`, and the OpenCode plugin registers its own `/save-memory`, whose handler receives the session ID

### Round 4 - public repo, install on another laptop

| # | Decision | Why |
| - | - | - |
| 33 | The repo is public on GitHub | Install on a work laptop with a clone and one command |
| 34 | `install.sh` installs missing dependencies itself (`jq`, `node`, `sqlite` through Homebrew, `qmd` through npm) and warns if Claude Code isn't on a subscription login | Drop in, install, done. An agent can run it end to end |
| 35 | The vault path is configurable with `AI_MEMORY_DIR` at install time, saved to `~/.config/ai-memory/env` and read by the hook | The other laptop's vault may live elsewhere. Hooks don't inherit shell variables, so the path has to be on disk |
| 36 | The installer adds the "check `/recall` first" rule to `~/.claude/CLAUDE.md` unless it already mentions `/recall` | A new machine gets the full setup, and a CLAUDE.md that already carries the rule (for example from dotfiles) is left alone |
| 37 | macOS only | The search server runs under launchd. Linux would need a systemd unit instead |

### Round 5 - a machine without a Claude subscription

The work laptop runs OpenCode on a GitHub Copilot key and has no Claude subscription

| # | Decision | Why |
| - | - | - |
| 38 | Each machine keeps its own memory, with no sync between them | The user's call |
| 39 | The summarizer is chosen per machine: `claude` or `opencode`, set with `AI_MEMORY_SUMMARIZER` and `AI_MEMORY_SUMMARY_MODEL` | Work has no Claude subscription. Copilot is available through OpenCode |
| | Replaced: decision 15 as a rule for every machine, "summaries always bill the Claude subscription" - it can't work where there's no subscription. It still holds when the summarizer is `claude` | |
| 40 | The OpenCode summarizer runs `opencode run --standalone --model <model> -f <transcript>`, asks for one JSON object, extracts it from the reply and cleans the tags | `opencode run` has no JSON schema option. Attaching a file avoids the argument size limit |
| 41 | Its transcript is cut to the last 400k characters, about 100k tokens | Copilot models have smaller context windows than Claude Code's |
| 42 | The hook sets `AI_MEMORY_DISABLE=1` for that private server, which turns off the plugin, then deletes the summary session | Otherwise the summarizer's own session would be saved and would clutter the session list |
| 43 | Claude Code is optional. Without it, the installer skips its settings, `/save-memory` command and MCP registration, and the rule goes into `~/.claude/CLAUDE.md` (which OpenCode reads) or OpenCode's own `AGENTS.md` | The work laptop may have only OpenCode |

Rejected: an Anthropic or Copilot API call straight from the hook - it would need its own key handling, and `opencode run` already has the user's provider login

### Round 6 - a setup wizard

| # | Decision | Why |
| - | - | - |
| 44 | `./setup.sh` asks for the memory folder, the agents, who writes summaries, the OpenCode provider and model, and the login, then runs `install.sh` with the answers | A person can install without knowing the environment variables. `install.sh` stays the non-interactive path for agents and re-installs |
| 45 | `AI_MEMORY_AGENTS` picks which agents get wired up. The default is every agent that's installed | Someone may have both installed but use memory in only one |
| 46 | API keys stay in each agent's own login: `claude auth login --claudeai` and `opencode auth login`. ai-memory never stores a key | One place to change or revoke a key, and nothing secret in the repo or in `~/.config/ai-memory/env` |
| 47 | When the provider's key only lives in an environment variable, the wizard offers to save it in OpenCode's store | Summaries run in the background, where a variable from a shell profile may be missing |
| 48 | The saved settings use `${VAR-saved}`, so setting a variable to empty clears it | Switching from the OpenCode summarizer to Claude has to clear the old model, or Claude would be asked to run a Copilot model name |

Rejected: asking for an API key in the wizard and storing it in ai-memory's config - a second copy of the secret, in plain text. Rejected: an API key for the Claude summarizer - the user requires the subscription

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
6. The worker runs `qmd update && qmd embed`, so the note is searchable right away
7. Every outcome is logged to `~/.claude/ai-memory.log`

OpenCode:
- The plugin `opencode/plugins/ai-memory.js` uses the OpenCode 2 format (default export `{id, setup}`). When a turn ends it starts `ai-memory-save.sh opencode-idle <id>` detached, since `opencode run` shuts its server down right after the reply. The detached worker sleeps 10 minutes, exports the session with `opencode session export <id>`, and exits if it was updated during the wait. Otherwise it condenses user and assistant text, without reasoning or tool output, and continues from step 3
- `/save-memory` runs `ai-memory-save.sh save <id>` in Claude Code, or `opencode-save <id>` from the plugin's command in OpenCode. Both skip the wait and the minimum message count

Recall:
- `/recall` lives in `~/.claude/skills/`, which both tools load. It calls qmd's `query` tool with `collections: ["ai-memory"]` and falls back to grep
- OpenCode reads `~/.claude/CLAUDE.md` because there's no `~/.config/opencode/AGENTS.md`, so the "check `/recall` first" rule applies there too

Docs used:
- https://code.claude.com/docs/en/hooks#sessionend
- https://code.claude.com/docs/en/cli-reference
- https://code.claude.com/docs/en/headless#get-structured-output
- https://code.claude.com/docs/en/skills (`${CLAUDE_SESSION_ID}`, inline shell)
- https://opencode.ai/v2/docs/build/plugins (OpenCode 2 plugin API: setup, `ctx.event.subscribe`, `ctx.command.transform`, `ctx.session.synthetic`), https://opencode.ai/docs/skills/, https://opencode.ai/docs/rules/, https://opencode.ai/docs/mcp-servers/, https://opencode.ai/docs/commands/
- https://github.com/tobi/qmd

## Out of scope for now

- SessionStart injection of past decisions
- Topic pages or an index, if grep over notes stops scaling
- Writers for agents other than Claude Code and OpenCode
- Saving before compaction
- Chunked summarizing for transcripts over ~8MB of text (currently only the tail is kept)
