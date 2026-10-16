# ai-memory

Cross-project memory for Claude Code and OpenCode. When a session ends, or an OpenCode session goes quiet for 10 minutes, it's summarized by Opus into `~/obsidian/Personal/ai-memory/sessions/`. The summary covers the goal, the decisions and why, what each decision replaced or rejected and why, findings, and open threads

In any later session, in either tool, `/recall <topic>`, or just asking "what did we decide about X", searches those notes by meaning with [qmd](https://github.com/tobi/qmd) and lists the decision history oldest to newest

`/save-memory` saves the current session right away

See [SPEC.md](SPEC.md) for the design and decisions

## Install

Requires `jq`, `perl`, `claude` and `qmd` (`npm install -g @tobilu/qmd`). OpenCode is optional

```sh
./install.sh
```

The installer:
- Symlinks `hooks/ai-memory-save.sh` and `skills/recall/` into `~/.claude`
- Registers the SessionEnd hook in `~/.claude/settings.json` without touching other hooks, after backing it up to `settings.json.ai-memory.bak`
- Copies `vault/README.md`, the note format and rules for every agent, into the vault
- Indexes the notes with qmd, and runs the qmd search server at `localhost:8181` as the launchd agent `ai-memory.qmd`
- Registers that server in Claude Code (user scope, read-only tools allowed) and in OpenCode's config
- Links the `/save-memory` command into Claude Code, and the plugin (save on quiet, `/save-memory`) into OpenCode. Run `opencode service restart` afterwards, because the background service keeps the old plugin loaded

It's safe to re-run

## Test

```sh
./test.sh
```

## Troubleshooting

- Every save logs to `~/.claude/ai-memory.log`: skipped sessions, saved notes and errors
- The qmd server logs to `~/Library/Logs/ai-memory.qmd.log`. Restart it with `launchctl kickstart -k gui/$(id -u)/ai-memory.qmd`
