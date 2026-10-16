---
name: recall
description: Search the shared AI memory vault for past sessions, decisions, research findings and project or topic knowledge. Use when the user types /recall, or asks what was decided, discussed, found or built before - "what did we decide about X", "how did we decide X", "did we look into Y", "what do we know about Z", "remind me how we set up", "last time we talked about"
argument-hint: [topic or question]
allowed-tools: Bash(grep *) Bash(rg *) Bash(ls *) Read
---

Answer from the memory vault at `~/obsidian/Personal/ai-memory/`. Its `README.md` is the rulebook for layout and markers - read it once if anything below is unclear

Query: $ARGUMENTS

1. Read `index.md`. Pick the projects, topics and knowledge pages whose line matches the query
2. Read those pages, starting with their `README.md`, then `decisions.md`, `research.md`, `design.md` or the knowledge page as the question needs. Follow `[[wikilinks]]` one or two hops when they look relevant
3. If the index has no match, or the pages don't answer it, grep `projects/`, `topics/`, `knowledge/`, then `sessions/` case-insensitively for the key terms and close synonyms. Read the top 3 to 5 hits
4. Answer directly. Cite every claim with its wikilink and date
5. Report only what is current, and say so when something isn't:
   - An ADR with `Status: superseded` - give the ADR that replaced it instead
   - A research entry with a `> superseded_by:` line, or a page with `status: stale` - give its replacement
   - An `Expires:` date that has passed, or an expiry condition - say it may no longer hold
6. For "how did we decide X" or "how did X change", trace the decision history: start at the current ADR and follow `Supersedes:` back to the first, then list them oldest first as `ADR-N (date) - decision - why it was replaced`
7. Session notes and pages are summaries. When the user needs exact detail, offer to open the `transcript:` path in the session note's frontmatter, if the file still exists
8. If nothing relevant is found, say so plainly. Never fill gaps from general knowledge as if it were remembered
