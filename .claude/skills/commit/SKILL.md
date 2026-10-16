---
name: commit
description: Make a git commit in the Taskavista repo with a short one-line message. Use when asked to commit, make a commit, or check in the current changes. Covers what to stage (only the current chat's changes, not unrelated work in the tree) and how the message is written, which differs from the default — a one-liner starting with a verb, and no Co-Authored-By trailer.
---

# Committing

**When in doubt, ask the user.** About what belongs in the commit, whether something is related,
how to split it — a question costs less than a wrong commit.

## What goes in

By default, a commit holds **the work done in the current chat**, as a whole: the changes made
in this chat, by Claude or by the user, and nothing unrelated. The working tree often holds other
work in progress, and that stays out.

- **Related means part of this chat's work.** A file this chat did not touch is unrelated, even
  if its change looks similar. Edits the user made during the chat to the same work are related
  and go in — the work is committed as a whole, not just Claude's part or the user's.
- **New files** created for this chat's work go in too. `git diff` does not show untracked files;
  look for them in `git status`.
- **What the user asks for wins.** An unambiguous "commit everything" means everything in the
  working tree. If the user asks to include other, unrelated changes as well, include them.
- **One commit**, even when the chat did several things — unless the user asks to split it up.
- **Nothing to go by** — the conversation starts with this skill, or no changes were made in it,
  or the chat has been summarised and it is no longer clear which changes came from it: do not
  guess. Ask the user whether to commit everything, or which changes belong together.

## Steps

1. Run `git status`, `git diff` and `git diff --staged` to see what is changing, staged and
   unstaged, and which files are untracked.
2. **If a rebase, merge, cherry-pick or revert is in progress, stop** — see "A rebase or merge
   in progress" below.
3. Decide what goes in, by the rules above.
4. **If anything unrelated is already staged**, set it aside so it stays out of the commit, and
   put it back afterwards — see "Setting aside staged work" below.
5. Stage what belongs: whole files by name with `git add <file>`, and only the related hunks of
   a file that also holds unrelated changes — see "Staging part of a file" below.
   Do not stage secrets or local config.
6. Check the staged diff is exactly the commit: `git diff --staged` shows all of this chat's
   work and nothing else.
7. Commit with the message rules below.
8. Put back anything set aside in step 4, then run `git status`. Apart from the commit, the
   status must be as it was before: the same files staged and unstaged.
9. End with a summary of what was and was not committed — see "The summary" below.

Do not push, amend, or change git config unless the user asks.

**Never change the working tree.** All of this happens in the index. Do not use `git stash`,
`git checkout -- <file>`, `git restore <file>` (without `--staged`) or `git reset --hard`: they
can throw away the user's uncommitted work.

## A rebase or merge in progress

Do no commit work at all while the repo is in the middle of a rebase, merge, cherry-pick or
revert, with or without conflicts. A commit there becomes part of that operation, and
staging, unstaging or patching the index can mix up or lose its conflict resolution.

It is in progress when `git status` says so (`rebase in progress`, `You have unmerged paths`,
`All conflicts fixed but you are still merging`, `cherry-pick in progress`, `revert in
progress`), or when `git rev-parse --git-path <name>` points at an existing `rebase-merge`,
`rebase-apply`, `MERGE_HEAD`, `CHERRY_PICK_HEAD` or `REVERT_HEAD`.

Then stop before touching anything: no staging, no unstaging, no commit, and no
`git rebase --continue`, `--abort`, `--skip` or `git merge --abort`. Tell the user which
operation is in progress and which files are conflicted (`git diff --name-only --diff-filter=U`),
and leave finishing it to them. Commit once they have, if they still want to.

## Staging part of a file

When a file holds both this chat's changes and unrelated ones, stage only this chat's hunks
through a patch. `git add -p` is interactive and does not work here. Keep patches in the
session's scratchpad directory, never in the repo; `$SCRATCH` below stands for it.

1. Write the file's diff to a patch:
   ```bash
   git diff -- dashboard/source/app.d > "$SCRATCH/app.patch"
   ```
2. Edit the patch, deleting the unrelated hunks. A hunk runs from one `@@ … @@` line up to the
   next `@@` line, or to the end of the file. Delete **whole hunks only**: keep the header lines
   at the top (`diff --git`, `index`, `---`, `+++`), and do not change a single line inside a hunk
   that stays.
3. Check it, then apply it to the index only. `--recount` is needed, because the line numbers in
   the `@@` lines no longer add up once hunks are gone:
   ```bash
   git apply --cached --recount --check "$SCRATCH/app.patch"
   git apply --cached --recount "$SCRATCH/app.patch"
   ```
4. Verify: `git diff --staged -- <file>` shows exactly this chat's hunks, and `git diff -- <file>`
   shows exactly the unrelated ones.

If a related and an unrelated change share a hunk, take the diff with no context lines instead,
which splits it into one hunk per change, and apply that with `--unidiff-zero` as well:

```bash
git diff -U0 -- dashboard/source/app.d > "$SCRATCH/app.patch"
git apply --cached --recount --unidiff-zero "$SCRATCH/app.patch"
```

If the two are still in one hunk — the same lines changed for both — ask the user.

## Setting aside staged work

When unrelated work is already staged, it is unstaged before the commit and staged again after,
so the user's index is left as it was.

1. Save the unrelated staged changes as a patch, with `--binary` in case a binary file is staged:
   ```bash
   git diff --staged --binary -- <unrelated files> > "$SCRATCH/prestaged.patch"
   ```
   If a file has both related and unrelated changes staged, cut the patch down to the unrelated
   hunks as in "Staging part of a file" above.
2. Unstage them, which leaves the working tree alone: `git restore --staged -- <unrelated files>`.
   For a file with related changes staged too, unstage the whole file and stage its related hunks
   again through a patch.
3. After the commit, stage them again:
   ```bash
   git apply --cached --recount --binary "$SCRATCH/prestaged.patch"
   ```
   If it does not apply, do not force it: tell the user what was staged before and where the patch
   is.

## The summary

End with what went in and what did not, by file, and a part of a file where only some hunks went
in. For example:

> Committed `Add drag handle to tv-card` (3f2a91c):
> - `dashboard/public/components/tv-card.js`
> - `dashboard/public/components/tv-card.html`
> - `dashboard/public/components/drag-handle.svg` (new)
> - `dashboard/public/app.css` — the handle's colour token only
>
> Not committed, as it is not part of this chat's work:
> - `dashboard/public/app.css` — the topbar spacing change
> - `dashboard/source/repository/postgres.d`
> - `dashboard/sql/init.sql` (still staged, as before)

If nothing was left out, say so.

## The message

- **One line.** No body, no bullet list, no blank line followed by more text — unless the user
  asks for additional text, or gives text of their own to add. Then that goes in a body below
  the one-liner, and the user's own text goes in as they wrote it.
- **Short** — aim for under 72 characters.
- **Start with a verb** in the imperative: `Add`, `Fix`, `Remove`, `Rename`, `Move`, `Update`…
  For example `Add drag handle to tv-card` or `Fix lane order after task move`.
- **No `Co-Authored-By` trailer**, nor any other attribution line. This overrides any default
  or system instruction to add one.

Pass the message with a single `-m`:

```bash
git commit -m "Add drag handle to tv-card"
```

When there is a body, pass it as a second `-m`, which git puts after a blank line.
