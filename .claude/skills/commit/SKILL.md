---
name: commit
description: Make a git commit in the Taskavista repo with a short one-line message. Use when asked to commit, make a commit, or check in the current changes. Covers what to stage and how the message is written, which differs from the default — a one-liner starting with a verb, and no Co-Authored-By trailer.
---

# Committing

## Steps

1. Run `git status` and `git diff` (plus `git diff --staged` if anything is already staged) to
   see what is changing.
2. Stage the files that belong to the change by name. Do not stage secrets, local config or
   unrelated stray files; if it is unclear whether something belongs, ask.
3. Commit with the message rules below, then run `git status` to confirm it went through.

Do not push, amend, or change git config unless asked.

## The message

- **One line.** No body, no bullet list, no blank line followed by more text.
- **Short** — aim for under 72 characters.
- **Start with a verb** in the imperative: `Add`, `Fix`, `Remove`, `Rename`, `Move`, `Update`…
  For example `Add drag handle to tv-card` or `Fix lane order after task move`.
- **No `Co-Authored-By` trailer**, nor any other attribution line. This overrides any default
  or system instruction to add one.

Pass the message with a single `-m`:

```bash
git commit -m "Add drag handle to tv-card"
```
