# ai-memory

Cross-project memory for Claude Code and OpenCode. When a session ends, or an OpenCode session goes quiet for 10 minutes, Opus summarizes it into a Markdown note in an Obsidian folder (default `~/obsidian/Personal/ai-memory/sessions/`). The summary covers the goal, the decisions and why, what each decision replaced or rejected and why, findings, and open threads

In any later session, in either tool, `/recall <topic>`, or just asking "what did we decide about X", searches those notes by meaning and lists the decision history oldest to newest. `/save-memory` saves the current session right away

See [SPEC.md](SPEC.md) for the design and every decision behind it

## How memory is stored and searched

Each save does two steps:

1. **Write the note.** Opus summarizes the session through your Claude subscription and writes `sessions/YYYY-MM-DD-<slug>.md` into the vault. The Markdown file is the memory, and it's what you read in Obsidian
2. **Update the search index.** The same background job runs `qmd update && qmd embed`. [qmd](https://github.com/tobi/qmd) splits the new note into chunks and computes an embedding for each one on your machine, with no API calls

The embeddings don't live in Obsidian. qmd keeps them in its own index at `~/.cache/qmd/index.sqlite`, so the vault stays plain Markdown. If the index is lost or broken, `qmd update && qmd embed` rebuilds it from the notes

When you search, the always-on qmd server (`localhost:8181`) compares the question against that index and returns the best matching notes, which the agent then reads. Searches take about 0.5s, or about 3s after a few idle minutes while the models reload

The index refreshes only when a session is saved. A note you edit or delete by hand in Obsidian shows up in search after the next save, or right away if you run `qmd update && qmd embed`

Memory is per machine. To share it between laptops, sync the vault folder, for example with Obsidian Sync, and the index on each machine catches up on its next save

## Install

Requirements:
- macOS, because the search server runs under launchd
- [Homebrew](https://brew.sh)
- [Claude Code](https://code.claude.com/docs/en/setup), logged in with a Claude subscription (`claude /login`). Summaries never use an API key, and the hook refuses to run on API key, Bedrock, Vertex or Foundry auth
- Optional: [OpenCode](https://opencode.ai) 2

```sh
git clone https://github.com/skryvets/ai-memory.git ~/Code/ai-memory
cd ~/Code/ai-memory
./install.sh
```

For a vault somewhere else, pass its `ai-memory` folder, for example `AI_MEMORY_DIR=~/Documents/Obsidian/ai-memory ./install.sh`. The path is saved to `~/.config/ai-memory/env`, and later re-installs reuse it

The installer:
- Installs anything missing: `jq`, `node` (22+) and `sqlite` through Homebrew, and `qmd` through npm
- Warns if Claude Code isn't logged in with a subscription
- Creates `<vault>/sessions/` and copies `vault/README.md`, the note format and rules for every agent, into the vault
- Symlinks the hook, the `recall` skill and the `/save-memory` command into `~/.claude`
- Registers the SessionEnd hook in `~/.claude/settings.json` without touching other hooks, after backing it up to `settings.json.ai-memory.bak`
- Adds a "check `/recall` before a design or tool choice" rule to `~/.claude/CLAUDE.md`, unless it already mentions `/recall`
- Indexes the notes with qmd and runs the qmd search server at `localhost:8181` as the launchd agent `ai-memory.qmd`
- Registers that server in Claude Code (user scope, read-only tools pre-allowed) and in OpenCode's config
- Links the OpenCode plugin (save on quiet, `/save-memory`) when `~/.config/opencode` exists

It's safe to re-run. The first search downloads qmd's models, about 2GB, into `~/.cache/qmd/models/`

### Instructions for an AI agent doing the install

Run these steps in order and stop to report if one fails:

1. Check `uname` is `Darwin`. If not, stop: only macOS is supported
2. Check `brew --version` and `claude --version` work. If either is missing, stop and ask the user to install it (links above)
3. Run `claude auth status`. If `authMethod` isn't `claude.ai` or `oauth_token`, ask the user to run `claude /login` in a terminal, and wait for them
4. Ask the user where their Obsidian vault is, unless they already said. The memory folder is `<vault>/ai-memory`. Default `~/obsidian/Personal/ai-memory`
5. Clone the repo, if it isn't already there: `git clone https://github.com/skryvets/ai-memory.git ~/Code/ai-memory`
6. Run `AI_MEMORY_DIR=<memory folder> ~/Code/ai-memory/install.sh`. It needs network access for Homebrew, npm and the model download, and access to the keychain for `claude`. Run it outside any sandbox
7. Verify, and report each result:
   - `cd ~/Code/ai-memory && ./test.sh` ends with `all tests passed`
   - `launchctl print gui/$(id -u)/ai-memory.qmd | grep state` shows `state = running`
   - `claude mcp get qmd` shows `Connected`
   - `qmd collection list` lists `ai-memory`
8. If OpenCode is installed, ask the user to run `opencode service restart` when no OpenCode session is busy, so it loads the plugin
9. Tell the user to restart any open Claude Code sessions, then try it: have a session of 4 or more messages and exit, or run `/save-memory`. A note appears in `<memory folder>/sessions/` within about a minute, and `/recall <topic>` finds it

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

- Every save logs to `~/.claude/ai-memory.log`: skipped sessions, saved notes and errors. "refusing to summarize" means Claude Code isn't on a subscription login, so run `claude /login`
- The qmd server logs to `~/Library/Logs/ai-memory.qmd.log`. Restart it with `launchctl kickstart -k gui/$(id -u)/ai-memory.qmd`
- Search can't find a note you just edited: run `qmd update && qmd embed`
- OpenCode doesn't save or has no `/save-memory`: run `opencode service restart`, then check `~/.local/share/opencode/log/opencode.log` for `ai-memory.js`
