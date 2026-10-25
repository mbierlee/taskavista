/**
 * Taskavista
 *
 * The strip over the board saying whether a project's AI agents are at work.
 *
 * Author: Mike Bierlee <m.bierlee@lostmoment.com>
 * Copyright: 2026 Mike Bierlee
 * License: MIT. The full terms of the license can be found in the LICENSE.txt file.
 */

/* <tv-agents-bar></tv-agents-bar>

   The strip over the board of a project managed by AI agents, saying whether
   they are at work, with the button that pauses or resumes them. It takes no
   attributes: the project comes from the store, and the strip is hidden for
   a project that is not managed by AI agents, none of whose lanes on the
   board the store's `boardAgentLanes` says the agents pick up, or when there
   is none. It sets
   `paused` on itself, for its styles. Its button is disabled while the
   store's `aiPausing` holds the project, as its last press is being saved,
   and the second and later clicks of a double or triple click are ignored.

   Events (bubbling and composed):
     agents-pause  detail { projectId, paused }  the button was pressed:
                   `paused` is what the project's agents should be now */

import { attachTemplate, loadTemplate } from "./template.js";
import { store } from "../store.js";

const template = await loadTemplate("tv-agents-bar.html");

export class TvAgentsBar extends HTMLElement {
  #project = null;
  #pausing = [];
  #agentLanes = false;
  #unwatch;
  #unwatchPausing;
  #unwatchAgentLanes;
  #text;
  #button;
  #buttonText;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#text = root.querySelector(".text");
    this.#button = root.querySelector(".toggle");
    this.#buttonText = root.querySelector(".label-text");

    /* A press means the opposite of what the strip shows, which the first
       click of a double click has already changed, so only that first click
       counts. The button is also disabled while a press is being saved, for
       a second press that comes before the server has answered. */
    this.#button.addEventListener("click", (event) => {
      if (event.detail <= 1) {
        this.#onToggle();
      }
    });
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
    this.#unwatchPausing = store.watch(
      (state) => state.aiPausing,
      (pausing) => {
        this.#pausing = pausing;
        this.#render();
      },
    );
    this.#unwatchAgentLanes = store.watch(
      (state) => state.boardAgentLanes,
      (agentLanes) => {
        this.#agentLanes = agentLanes;
        this.#render();
      },
    );
  }

  disconnectedCallback() {
    this.#unwatch();
    this.#unwatchPausing();
    this.#unwatchAgentLanes();
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
    this.hidden = !project || !this.#agentLanes;
    const paused = project?.aiPaused ?? false;
    this.toggleAttribute("paused", paused);
    this.#text.textContent = paused
      ? "AI agents are paused"
      : "AI agents are handling this project";
    this.#buttonText.textContent = paused ? "Resume agents" : "Pause agents";
    this.#button.disabled = Boolean(
      project && this.#pausing.includes(project.id),
    );
  }
}

customElements.define("tv-agents-bar", TvAgentsBar);
