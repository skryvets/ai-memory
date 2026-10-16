# ai-memory

Shared memory for AI agents (Claude Code and others), kept apart from hand-written notes in this vault. Managed by https://github.com/skryvets/ai-memory

## Layout

- `sessions/` - one note per agent session, named `YYYY-MM-DD-<slug>.md`. Written automatically at session end, overwritten when the same session is resumed and ended again

## Session note format

```
---
date: YYYY-MM-DD
agent: claude-code
model: <model id>
project: <working directory>
session_id: <id, unique per note>
transcript: <path to the raw transcript, may no longer exist>
tags: [claude-session, <topics>]
---
# <title>

## Goal
## Decisions        "<decision> - <why>" bullets
## Findings         research sessions only
## Open threads
```

## Rules for agents

- Search `sessions/` before claiming something was never discussed
- Never write secrets or credentials here. The vault syncs to other devices
- Keep `session_id` unique - one note per session
