# Code style

## Formatting

The editor formats the JS, HTML and CSS with prettier on save (double quotes, 2-space indent),
while the D source uses 4 spaces. Match whatever a file already looks like.

Always put braces around the body of an `if`, `else`, loop, `catch` or `scope` statement, even when the
body is a single line. This goes for the D and the JS alike.

## D imports

Every import goes at the top of the module, never inside a function, so a module's
dependencies can be read in one place. The one exception is a `unittest` block that needs
something only its tests use: that import goes inside the block.

Imports come in groups separated by a blank line: libraries (`vibe`, `dpq2`, `poodinis`), then
Phobos (`std`), then the project's own modules. Within the `std` group, one line per module,
sorted, with selective imports (`import std.format : format;`).

## Running things in the background

The caller decides what runs asynchronously, not the callee. A function does its work and
returns when it is done; a caller that should not wait on it, such as a request handler, wraps
the call in `runTask` itself, along with the `try`/`catch` that logs what it throws. That keeps
a function's behaviour visible where it is called, and lets another caller run it in the
foreground.

## Telling the person what went wrong

When work done for a task goes wrong or is skipped, such as an agent that fails or a task
with no agent to work on it, add a note to the task saying so, as well as logging it. The
log is for whoever runs the server; the note is what the person looking at the task sees,
and without it the task just sits there with no sign of why. Only what cannot be put on a
task, such as a task that is gone, is left to the log alone.

## Comments

A comment explains **why**: the reason for a choice, the constraint behind it, the trap it avoids.
It does not say **what** the code does. The code already says that, and a comment that repeats it
goes stale the first time the code changes. If the what matters, because it is not obvious from a
name or because a side effect is easy to miss, give it in one line as a summary rather than step
by step.

In the D source, the doc comment of a public class, interface or method, when it has one, follows
[Ddoc](https://dlang.org/spec/ddoc.html): a summary line, then a description if one is needed,
then whichever of the `Params:`, `Returns:` and `Throws:` sections apply. A short sentence is
enough for anything else: private methods, free functions and fields.

A doc comment that fits on one line is written with `///`. One that runs over more lines goes in a
`/** … */` block, never in a run of `///` lines. A plain `//` comment is not a doc comment.

```d
/**
 * Fills in a prompt.
 *
 * Params:
 *   prompt = The prompt's text.
 *   conditions = Each condition named by an `[if name]`, and whether it holds.
 *
 * Returns: The prompt with its blocks resolved.
 *
 * Throws: `Exception` when the prompt names a condition that is not in `conditions`.
 */
public string parse(string prompt, const bool[string] conditions)
```

A reason that holds for every instance of a pattern belongs here or in the skill for that kind of
work, not repeated above each instance.
