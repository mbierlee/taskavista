# The UI store

`dashboard/public/store.js` is a small Redux-like store for the web UI: one state object that
components watch directly, so data does not have to be handed down through every component in
between. It is about thirty lines on top of `EventTarget`, with no library behind it.

For how components are built and how they otherwise talk, see [webcomponents.md](webcomponents.md).

## Why it exists

A component inside another component's shadow root cannot be reached from the page. The project
switcher lives in the topbar's shadow DOM, so `app.js` has no way to hand it anything directly —
the alternative is forwarding attributes and slots through every level in between, which is
plumbing the middle components have no use for.

## Using it

A component watches the part of the state it needs, starting in `connectedCallback` and stopping
in `disconnectedCallback`:

```js
import { store } from "../store.js";

connectedCallback() {
  this.#unwatch = store.watch(
    (state) => state.projects,
    (projects) => {
      this.#projects = projects;
      this.#render();
    },
  );
}

disconnectedCallback() {
  this.#unwatch();
}
```

`watch(select, callback)` calls back straight away and then whenever `select(state)` returns
something different, compared with `Object.is`. It returns the function that stops watching.

`app.js` changes the state with `update(patch)`, which merges `patch` into the top level:

```js
store.update({ currentProjectSlug: event.detail.slug });
```

## The rules

**Components read the store; only `app.js` writes to it.** A component that wants something
changed raises a `composed` event as before, and `app.js` decides what that means for the state.
That keeps one place where state changes — the job a reducer does in Redux.

**Replace, never edit in place.** The state is frozen and replaced whole on every update, so a
part that did not change keeps its identity and its watchers stay quiet. The freeze is shallow:
pushing onto `state.projects.list` would not throw, but no watcher would see it either. Build a
new object for whatever changed.

**Import it by the same URL everywhere.** A module is one instance per URL, so `../store.js`
from a component and `./store.js` from `app.js` are the same store — but `/store.js?v=2`, or an
`import()` from outside the page such as a WebDriver script, gets a separate copy with its own
state.

## When to reach for it

Use the store for data that is shared across the screen, or that would otherwise be passed through
components that do not use it. Data a parent naturally owns — a lane's cards — is still better
as children, where `slotchange` gives the component its updates for free.

## What is in it

| Key | Shape | Watched by |
|---|---|---|
| `projects` | `{ status, list }` — `status` is `"loading"`, `"ready"` or `"unavailable"`; `list` is the projects as `GET /api/rest/v1/projects` returns them, except that pausing or resuming a project's AI agents replaces that project in the list with one whose `aiPaused` is changed, without fetching it again | `tv-project-switcher`, which also disables its chip while `status` is `"loading"`; `tv-project-settings`, which checks a name being typed against the list, and as the new project screen with no projects yet, labels its back link "Back to AI setup", since `/` then shows the project prompt; `tv-agents-bar`, which shows the selected project's AI agents; `tv-topbar`, which shows "Open project" when the selected project's `canBeOpened` is true; also `app.js`, which shows the selected project on the board, but not again when only its `aiPaused` or `canBeOpened` changed |
| `currentProjectSlug` | The slug from the `/projects/:slug` route, or `null` when no project is selected. Projects are selected by slug, not id: compare it with a project's `slug`. Left as it was on a route that names no project, such as `/settings`; on a fresh load it starts as the last project shown. Set before `projects` is `"ready"`, so it may briefly name a project that does not exist; once `app.js` knows, it shows the not-found screen and puts back the previous selection. Every non-null value is saved in localStorage under `taskavista.currentProjectSlug`, which is how `/` goes back to the last project | `tv-project-switcher`; `tv-agents-bar`; `tv-topbar`; also `app.js`, which saves it and shows that project on the board |
| `boardLoading` | `true` while `app.js` is fetching the selected project's lanes and tasks (`GET /api/rest/v1/projects/{projectId}/lanes` and `/tasks`, in parallel), otherwise `false`. The lanes and tasks themselves are not in the store: they go to the board as `tv-lane` children, each holding its `tv-card`s | `tv-project-switcher`, which disables its chip while it is `true`, so a switch cannot start before the last one has finished |

| `agents` | `{ status, list, runtimes, models }` — `status` is `"loading"`, `"ready"` or `"unavailable"`; `list`, `runtimes` and `models` are as `GET /api/rest/v1/agents`, `/runtimes` and `/models` return them. Loaded on start-up, and replaced whenever the Taskavista settings screen fetches the agents, which it does on opening and after every write | `tv-agent-chat`, which names the agents and offers them in a "New chat" tab; `tv-card`, which names the agent at work on its task; also `app.js`, which ends the chat of an agent no longer in the list |
| `chat` | `{ open, sessions, current }` — whether the agent chat shows, its tabs in order, and the `id` of the one showing (`null` with no tabs). A session is `{ id, agentId, number, messages, unread, waiting, agentSessionId, projectId }`: `agentId` is `null` while it is a "New chat" tab with no agent picked yet, `number` (`null` until then) numbers the agent's chats, one past its highest open one when the agent is picked, and is kept when another of them ends, so a tab's name stays as it is, `messages` are `{ from, text }` with `from` `"user"`, `"agent"`, or `"error"` for a message that got no reply (its `text` is why), `unread` counts the replies and errors not yet seen, cleared when its tab shows, `waiting` is `true` while a message sent through `sendChatMessage` has not been answered, which holds back the next one, `agentSessionId` is the session `sendChatMessage` gave the chat, `null` until its first message has been answered, and `projectId` is the project the chat started in, sent with every later message so the agent can reach its working directory, `null` until then or when it started in none. Only in the page, so a reload ends every chat. Ids count up from 1 for the page's lifetime | `tv-agent-chat`; `tv-topbar`, which marks its chat button while `open` and badges it with the sum of `unread` |

Add a row when a key is added.
