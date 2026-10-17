# ai-memory

Cross-project memory for Claude Code and OpenCode. When a session ends, or an OpenCode session goes quiet for 10 minutes, a strong model summarizes it into a Markdown note in an Obsidian folder (default `~/obsidian/Personal/ai-memory/sessions/`). The summarizer is Claude Opus through your Claude subscription, or, on a machine without one, any model you use in OpenCode, for example through GitHub Copilot. The summary covers the goal, the decisions and why, what each decision replaced or rejected and why, findings, and open threads

In any later session, in either tool, `/recall <topic>`, or just asking "what did we decide about X", searches those notes by meaning and lists the decision history oldest to newest. `/save-memory` saves the current session right away

See [SPEC.md](SPEC.md) for the design and every decision behind it

## How memory is stored and searched

Each save does two steps:

1. **Write the note.** The summarizer model reads the session and writes `sessions/YYYY-MM-DD-<slug>.md` into the vault. The Markdown file is the memory, and it's what you read in Obsidian
2. **Update the search index.** The same background job runs `qmd update && qmd embed`. [qmd](https://github.com/tobi/qmd) splits the new note into chunks and computes an embedding for each one on your machine, with no API calls

The embeddings don't live in Obsidian. qmd keeps them in its own index at `~/.cache/qmd/index.sqlite`, so the vault stays plain Markdown. If the index is lost or broken, `qmd update && qmd embed` rebuilds it from the notes

When you search, the always-on qmd server (`localhost:8181`) compares the question against that index and returns the best matching notes, which the agent then reads. Searches take about 0.5s, or about 3s after a few idle minutes while the models reload

The index refreshes only when a session is saved. A note you edit or delete by hand in Obsidian shows up in search after the next save, or right away if you run `qmd update && qmd embed`

Memory is per machine by design: each laptop keeps its own notes and its own index

## Install

Requirements:
- macOS, because the search server runs under launchd
- [Homebrew](https://brew.sh)
- At least one of:
  - [Claude Code](https://code.claude.com/docs/en/setup), logged in with a Claude subscription (`claude /login`). With the Claude summarizer, summaries never use an API key, and the hook refuses to run on API key, Bedrock, Vertex or Foundry auth
  - [OpenCode](https://opencode.ai) 2 with a provider that has a strong model, for example GitHub Copilot

```sh
git clone https://github.com/skryvets/ai-memory.git ~/Code/ai-memory
cd ~/Code/ai-memory
./setup.sh
```

`setup.sh` asks a few questions, shows your answers, and installs only after you confirm. On a re-run, Enter keeps each saved answer:
1. **Memory folder** - where the notes go
2. **Agents** - Claude Code, OpenCode or both, from what's installed
3. **Who writes summaries** - Claude Code with your Claude subscription, or OpenCode with a model you pick
4. **Login** - for Claude, it checks you're logged in with a subscription and opens `claude auth login` if not. For OpenCode, you pick a provider you're already connected to, or connect a new one through `opencode auth login`, which asks for the API key or opens the provider's login (GitHub Copilot uses a browser login). If the key only lives in an environment variable, it offers to save it in OpenCode's store, because summaries run in the background where that variable may be missing
5. **Model** - for OpenCode, type part of a name (`opus`, `gpt`, `deepseek`) and pick from the matches

ai-memory never stores an API key. Keys stay in Claude Code's and OpenCode's own logins

To skip the questions, run `./install.sh` with settings as environment variables. They're saved to `~/.config/ai-memory/env`, and later re-installs reuse them:
- `AI_MEMORY_DIR` - the vault's `ai-memory` folder. Default `~/obsidian/Personal/ai-memory`
- `AI_MEMORY_AGENTS` - `claude`, `opencode` or `"claude opencode"`. Default: every one that's installed, checked again on each run. OpenCode counts as installed when `opencode` is on PATH or `~/.config/opencode` exists. A saved agent that was uninstalled is skipped with a warning
- `AI_MEMORY_SUMMARIZER` - `claude` (Claude Code with a Claude subscription) or `opencode` (`opencode run` with any provider). Default `claude` when Claude Code is installed, otherwise `opencode`
- `AI_MEMORY_SUMMARY_MODEL` - the model that writes summaries. Required for `opencode`, as `provider/model` from `opencode models`. For `claude`, the default is the session's own model, falling back to `claude-opus-5-5`

A machine that uses OpenCode with GitHub Copilot and has no Claude subscription:

```sh
AI_MEMORY_SUMMARIZER=opencode AI_MEMORY_SUMMARY_MODEL=github-copilot/<strongest model> ./install.sh
```

The installer:
- Installs anything missing: `jq`, `node` (22+) and `sqlite` through Homebrew, and `qmd` through npm
- Checks the summarizer: warns if Claude Code isn't logged in with a subscription, or stops if `opencode` has no `AI_MEMORY_SUMMARY_MODEL`
- Creates `<vault>/sessions/` and copies `vault/README.md`, the note format and rules for every agent, into the vault
- Symlinks the hook and the `recall` skill into `~/.claude`. OpenCode loads skills from there too
- With Claude Code: links `/save-memory`, and registers the SessionEnd hook in `~/.claude/settings.json` without touching other hooks, after backing it up to `settings.json.ai-memory.bak`
- Adds a "check `/recall` before a design or tool choice" rule to `~/.claude/CLAUDE.md`, and with OpenCode to `~/.config/opencode/AGENTS.md` if that exists, unless the file already mentions `/recall`
- Indexes the notes with qmd and runs the qmd search server at `localhost:8181` as the launchd agent `ai-memory.qmd`
- Registers that server in Claude Code (user scope, read-only tools pre-allowed) and in OpenCode's config
- With OpenCode: links the plugin (save on quiet, `/save-memory`)
- For an agent left out of `AI_MEMORY_AGENTS`: removes what an earlier install added, the hook and `/save-memory` for Claude Code, the plugin for OpenCode, the qmd server entry in both, and the `/recall` rule from an instructions file no selected agent reads

It's safe to re-run. The first search downloads qmd's models, about 2GB, into `~/.cache/qmd/models/`

### Instructions for an AI agent doing the install

A person can run `./setup.sh`. An agent can't answer its questions, so it runs these steps in order and stops to report if one fails:

1. Check `uname` is `Darwin`. If not, stop: only macOS is supported
2. Check `brew --version` works. If not, stop and ask the user to install [Homebrew](https://brew.sh)
3. Check which agents exist: `claude --version` and `opencode --version`. If neither does, stop and ask the user to install one
4. Pick the summarizer:
   - If Claude Code exists, run `claude auth status`. If `authMethod` is `claude.ai` or `oauth_token`, use `AI_MEMORY_SUMMARIZER=claude` and leave `AI_MEMORY_SUMMARY_MODEL` unset
   - Otherwise, if OpenCode exists, use `AI_MEMORY_SUMMARIZER=opencode`. Run `opencode models` and pick the strongest model the user has access to, preferring the newest Claude Opus, then the newest GPT, for example under `github-copilot/`. Confirm the choice with the user and set `AI_MEMORY_SUMMARY_MODEL=<provider/model>`
   - If Claude Code exists but isn't on a subscription and the user wants the Claude summarizer, ask them to run `claude /login` in a terminal and wait
5. Ask the user where their Obsidian vault is, unless they already said. The memory folder is `<vault>/ai-memory`. Default `~/obsidian/Personal/ai-memory`
6. Clone the repo, if it isn't already there: `git clone https://github.com/skryvets/ai-memory.git ~/Code/ai-memory`
7. Run `AI_MEMORY_DIR=<memory folder> AI_MEMORY_SUMMARIZER=<choice> [AI_MEMORY_SUMMARY_MODEL=<model>] ~/Code/ai-memory/install.sh`. It needs network access for Homebrew, npm and the model download, plus keychain access for `claude`, so run it outside any sandbox
8. Verify, and report each result:
   - `cd ~/Code/ai-memory && ./test.sh` ends with `all tests passed`
   - `launchctl print gui/$(id -u)/ai-memory.qmd | grep state` shows `state = running`
   - `qmd collection list` lists `ai-memory`
   - With Claude Code: `claude mcp get qmd` shows `Connected`
   - With OpenCode: `jq .mcp.qmd ~/.config/opencode/opencode.json*` shows the `http://localhost:8181/mcp` entry
9. If OpenCode is installed, ask the user to run `opencode service restart` when no OpenCode session is busy, so it loads the plugin
10. Tell the user to restart open agent sessions, then try it: run `/save-memory`, or have a session of 4 or more messages and exit it (Claude Code) or leave it quiet for 10 minutes (OpenCode). A note appears in `<memory folder>/sessions/`, and `/recall <topic>` finds it

## Update

```sh
cd ~/Code/ai-memory && git pull && ./install.sh
```

Then run `opencode service restart` if you use OpenCode

## Test

```sh
./test.sh
```

The OpenCode plugin test needs [Bun](https://bun.sh) and is skipped without it

## Troubleshooting

- Every save logs to `~/.claude/ai-memory.log`: skipped sessions, saved notes and errors
  - "refusing to summarize" means Claude Code isn't on a subscription login. Run `claude /login`, or switch to the OpenCode summarizer
  - "summarizer returned no structured output" with the OpenCode summarizer usually means the model didn't reply with JSON. Pick a stronger `AI_MEMORY_SUMMARY_MODEL` and re-run `install.sh`
- The qmd server logs to `~/Library/Logs/ai-memory.qmd.log`. Restart it with `launchctl kickstart -k gui/$(id -u)/ai-memory.qmd`
- Search can't find a note you just edited: run `qmd update && qmd embed`
- OpenCode doesn't save or has no `/save-memory`: run `opencode service restart`, then check `~/.local/share/opencode/log/opencode.log` for `ai-memory.js`
