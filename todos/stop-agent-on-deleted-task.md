# Stop the scheduler's or agent's prompt when its task is deleted

When a task is deleted, or its lane is cleared, while the task scheduler is choosing its next step
or an agent is working on it, the run goes on to the end. `TaskService.remove` and `clear` in
`dashboard/source/service.d` only delete the rows and publish the event; nothing tells
`TaskScheduler` or `TaskExecutor` in `dashboard/source/agent.d`.

The data stays right: once the prompt returns, every write after it finds no task and does nothing.
`addNote` and the `record*` notes insert by selecting from `tasks`, `assignAiAgent` rolls back,
`changeAgentStatus` matches no row and `moveOn` returns early. But until then:

- The `claude` process started by `ClaudeCodeRuntime.run` keeps running, and its tokens and time
  are paid for nothing.
- An agent that calls the API about its task gets 404s, and whatever it writes to the working
  directory or its scratch space stays there.
- The run holds one of the agent's `maxParallelTasks` slots, or the scheduler's, so other tasks can
  wait behind it.
- The result is dropped without a word in the log.

## What to do

Stop the run as soon as its task is deleted:

1. **Make a run stoppable.** `IRuntime.prompt` has nothing to cancel it with. `ClaudeCodeRuntime.run`
   needs to be able to kill the process it got from `pipeProcess`, either from a handle it hands
   back or from a cancellation token passed in. A killed run should throw something the caller can
   tell apart from a failure, so no "Working on it failed" note is attempted and nothing is logged
   as an error.
2. **Know which runs are going.** `TaskScheduler` and `TaskExecutor` keep a map from the task's
   id to the run working on it, filled when a task is claimed and emptied in `scheduleClaimed`'s
   and `executeClaimed`'s `scope (exit)`.
3. **Learn of the deletion.** Either subscribe to the task `deleted` and lane `cleared` events
   (`eventing.d`), or have each loop's round check whether its running tasks still exist. The
   events are immediate. The check is simpler and also catches a task deleted straight in the
   database, but it waits up to one interval.
4. **Clean up.** A stopped run frees its slot in `running` as it ends now. The scratch space of an
   executor run can be removed; the working directory is the project's and is left alone.

A task deleted after its prompt has returned, but before its result is written, needs no change.
The writes already do nothing then.

## Also

- Deleting a project or a lane deletes its tasks too; those should stop their runs in the same way.
  With events, they need either an event per task or a lookup of the runs by lane or project.
- With several dashboards on one database, only the one running the prompt can kill it. Events
  reach only the dashboard that made the write, so a check against the database works there and
  an event does not.
