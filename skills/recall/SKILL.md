---
name: recall
description: Search the shared AI memory vault for past sessions, decisions and research findings. Use when the user types /recall, or asks what was decided, discussed, found or built before - "what did we decide about X", "did we look into Y", "remind me how we set up Z", "last time we talked about"
argument-hint: [topic or question]
allowed-tools: Bash(grep *) Bash(rg *) Bash(ls *) Read
---

Answer from the memory vault at `~/obsidian/Personal/ai-memory/`. Read its `README.md` once if the note format is unclear

Query: $ARGUMENTS

1. Search `~/obsidian/Personal/ai-memory/sessions/` case-insensitively for the query's key terms and close synonyms, one term at a time. Match titles, `tags:` lines and body text. Use `grep -ril` or `rg -il`, then `grep -c` to rank files by hit count
2. Read the top 3 to 5 matching notes in full. If nothing matches, try broader or related terms once before giving up
3. Answer the question directly from the notes. Quote decisions with their "why", and cite each note as a wikilink `[[note-file-name]]` with its date
4. Notes are summaries. When the user needs exact detail the note lacks, offer to open the `transcript:` path from the note's frontmatter, if that file still exists
5. If nothing relevant is found, say so plainly. Never fill gaps from general knowledge as if it were remembered
