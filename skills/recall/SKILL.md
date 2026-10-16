---
name: recall
description: Search the shared AI memory vault for past sessions, decisions and research findings. Use when the user types /recall, asks what was decided, discussed, found or built before - "what did we decide about X", "how did we decide X", "did we look into Y", "remind me how we set up Z", "last time we talked about" - and before recommending a design or tool choice that may have been decided before
argument-hint: [topic or question]
allowed-tools: mcp__qmd__query mcp__qmd__get mcp__qmd__multi_get Bash(grep *) Bash(rg *) Bash(ls *) Read
---

Answer from the memory vault at `~/obsidian/Personal/ai-memory/sessions/`

Query: $ARGUMENTS

1. Search with the qmd `query` tool (`mcp__qmd__query` in Claude Code, `qmd_query` in OpenCode). Pass the user's question as plain text in `query`, and `collections: ["ai-memory"]`. It searches by meaning, so the exact words don't need to match
2. Read every relevant result, up to about 10 notes, newest first by the date in the file name. A result `qmd://ai-memory/<file>` is the file `~/obsidian/Personal/ai-memory/sessions/<file>`
3. If the qmd tool is missing or fails, search with `grep -ril` for the key terms and close synonyms instead, one term at a time
4. Answer directly. Cite each claim with its `[[sessions/<note>]]` wikilink, date and the `model:` from its frontmatter
5. For decisions, list them oldest to newest, with each one's why and its `Replaced:` and `Rejected:` lines. The newest decision is current. When notes disagree, prefer the newer note, then the one from the stronger model. Call out any alternative that was already tried and dropped, with the edge case that ruled it out - this is what keeps the user from re-making a decision that already failed
6. If the user is about to choose something a note lists as `Replaced` or `Rejected`, warn them and quote the reason
7. Notes are summaries. When the user needs exact detail, offer the note's `transcript:` - a file path for Claude Code, or an `opencode session export <id>` command for OpenCode
8. If nothing relevant is found, say so plainly. Never fill gaps from general knowledge as if it were remembered
