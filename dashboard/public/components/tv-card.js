/**
 * Taskavista
 *
 * A task's card on the board.
 *
 * Author: Mike Bierlee <m.bierlee@lostmoment.com>
 * Copyright: 2026 Mike Bierlee
 * License: MIT. The full terms of the license can be found in the LICENSE.txt file.
 */

/* <tv-card task-id="t1" done selected working-agent-id="a1">Write the onboarding email</tv-card>

   The description is the element's own text content, so a card reads the same
   in the light DOM as it does on the board. Styling lives in the shadow root;
   the colour tokens from app.css reach it because custom properties inherit.
   `selected` marks the card whose task is open in the details panel, and
   `added` plays the glow of a task just added, then removes itself. A
   description longer than six lines is cut off with its bottom faded out.
   `working-agent-id` is the AI agent at work on the task, the task scheduler
   included, which sweeps its lane's colour along the card's border and names the agent
   under the description; its name comes from the store's `agents`.

   Events (bubbling and composed):
     task-open  detail { taskId }  the card was clicked, or Enter or Space
                pressed on it. A drag does not end in a click. */

import { store } from "../store.js";
import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-card.html");

export class TvCard extends HTMLElement {
  static observedAttributes = ["working-agent-id"];

  #description;
  #agent;
  #agents = [];
  #unwatch = null;

  constructor() {
    super();
    attachTemplate(this, template);
    this.#description = this.shadowRoot.querySelector(".description");
    this.#agent = this.shadowRoot.querySelector(".agent");

    /* The resize catches most changes, but not text that grows while the box
       is already at its cap, hence the mutation observer too. */
    const check = () => this.#checkClipped();
    new ResizeObserver(check).observe(this.#description);
    new MutationObserver(check).observe(this, {
      characterData: true,
      childList: true,
      subtree: true,
    });

    this.addEventListener("click", () => this.#open());
    this.addEventListener("keydown", (event) => {
      if (event.target === this && (event.key === "Enter" || event.key === " ")) {
        event.preventDefault();
        this.#open();
      }
    });
    this.addEventListener("animationend", () => this.removeAttribute("added"));
    this.addEventListener("animationcancel", () => this.removeAttribute("added"));
  }

  connectedCallback() {
    /* Cards are the drag source; the board listens for the events they raise. */
    this.draggable = true;
    this.tabIndex = 0;
    this.setAttribute("role", "button");
    this.#unwatch = store.watch(
      (state) => state.agents.list,
      (list) => {
        this.#agents = list;
        this.#renderAgent();
      },
    );
  }

  disconnectedCallback() {
    this.#unwatch?.();
    this.#unwatch = null;
  }

  attributeChangedCallback() {
    this.#renderAgent();
  }

  get taskId() {
    return this.getAttribute("task-id");
  }

  set taskId(value) {
    this.setAttribute("task-id", value);
  }

  get done() {
    return this.hasAttribute("done");
  }

  set done(value) {
    this.toggleAttribute("done", Boolean(value));
  }

  get selected() {
    return this.hasAttribute("selected");
  }

  set selected(value) {
    this.toggleAttribute("selected", Boolean(value));
  }

  get workingAgentId() {
    return this.getAttribute("working-agent-id");
  }

  set workingAgentId(value) {
    if (value) {
      this.setAttribute("working-agent-id", value);
    } else {
      this.removeAttribute("working-agent-id");
    }
  }

  get added() {
    return this.hasAttribute("added");
  }

  set added(value) {
    this.toggleAttribute("added", Boolean(value));
  }

  /* An agent the store does not know yet, such as one added since the agents
     were loaded, is shown unnamed until it does. */
  #renderAgent() {
    const id = this.workingAgentId;
    this.#agent.hidden = id === null;
    if (id === null) {
      this.removeAttribute("title");
      return;
    }
    const name = this.#agents.find((a) => a.id === id)?.name ?? "An AI agent";
    this.#agent.querySelector(".name").textContent = name;
    this.title = `${name} is working on this`;
  }

  #checkClipped() {
    const box = this.#description;
    box.classList.toggle("clipped", box.scrollHeight > box.clientHeight);
  }

  #open() {
    this.dispatchEvent(
      new CustomEvent("task-open", {
        bubbles: true,
        composed: true,
        detail: { taskId: this.taskId },
      }),
    );
  }
}

customElements.define("tv-card", TvCard);
