/* <tv-agents-bar></tv-agents-bar>

   The strip over the board of a project managed by AI agents, saying whether
   they are at work, with the button that pauses or resumes them. It takes no
   attributes: the project comes from the store, and the strip is hidden for
   a project that is not managed by AI agents, or when there is none. It sets
   `paused` on itself, for its styles.

   Events (bubbling and composed):
     agents-pause  detail { projectId, paused }  the button was pressed:
                   `paused` is what the project's agents should be now */

import { attachTemplate, loadTemplate } from "./template.js";
import { store } from "../store.js";

const template = await loadTemplate("tv-agents-bar.html");

export class TvAgentsBar extends HTMLElement {
  #project = null;
  #unwatch;
  #text;
  #button;
  #buttonText;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#text = root.querySelector(".text");
    this.#button = root.querySelector(".toggle");
    this.#buttonText = root.querySelector(".label-text");

    this.#button.addEventListener("click", () => this.#onToggle());
  }

  connectedCallback() {
    this.#unwatch = store.watch(
      (state) =>
        state.projects.list.find((p) => p.slug === state.currentProjectSlug) ??
        null,
      (project) => {
        this.#project = project;
        this.#render();
      },
    );
  }

  disconnectedCallback() {
    this.#unwatch();
  }

  #onToggle() {
    if (!this.#project) {
      return;
    }
    this.dispatchEvent(
      new CustomEvent("agents-pause", {
        bubbles: true,
        composed: true,
        detail: {
          projectId: this.#project.id,
          paused: !this.#project.aiPaused,
        },
      }),
    );
  }

  #render() {
    const project = this.#project;
    this.hidden = !project?.managedByAi;
    const paused = project?.aiPaused ?? false;
    this.toggleAttribute("paused", paused);
    this.#text.textContent = paused
      ? "AI agents are paused"
      : "AI agents are handling this project";
    this.#buttonText.textContent = paused ? "Resume agents" : "Pause agents";
  }
}

customElements.define("tv-agents-bar", TvAgentsBar);
