/* <tv-project-prompt></tv-project-prompt>

   The screen where a person describes a project for an agent to suggest one.
   For now it is shown only at first run, in place of a board while there are
   no projects, so its text speaks of the first project. "Set up manually" is
   an ordinary link to the new project screen.

   "Set up project" raises project-draft. The caller has the draft made,
   holding the screen with `generating` meanwhile, then opens it on the new
   project screen, or sets `error` to say why there is none. The error shows
   under the description, which is kept to be put right, until the next try.

   Events (bubbling and composed):
     project-draft  detail { description } */

import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-project-prompt.html");

export class TvProjectPrompt extends HTMLElement {
  #description;
  #setUp;
  #setUpLabel;
  #error;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#description = root.querySelector("textarea");
    this.#setUp = root.querySelector(".set-up");
    this.#setUpLabel = root.querySelector(".set-up-label");
    this.#error = root.querySelector(".field-error");

    this.#description.addEventListener("input", () => this.#updateSetUp());
    // Enter sets the project up, as the button would; Shift+Enter is left to add a newline.
    this.#description.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" || event.shiftKey || event.isComposing) {
        return;
      }
      event.preventDefault();
      this.#setUp.click();
    });
    this.#setUp.addEventListener("click", () =>
      this.dispatchEvent(
        new CustomEvent("project-draft", {
          bubbles: true,
          composed: true,
          detail: { description: this.#description.value.trim() },
        }),
      ),
    );
  }

  connectedCallback() {
    this.setAttribute("role", "region");
    this.setAttribute("aria-label", "Set up a project");
  }

  focus() {
    this.#description.focus();
  }

  set generating(value) {
    this.#description.disabled = Boolean(value);
    if (value) {
      this.error = "";
    } else {
      this.#updateSetUp();
    }
  }

  set error(message) {
    this.#error.textContent = message;
    this.#error.hidden = !message;
    this.#description.setAttribute("aria-invalid", String(Boolean(message)));
    this.#updateSetUp();
  }

  /* The textarea is disabled only while a draft is being made. */
  #updateSetUp() {
    const generating = this.#description.disabled;
    this.#setUp.disabled = generating || this.#description.value.trim() === "";
    const failed = !this.#error.hidden;
    this.#setUpLabel.textContent = generating
      ? "Setting up"
      : failed
        ? "Try again"
        : "Set up project";
    if (generating) {
      const dots = document.createElement("span");
      dots.className = "dots";
      dots.setAttribute("aria-hidden", "true");
      dots.innerHTML = "<span>.</span><span>.</span><span>.</span>";
      this.#setUpLabel.append(dots);
    }
  }
}

customElements.define("tv-project-prompt", TvProjectPrompt);
