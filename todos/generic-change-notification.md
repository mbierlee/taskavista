# Design a generic way to report data changes

Every write to the database is meant to be reported to the open UIs over the change feed
(`ChangeFeed` in `dashboard/source/changes.d`, see `docs/change-feed.md`). Today each caller
does that by hand, straight after its repository call:

- the REST resources in `dashboard/source/api/rest.d` call `changes.project`, `changes.lane`,
  `changes.task` and `changes.agent` after each create, update and delete;
- the RPC calls in `dashboard/source/api/rpc.d` do the same for a move and the project settings;
- the task scheduler in `dashboard/source/agent.d` needed a helper of its own, `noted`, to report
  the notes it adds through `TaskRepository`, since the repository only says whether a note was
  added and leaves the reporting to the caller.

## The problem

- Nothing ties a write to its notification, so a new write path (a new endpoint, RPC call or
  agent action) can silently leave the UI stale, and it is easy to miss in review.
- The knowledge of which event a write causes, and which ids it concerns (such as the project and
  the lanes a task moved between), is repeated at every call site, and each call site has to look
  those ids up itself.
- Modules and classes grow small helpers like `noted` just to bridge a repository's answer to the
  change feed.

## What the design should achieve

- A write to the data cannot be made without its change being reported, or forgetting it is at
  least caught early.
- No per-module or per-class helpers for reporting changes.
- The messages on the change feed stay as they are described in `docs/change-feed.md`, unless the
  design gives a good reason to change them.

Design only: options, their trade-offs and a recommendation, before any implementation.
