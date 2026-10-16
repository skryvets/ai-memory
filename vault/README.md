# ai-memory

Shared memory for AI agents (Claude Code and others), kept apart from hand-written notes in this vault. Managed by https://github.com/skryvets/ai-memory. This file is the rulebook for every agent that reads or writes here

## Layout

```
index.md                 one line per project, topic and knowledge page - read this first
sessions/                one note per agent session, written automatically. Never edited by the merge
projects/<slug>/         things being built
  README.md
  decisions.md           append-only numbered ADRs
  research.md            append-only dated findings
  design.md              current architecture, rewritten in place. Only once architecture was discussed
topics/<slug>/           learning domains (go, youtube, ai, ...)
  README.md
  research.md
  decisions.md           only when a decision was made
knowledge/<slug>.md      facts proven across 2+ projects or topics
```

Slugs are lowercase and hyphenated. One session can feed several projects or topics. Wikilinks use vault-relative paths without `.md`, like `[[projects/ai-memory/decisions#ADR-003]]` or `[[sessions/2026-10-16-some-title]]`

## Frontmatter

`projects/<slug>/README.md` and `topics/<slug>/README.md`:

```
---
kind: project | topic
status: active | paused | done
updated: YYYY-MM-DD
tags: [...]
---
# <Name>

<one-paragraph summary of what it is and where it stands>
```

`knowledge/<slug>.md` and any page that stops being true:

```
---
status: current | stale
updated: YYYY-MM-DD
superseded_by: "[[...]]"     only when stale
sources: ["[[...]]"]
---
```

## decisions.md

Append-only, numbered per file, newest at the bottom. Old entries are never edited except their `Status` and `Superseded by` lines

```
## ADR-007: <title>
- Date: YYYY-MM-DD
- Status: accepted            (accepted | superseded | expired)
- Supersedes: ADR-003         (or -)
- Superseded by: -
- Expires: -                  (optional date YYYY-MM-DD or a condition)
- Source: [[sessions/<note>]]

<the decision> - <why>. Alternatives rejected and why, when known
```

When ADR-N replaces ADR-M, set ADR-M to `Status: superseded` and `Superseded by: ADR-N`

## research.md

Append-only, newest at the bottom

```
## YYYY-MM-DD - <finding title>
<the finding, specific, with numbers, versions, names>
- Sources: <URLs>, [[sessions/<note>]]
```

When a later finding contradicts an entry, add a line under the old entry: `> superseded_by: [[<file>#<heading>]] - <why>`. Never delete the old entry

## index.md

```
# ai-memory index

## Projects
- [[projects/<slug>/README|<Name>]] - <one-line summary> - updated YYYY-MM-DD

## Topics
- [[topics/<slug>/README|<Name>]] - <one-line summary> - updated YYYY-MM-DD

## Knowledge
- [[knowledge/<slug>|<Name>]] - <one-line summary> - updated YYYY-MM-DD
```

## Rules for agents

- Read `index.md` first. Search `sessions/` before claiming something was never discussed
- Treat `status: stale`, `Status: superseded`, `> superseded_by:` and passed `Expires:` as no longer true
- Never write secrets or credentials here. The vault syncs to other devices
- Never delete content. Retire it with the markers above
- The folder is a git repo. Every automatic merge is one commit, so `git log` is the audit trail and the undo
