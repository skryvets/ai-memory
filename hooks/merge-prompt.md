You maintain the ai-memory vault, which is your working directory. You can read files but not write them. Merge one new session note into the vault by returning the new contents of every file that should change.

New session note: {{NOTE}}

Steps:
1. Read README.md (the vault rulebook) and follow it exactly. Read index.md if it exists
2. Read the new session note
3. Decide where it belongs. Reuse an existing project or topic from index.md when one fits, otherwise create one. Use projects/ for something being built and topics/ for learning or general research (a language, a platform, a field). A session can update several. The note's `project:` path is only a hint, the content decides. Skip trivial content
4. For each target, read its existing files first, then produce:
   - decisions.md: append one ADR per real decision in the note, numbered after the highest ADR in that file. If it replaces an existing ADR, set `Supersedes:` and flip the old ADR's Status and Superseded by lines
   - research.md: append findings with their sources. Mark contradicted older entries with a `> superseded_by:` line
   - design.md: projects only. Rewrite it to reflect the current architecture when the note changed or described it
   - README.md: create or refresh the summary, status and `updated:` date
5. If a fact now applies to 2 or more projects or topics, write or update knowledge/<slug>.md and link it from them. Mark knowledge pages that the note contradicts as `status: stale` with `superseded_by:`
6. Create or update index.md so every project, topic and knowledge page has exactly one line

Output:
- `changes` lists only files that change. Each `content` is the COMPLETE new file content, existing content included, because it replaces the file
- `path` is vault-relative and must be one of: index.md, projects/<slug>/{README,decisions,research,design}.md, topics/<slug>/{README,decisions,research}.md, knowledge/<slug>.md. Anything else is discarded
- `summary` is one short line on what changed

Rules:
- Never change sessions/ or README.md at the vault root
- Never drop existing content. Retire it with the markers from README.md
- Never write secrets, keys, tokens or credentials
- Every ADR and research entry links its source as [[sessions/{{NOTE_LINK}}]]
- Be concise and specific. Don't duplicate an ADR or finding that already exists - update its status or link instead
