# ai-memory

Cross-project memory for Claude Code. When a session ends, a SessionEnd hook:
- Summarizes it into `~/obsidian/Personal/ai-memory/sessions/`
- Has a read-only agent merge that summary into per-project and per-topic pages: decision records with history, research findings, design, and an `index.md`
- Commits the result to the vault's local git repo

In any later session, `/recall <topic>`, or just asking "what did we decide about X", reads the index, the pages, and then falls back to search

See [SPEC.md](SPEC.md) for the design and decisions

## Install

Requires `jq`, `perl`, `git` and `claude`

```sh
./install.sh
```

The installer:
- Symlinks `hooks/ai-memory-save.sh` and `skills/recall/` into `~/.claude`
- Registers the SessionEnd hook in `~/.claude/settings.json` without touching other hooks, after backing it up to `settings.json.ai-memory.bak`
- Copies `vault/README.md`, the rulebook for every agent, into the vault and makes the vault a git repo

It's safe to re-run

## Test

```sh
./test.sh
```

## Troubleshooting

Every run logs to `~/.claude/ai-memory.log`: skipped sessions, saved notes, merged and rejected paths, and errors. To undo a bad merge, run `git -C ~/obsidian/Personal/ai-memory log` and then `git revert`
