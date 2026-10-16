---
name: recall
description: Search the shared AI memory vault for past sessions, decisions and research findings. Use when the user types /recall, asks what was decided, discussed, found or built before - "what did we decide about X", "how did we decide X", "did we look into Y", "remind me how we set up Z", "last time we talked about" - and before recommending a design or tool choice that may have been decided before
argument-hint: [topic or question]
allowed-tools: Bash(grep *) Bash(rg *) Bash(ls *) Read
---

Answer from the memory vault at `~/obsidian/Personal/ai-memory/sessions/`

Query: $ARGUMENTS

1. Search the notes case-insensitively for the query's key terms and close synonyms, one term at a time. Match `tags:` lines, titles and body text. Use `grep -ril` or `rg -il`, then `grep -c` to rank files by hit count
2. Read every matching note, up to about 10, newest first by the date in the file name. If nothing matches, try broader or related terms once
3. Answer directly. Cite each claim with its `[[sessions/<note>]]` wikilink and date
4. For decisions, list them oldest to newest, with each one's why and its `Replaced:` and `Rejected:` lines. The newest decision is current. Call out any alternative that was already tried and dropped, with the edge case that ruled it out - this is what keeps the user from re-making a decision that already failed
5. If the user is about to choose something a note lists as `Replaced` or `Rejected`, warn them and quote the reason
6. Notes are summaries. When the user needs exact detail, offer to open the `transcript:` path from the note's frontmatter, if that file still exists
7. If nothing relevant is found, say so plainly. Never fill gaps from general knowledge as if it were remembered
