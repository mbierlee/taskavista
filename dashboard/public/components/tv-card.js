/* <tv-card task-id="t1" done selected>Write the onboarding email</tv-card>

   The description is the element's own text content, so a card reads the same
   in the light DOM as it does on the board. Styling lives in the shadow root;
   the colour tokens from app.css reach it because custom properties inherit.
   `selected` marks the card whose task is open in the details panel, and
   `added` plays the glow of a task just added, then removes itself.

   Events (bubbling and composed):
     task-open  detail { taskId }  the card was clicked, or Enter or Space
                pressed on it. A drag does not end in a click. */

import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-card.html");

export class TvCard extends HTMLElement {
  constructor() {
    super();
    attachTemplate(this, template);

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

  get added() {
    return this.hasAttribute("added");
  }

  set added(value) {
    this.toggleAttribute("added", Boolean(value));
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
