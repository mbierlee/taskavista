/* <tv-project-prompt first-run></tv-project-prompt>

   The screen where a person describes a project for an agent to suggest one.
   `first-run` is for when there are no projects yet, and it is shown in place
   of a board: its text speaks of the first project, and there is no board to
   go back to. Without it, it is the switcher's quick-create screen, with a
   link back to the board. "Set up manually" is an ordinary link to the new
   project screen.

   "Set up project" raises project-draft. The caller has the draft made,
   holding the screen with `generating` meanwhile, then opens it on the new
   project screen, or sets `error` to say why there is none. The error shows
   under the description, which is kept to be put right, until the next try.

   Events (bubbling and composed):
     project-draft  detail { description } */

import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-project-prompt.html");

export class TvProjectPrompt extends HTMLElement {
  static observedAttributes = ["first-run"];

  #back;
  #intro;
  #description;
  #setUp;
  #setUpLabel;
  #error;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#back = root.querySelector(".back");
    this.#intro = root.querySelector(".intro");
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

  attributeChangedCallback() {
    const firstRun = this.hasAttribute("first-run");
    this.#back.hidden = firstRun;
    const project = firstRun ? "your first project" : "the new project";
    this.#intro.textContent = `Describe ${project}. An agent suggests a name and lanes; you review them before anything is created.`;
    this.#description.setAttribute("aria-label", `Describe ${project}`);
  }

  connectedCallback() {
    this.setAttribute("role", "region");
    this.setAttribute("aria-label", "Set up a project");
  }

  focus() {
    this.#description.focus();
  }

  /* Empties the screen for a new project, unless a draft is still being made
     from what is there, which then carries on. */
  clear() {
    if (this.#description.disabled) {
      return;
    }
    this.#description.value = "";
    this.error = "";
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
