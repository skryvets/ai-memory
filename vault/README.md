# ai-memory

Shared memory for AI agents (Claude Code, OpenCode and others), kept apart from hand-written notes in this vault. Managed by https://github.com/skryvets/ai-memory

## Layout

- `sessions/` - one note per agent session, named `YYYY-MM-DD-<slug>.md`, written automatically when the session ends. A resumed session updates its note in place and keeps the file name

## Session note format

```
---
date: YYYY-MM-DD
agent: claude-code | opencode
model: <the session's model, the one that made the decisions>
project: <working directory>
session_id: <id, unique per note>
transcript: <path to the raw transcript, or an opencode session export command, may no longer exist>
tags: [claude-session | opencode-session, <topics>]
---
# <title>

## Goal
## Decisions
- <decision> - <why>
  - Replaced: <earlier choice> - <the edge case or fact that made it wrong> (with [[sessions/<note>]] when it came from an earlier session)
  - Rejected: <alternative> - <why not>
## Findings         research sessions only
## Open threads
```

## Rules for agents

- Before recommending a design or tool choice, search `sessions/` for earlier decisions on the same topic, with the qmd `query` tool (collection `ai-memory`) or grep. Read the Replaced and Rejected lines: they record choices that were already tried and dropped
- When notes disagree, the newest note is current. Between notes of a similar age, trust the one from the stronger model
- Never write secrets or credentials here. The vault syncs to other devices
