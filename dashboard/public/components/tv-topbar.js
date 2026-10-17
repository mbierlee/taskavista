/* <tv-topbar></tv-topbar>

   The board's chrome: wordmark, project switcher and search. The switcher
   finds its own data in the store, so the topbar passes nothing along; the
   `no-switcher` attribute hides it, for a screen about no project, and the
   "Open project" button with it. That button opens the current project's page
   in a tab of its own, and shows only for a project that can be opened. The
   `settings` attribute marks the gear, which links to the Taskavista
   settings, as the screen showing. The chat button shows or hides the agent
   chat, and watches the store's `chat` to mark itself while it shows and to
   count the replies not yet read. The
   search is in the markup per the mockup but hidden and inert for now — the
   results screen it opens is out of scope.

   Events (bubbling and composed):
     chat-toggle  the chat button was pressed */

import { attachTemplate, loadTemplate } from "./template.js";
import "./tv-project-switcher.js";
import { store } from "../store.js";

const template = await loadTemplate("tv-topbar.html");

export class TvTopbar extends HTMLElement {
  static observedAttributes = ["settings"];

  #gear;
  #chat;
  #badge;
  #open;
  #unwatch = [];

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#gear = root.querySelector(".gear");
    this.#chat = root.querySelector(".chat");
    this.#badge = root.querySelector(".badge");
    this.#open = root.querySelector(".open");

    this.#chat.addEventListener("click", () =>
      this.dispatchEvent(
        new CustomEvent("chat-toggle", { bubbles: true, composed: true }),
      ),
    );
  }

  attributeChangedCallback() {
    if (this.hasAttribute("settings")) {
      this.#gear.setAttribute("aria-current", "page");
    } else {
      this.#gear.removeAttribute("aria-current");
    }
  }

  connectedCallback() {
    this.setAttribute("role", "banner");
    this.#unwatch = [
      store.watch(
        (state) => state.chat,
        (chat) => this.#renderChat(chat),
      ),
      store.watch(
        (state) =>
          state.projects.list.find(
            (p) => p.slug === state.currentProjectSlug,
          ) ?? null,
        (project) => this.#renderOpen(project),
      ),
    ];
  }

  disconnectedCallback() {
    for (const unwatch of this.#unwatch) {
      unwatch();
    }
  }

  /* The page is served out of the working directory, which is named after
     the slug (see app.d). */
  #renderOpen(project) {
    this.#open.hidden = !project?.canBeOpened;
    if (project?.canBeOpened) {
      this.#open.href = `/working-dirs/${encodeURIComponent(project.slug)}/index.html`;
    } else {
      this.#open.removeAttribute("href");
    }
  }

  #renderChat({ open, sessions }) {
    const unread = sessions.reduce((sum, s) => sum + s.unread, 0);
    this.#chat.setAttribute("aria-expanded", String(open));
    this.#chat.setAttribute(
      "aria-label",
      unread === 0 ? "Agent chat" : `Agent chat, ${unread} unread`,
    );
    this.#badge.textContent = String(unread);
    this.#badge.hidden = unread === 0;
  }
}

customElements.define("tv-topbar", TvTopbar);
