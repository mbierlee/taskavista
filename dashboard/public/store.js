/**
 * Taskavista
 *
 * The web UI's shared state.
 *
 * Author: Mike Bierlee <m.bierlee@lostmoment.com>
 * Copyright: 2026 Mike Bierlee
 * License: MIT. The full terms of the license can be found in the LICENSE.txt file.
 */

/* The app's shared state, for data that more than one part of the screen needs
   or that sits deep inside other components — a Redux-like store without the
   library.

   The state is one frozen object, replaced whole on every update, so a part of
   it that did not change keeps its identity and a watcher can tell. Components
   read it through watch(); only app.js writes to it. Changes still come up
   from the components as composed events, and app.js turns them into updates,
   so there is one place where state is changed. */

export class Store extends EventTarget {
  #state;

  constructor(initial) {
    super();
    this.#state = Object.freeze({ ...initial });
  }

  get state() {
    return this.#state;
  }

  /* Merges `patch` into the top level of the state. Replace a nested object
     rather than changing it in place, or watchers will not see the change. */
  update(patch) {
    this.#state = Object.freeze({ ...this.#state, ...patch });
    this.dispatchEvent(new Event("change"));
  }

  /* Calls `callback` with select(state) now, then again whenever that value
     changes. Returns the function that stops watching — call it from
     disconnectedCallback. */
  watch(select, callback) {
    let current = select(this.#state);
    callback(current);

    const listener = () => {
      const next = select(this.#state);
      if (!Object.is(next, current)) {
        current = next;
        callback(next);
      }
    };
    this.addEventListener("change", listener);
    return () => this.removeEventListener("change", listener);
  }
}

export const store = new Store({
  /* status is "loading", "ready" or "unavailable". */
  projects: { status: "loading", list: [] },
  /* The slug of the project the URL names (/projects/:slug), or null when
     none is selected. It is set from the route before the project list arrives, so
     until then it may name a project that does not exist. Once app.js knows,
     it puts the previous selection back. */
  currentProjectSlug: null,
  /* True while the lanes and tasks of the selected project are being fetched. */
  boardLoading: false,
  /* The ids of the projects whose AI agents are being paused or resumed, from
     the press of the button until the server has answered. */
  aiPausing: [],
  /* The AI agents, with the runtimes and models their names come from, as
     their REST endpoints return them. status is "loading", "ready" or
     "unavailable". */
  agents: { status: "loading", list: [], runtimes: [], models: [] },
  /* The agent chat: whether it shows, its tabs, and the session of the one
     showing. A session is { id, agentId, messages, unread, waiting,
     agentSessionId, projectId }, with agentId null while it is a "New chat"
     tab with no agent picked, and projectId the project the chat started in. Kept for the page's lifetime only, so a reload ends every
     chat. */
  chat: { open: false, sessions: [], current: null },
});
