# ai-memory

Cross-project memory for Claude Code. When a session ends, a SessionEnd hook summarizes it into `~/obsidian/Personal/ai-memory/sessions/`. The summary covers the goal, the decisions and why, what each decision replaced or rejected and why, findings, and open threads

In any later session, `/recall <topic>`, or just asking "what did we decide about X", searches those notes and lists the decision history oldest to newest

See [SPEC.md](SPEC.md) for the design and decisions

## Install

Requires `jq`, `perl` and `claude`

```sh
./install.sh
```

The installer:
- Symlinks `hooks/ai-memory-save.sh` and `skills/recall/` into `~/.claude`
- Registers the SessionEnd hook in `~/.claude/settings.json` without touching other hooks, after backing it up to `settings.json.ai-memory.bak`
- Copies `vault/README.md`, the note format and rules for every agent, into the vault

It's safe to re-run

## Test

```sh
./test.sh
```

## Troubleshooting

Every run logs to `~/.claude/ai-memory.log`: skipped sessions, saved notes and errors
