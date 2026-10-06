# AGENTS.md

## Git

- `.git` is intentionally read-only. Never run git write operations (`add`, `commit`, `stash`, `tag`) and never try to work around it (remount, elevate, override `GIT_DIR`). Read-only commands (`status`, `diff`) are fine.
- When the user asks to commit, output a copy-pasteable command — do not run it.
- Commit messages are always in English.
- One command per line, never wrapped. The user is on Windows PowerShell: no heredocs, no multi-line strings.
- Use separate single-line `-m` flags for title and body.
- Put `git add` and `git commit` on their own lines.
- Never `push` unless explicitly asked.
