# Remove the scratch spaces of runs that are over

Every one-off prompt to an agent and every task an agent works on runs in a scratch space of its
own, made by `createAgentScratchSpace` in `dashboard/source/agent.d` as
`<tempDir>/taskavista-tmp/taskavista-scratch-<agent id>-<run id>`, with a new random run id each
time. Nothing ever removes one, so a new directory is left behind by:

- every task an agent works on, since `TaskExecutor.execute` makes one for the run and passes it in;
- every step the task scheduler chooses, and every agent drafted by "Quick-create an agent", since
  `ClaudeCodeRuntime.prompt` makes one in `runAs` for a one-off prompt that is given none.

They pile up under `taskavista-tmp` until the OS clears its temp directory, if it does, along with
whatever the agents wrote there.

## What to do

1. **Remove a one-off run's scratch space when the run ends.** In `ClaudeCodeRuntime.prompt`, the
   `!createSession` branch is the only one whose scratch space `runAs` makes and nothing uses
   again. It is removed there, in a `scope (exit)`, whether the run answered or failed. The
   session branches make a chat's scratch space, which stays (see below).
2. **Remove an executor run's when the task is done with.** `execute` makes it and passes it in,
   so `execute` removes it, in a `scope (exit)` right after `createAgentScratchSpace` has
   succeeded. A failure to remove it is logged and does not fail the task.
3. **Clear what is left over on start-up.** Scratch spaces of runs a dashboard was in the middle
   of when it stopped or crashed are not removed by either step. A dashboard starting up has no
   runs going, so it can remove every one-off and executor scratch space, but not chats' (see
   below). Several dashboards on one machine share `tempDir`, though, so this would remove the
   scratch spaces of the other dashboards' runs. Either name the scratch spaces after the dashboard
   that made them, or accept that this setup is not supported.

## Chats' scratch spaces

A chat runs in the scratch space named after its session id, so that it can be resumed, since
Claude Code resumes a session only from the directory it ran in. Those have to stay as long as
the chat can be resumed. The UI's chat tabs last only as long as the page, but nothing tells the
server a chat is over, so they pile up too. Removing them needs a decision on when a chat ends:
on closing its tab, after a time with no messages, or never while its session exists in Claude
Code's own files.

The start-up clean-up in step 3 therefore has to tell them apart. Both kinds are named alike
today; giving one-off and executor runs a name of their own, or a parent directory of their own,
makes that easy.

## Also

- A run the loops stop, because its task was deleted, its project paused or its agent disabled or
  deleted, leaves `execute` with a `RunStoppedException`, so the same `scope (exit)` removes its
  scratch space too.
