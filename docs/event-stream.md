# The event stream

Every write made through the API is reported to each open web UI over a WebSocket, so that a
change made somewhere else shows without a reload. That mostly means AI agents, which work
through the same REST and RPC calls as the UI, but it also covers a second browser tab.

The server side is `EventStream` in `dashboard/source/eventing.d`, served at `/api/events/v1`. The
UI side is the "changes made elsewhere" section of `dashboard/public/app.js`.

## A message is an event, not data

Each message is a JSON object holding a `type` and the ids it concerns, and nothing else:

| `type` | Ids | Sent by |
|---|---|---|
| `task-created` | `taskId`, `projectId`, `toLaneId` | The tasks REST endpoints |
| `task-changed` | `taskId`, `projectId`, `fromLaneId`, `toLaneId` | The tasks REST endpoints (a `PUT` can move a task) |
| `task-moved` | `taskId`, `projectId`, `fromLaneId`, `toLaneId` | `moveTask`, and the task scheduler when it moves a task on to the lane its agent starts it in |
| `task-deleted` | `taskId`, `projectId`, `fromLaneId` | The tasks REST endpoints |
| `lane-created`, `lane-changed`, `lane-deleted` | `laneId`, `projectId` | The lanes REST endpoints |
| `project-created`, `project-changed`, `project-deleted` | `projectId` | The projects REST endpoints, `createProject`, `saveProjectSettings`, `setAiPaused` |
| `agent-created`, `agent-changed`, `agent-deleted` | `agentId` | The agents REST endpoints |
| `note-created` | `taskId`, `projectId` | The task scheduler, for each note it adds to a task |

The UI fetches whatever it needs through the REST API. That keeps a single way of reading the
data, and a message lost while the socket is down costs only a refetch. `projectId` comes with
task and lane events so that the UI can skip the ones for a board it is not showing without
fetching anything. A task event also names the lane the task left and the lane it is in now,
which are the lanes the UI refetches. The UI must not work these out from what it has drawn:
while events are still queued, that drawing is behind, and it is wrong about where a task
was. `saveProjectSettings` sends a single `project-changed` rather than an event
per lane, so the UI reads `project-changed` for the project on screen as "its lanes may have
changed too". A write to a task also adds a note to it, and its own
task event stands for that note, so `note-created` is sent only for a note added without one,
such as the scheduler's.

An API call reports its write after the write has succeeded, so a refused call sends nothing. Writes made
any other way, such as straight into the database, are not reported. The one exception is that
the UI fetches everything again after it reconnects.

## The server

A message is queued for each open socket and sent by that socket's own task, never by the
request that made the change. A UI that is slow to read therefore holds up only itself. While
the sender task waits for messages, the handler task reads the socket and ignores what it
reads, which is how a closed socket is noticed.

## The UI

The UI's own writes come back over the stream too, and the screen already shows them. So the UI
compares what it fetches with what it has drawn, and it draws again only what differs: a lane
whose cards changed, or the whole row of lanes if the lanes themselves changed. A card for a
task that is new to the board gets the same `added` glow as a card added on the page.
A card that moved, to another lane or within one, slides from where it was drawn to where it
is now, through the board's `animateMoves`, and a card whose task was deleted fades out before
the cards around it close the gap. The page's own moves and deletes are drawn before their events
come back, so those find nothing to draw again and do not fly.

## Ending up correct

Correctness matters more here than the number of requests. What makes the end state right:

- **Every change leads to a fetch made after it.** The server reports a write only once it has
  been stored, and the UI fetches only once the message has arrived. Every lane a change touched
  is therefore fetched at least once after its last change. This holds even if two requests
  report their changes in a different order from the one in which they were stored.
- **Older data never replaces newer.** Board updates run one at a time, in the order their events
  arrived. Each project list or agent list fetch is numbered, and a fetch that answers after a
  later one has been shown is dropped.
- **A fetched lane wins.** A burst of moves, such as an agent clearing a lane, means a lane
  fetched for one event can already hold tasks whose own events haven't been handled yet. A task
  found in a fetched lane is taken off every other lane it is drawn in, rather than showing twice
  until its own event comes up.
- **Nothing reported is dropped.** A change to a board that is still loading marks the board to be
  fetched again once it is in, since the load may have read the data before that change. Every
  time the socket opens, including the first, everything is fetched again, because changes made
  while no socket was open are never reported.
- **A failed update is retried.** A board update that fails, apart from a lane that has been
  deleted, which its own event takes care of, is followed by one fetch of the whole board.

Each board update waits until no write from this page is pending and no card is being dragged,
and it fetches again if either started while it was fetching. A fetch that overtook one of this
page's writes would draw back the state from before the write, and drawing a lane again mid-drag
would end the drag.

The details panel follows its task: it closes if the task was deleted, and if the task moved or
its description changed, it shows that and fetches the notes again. It fetches them again
too on a `note-created` for its task. An edit that is still being
typed in the panel is overwritten if the description changes elsewhere.

When the project list changes, a project that did not change keeps the object it had. The board
follows the selected project's identity, so this keeps it from loading again for no reason. The
board also does not load again when the only change is its agents being paused or resumed. A
board whose project was renamed elsewhere moves to its new URL, and one whose project was
deleted goes to `/`.

A socket that drops is opened again every two seconds until the server answers.
