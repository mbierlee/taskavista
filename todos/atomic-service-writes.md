# Make the services' check-then-write sequences safe against concurrent writes

Several service methods in `dashboard/source/service.d` read, check and then write in separate
statements. Two writes arriving at once can slip between the check and the write. This is a real
case, not a theoretical one: AI agents write through the API while a person uses the UI.

The repository already does a write of several steps in one transaction where it has to, and that
stays the way: `addWithLanes`, `replaceWithLanes`, the agent with its labels, and the task writes,
which lock the lane (`lockLane`) and place the task inside the transaction. The cases below are
where the steps around such a call should be in that transaction too, or where the service's own
sequence needs one. See `docs/server-layers.md` for the layers.

## Data that ends up other than asked for

These should be one transaction, done in the repository.

1. **`ProjectService.save(ProjectWithLanes)`, update.** The service reads the project's lanes
   (`lanes.ofProject`) and works out which to delete before it calls `replaceWithLanes`; only that
   last call is a transaction.
   - A lane added in between, such as by `createLane` or an agent, is neither kept nor deleted, so
     the project no longer has "exactly these lanes", and its position may clash at commit, which
     is a 500.
   - A lane deleted in between makes its `update lanes … where id = $1` match nothing, and the call
     still succeeds.

   Fix: `replaceWithLanes` works out the lanes to delete itself, inside its transaction: delete
   every lane of the project whose id is not among those kept. The lane-id checks (another
   project's lane, an unknown lane, a lane listed twice) may stay in the service as the early
   answer.

2. **`replaceWithLanes` on a project that is gone.** The service checks `find` first, but if the
   project is deleted before the write, `execParams(update)[0]` indexes an empty answer. That is a
   `RangeError`, not an `Exception`, and in a release build, where `@system` code has no bounds
   checks, it is undefined behaviour. Fix: return `false` for no row, as `update` does, and have
   the service answer `ProjectNotFoundError`.

3. **`LaneService.save` and lane positions.** `nextPosition`, `positionTaken` and `add`/`update`
   are separate statements. Two lanes created at once with no position both get the same next
   position, and the second insert fails on the unique `(project_id, position)` constraint with a
   500. Fix: do as the tasks do. The repository locks the project's row, places the lane and
   checks its position in the transaction, and throws `PositionConflict`; the service turns that
   into `LanePositionTakenError`, as `TaskService` does for `TaskPositionTakenError`.

4. **`ProjectService.setAiPaused`.** It reads `managedByAi`, then sets `ai_paused`. If AI
   management is turned off in between, the resume still goes through, and an unmanaged project
   has its agents running. Fix: one statement,
   `update projects set ai_paused = $2 where id = $1 and (managed_by_ai or $2)`, with the
   repository telling "no project" apart from "not managed by AI".

## An answer that is wrong, while the database holds

The constraints keep the data right, but the caller gets a 500 where it should get a 409 or 404.

5. **Unique names.** `checkSlug` (projects) and `nameTaken` (agents) are checked before the write.
   Two clashing writes at once both pass, and the second fails on the unique constraint. Fix:
   either the repository turns a unique violation (SQLSTATE `23505`) into a typed exception that
   the service maps to `SlugTakenError`/`NameTakenError`/`AgentNameTakenError`, or the check and
   the write go in one transaction.

6. **A parent that is gone.** `LaneService.save` checks `projectExists`, and `TaskService.save`
   checks `projectOfLane`; a project or lane deleted before the insert gives a foreign-key failure,
   a 500 rather than a 404. Rare; the same fix as 5 if wanted.

## Already fine

- `TaskService.save` and `move` leave the positions to the repository's locked transactions, and
  `move` turns the remaining race, the task to go above leaving the lane, into
  `BeforeTaskNotInLaneError`. This is the pattern for 3.
- `AgentService.save` writes the agent and its labels in one transaction, and its runtime, model and
  effort checks read fixed data.
- The `remove` methods delete in one statement; the read before only gives the ids for the event.
- The reads, and the events, which are published only after a write has succeeded.

## Order

2 first, since it can be undefined behaviour; then 1 and 3, where the data ends up other than asked
for; then 4; and 5 and 6 last, which only give the wrong status.
