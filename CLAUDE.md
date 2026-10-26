# Taskavista

Taskavista is a task board: a project holds lanes, lanes hold task cards.

- `dashboard/` — a D / vibe.d HTTP server that serves the web UI out of `public/`, layered into
  controllers, services and repositories (see `docs/server-layers.md`). It also
  holds `sql/init.sql`, the whole schema — `projects`, their `lanes`, the `tasks` in them, each task's `task_notes`, the fixed `runtimes` and their `models`, the fixed `effort_levels` and which of them each model takes (`model_effort_levels`), the `agents` that run on them and their `agent_labels`, and the `defaults`, a value per key — which it applies on
  start-up when the database is still completely empty.
- `docker/` — postgres 18 and pgadmin.
- `mock-data.sql` — sample rows, applied by hand; nothing runs it automatically.

The UI reads projects, their lanes and the lanes' tasks from the REST API (`dashboard/public/rest-openapi.yaml`, an OpenAPI spec),
with operations that are not plain CRUD, such as moving a task, in the RPC API (`dashboard/public/rpc-openapi.yaml`;
why the APIs are shaped as they are, and how their errors are answered, is in `docs/rest-api.md`
and `docs/rpc-api.md`),
and the board shows each task as a `tv-card`. Cards can be dragged within a lane or to another
lane, and tasks added from a lane's "+ Add a task", both saved through the API. A lane that marks
tasks done has a "Clear" button that, once confirmed, deletes all of its tasks in one RPC call. A card an AI agent is at work on, the task scheduler included,
has its lane's colour sweeping along its border and names the agent. Clicking a card
opens the task details panel over the board, with the task's lane (which it can be moved out of),
its description, which can be edited there, the agent working on it, and its notes, and a button that deletes the task, beside which a task in a lane the agents pick up, added before the lane was one, gets "Schedule for AI", which hands it to the agents. A project's
name, description and lanes, with which of them take new tasks, close them and are worked on by agents, and its working directory, under "Advanced", are edited on its settings screen (`/projects/:slug/settings`),
and a project is created on the same screen in its new-project mode (`/projects/new`). With no
projects yet, `/` shows the project prompt (`tv-project-prompt`) instead of a board, where an agent (Generic, or else a task scheduler)
drafts the first project from a description, with `dashboard/prompts/quick-create-project.txt`, and opens the
draft on the new-project screen to be reviewed before it is created; the same prompt is the project switcher's
"Quick-create project" (`/projects/new/quick`) once there are projects.
The Taskavista settings screen (`/settings`, the topbar's ⚙) lists the AI agents, and adds,
edits and deletes them in a dialog, along with their labels; a new agent starts on the runtime, model and effort level in `defaults`, and each agent is run at its effort level. An agent can be disabled there, which keeps the task scheduler from giving it tasks (a disabled task scheduler schedules none) and stops what it is working on, handing those tasks back to the scheduler; it can still be chatted with. Its "Quick-create an agent" has an agent (Generic, or else a task scheduler) draft one from a description, with `dashboard/prompts/quick-create-agent.txt`, and opens the draft in that dialog to be reviewed before it is added.
A project managed by AI agents, which is one with a lane the agents pick up, shows a strip over its board saying whether the agents are at
work, with a button that pauses or resumes them. Pausing stops the agents' runs on its tasks
within a round of the task scheduler's and executor's loops, as deleting a task does its run; a
stopped task waits to be taken up again on resume. The topbar's chat button opens the agent chat, a panel beside
every screen with a tab per chat with an agent. A chat is a session on the agent's runtime, started
with a system prompt of two parts, each filled in by `PromptParser`: `dashboard/prompts/system/agent.txt`,
which starts every interaction with an agent and gives it the API help in
`dashboard/public/agent-help.txt` (which agents can also fetch from the server), then
`dashboard/prompts/system/new-agent-chat.txt`, the chat's own part; the tabs last as long as the page.
A project can have a working directory for its files, kept in `projects.working_dir`: a new project's is
named after its slug under `projectWorkingDirRoot` in `config.json`, unless another is given, and stays
where it is when the slug changes. It is made when the directory it goes in exists (see `workingdir.d`): task agents run in it, and
a chat started in a project runs in its own scratch space with the working directory open to it. Closing
a chat's tab ends the chat on the server, which removes its scratch space, and a run's scratch space goes when the run ends. With no working directory, agents work in their scratch space. A project
whose working directory has an `index.html` has an "Open project" button in the topbar, which opens
it in a new tab, served under `/working-dirs/<slug>/`; it appears once a task is moved after the page
was made, such as by the task scheduler moving on the task whose agent made it. Every write
through the API is reported to the open UIs over a WebSocket
(`/api/events/v1`), as an event and the ids it concerns, and the UI fetches what changed, so what
an agent does shows on screen straight away (see `docs/event-stream.md`).

## Running it

| | |
|---|---|
| Dashboard | `cd dashboard && dub run` → http://localhost:8080 (port in `config.json`, or another config file given with `dub run -- --config=config-dev.json`) |
| Database | `docker/run.sh -d` → postgres on 5432, pgadmin on http://localhost:5050 |

There are no tests. There is no frontend build step, so a UI change needs only a reload;
a change to `app.d` needs a rebuild.

The UI mockups are not in this repo — see the `taskavista-designs` skill. The database is
only reachable through the container, since there is no local psql — see `taskavista-database`.

## The UI is native web components

No framework, no bundler, no npm. The screen is assembled from custom elements in
`dashboard/public/components/`, each one a `tv-thing.js` / `tv-thing.html` pair, styled with the
classes in `components/shared.css` (buttons, fields, labels) and the colour tokens in `app.css`. Data goes down
as attributes, or through the small store in `store.js` (see `docs/store.md`) when it is shared
or deeply nested;
changes come up as `composed` events. `app.js` holds the data, and is the only writer to the
store. It is also the router: each screen has a real URL (`/projects/:slug`), matched in the
browser, and the server hands every path that is not a file or `/api/` the same `index.html`
(see `docs/routing.md`).

**Read `docs/webcomponents.md` before changing the UI** — it covers the conventions, how a
component is put together, and the gotchas (notably: a headless screenshot of the board comes
out blank, and that is the tool, not a bug). To check a UI change in a browser, headless or
headful, use the `taskavista-browser-check` skill.

## Code style

**Read `docs/code-style.md` before writing code**: formatting, braces, and what a comment is for.
