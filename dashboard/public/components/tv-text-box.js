/**
 * Taskavista
 *
 * A text box that grows with its text and commits on Enter.
 *
 * Author: Mike Bierlee <m.bierlee@lostmoment.com>
 * Copyright: 2026 Mike Bierlee
 * License: MIT. The full terms of the license can be found in the LICENSE.txt file.
 */

/* <tv-text-box label="Description" placeholder="…"></tv-text-box>

   A text box that grows with its text, where Enter commits what was written
   and Escape backs out. Shift+Enter starts a new line. What a commit or a
   cancel does is up to the caller, as is anything on losing focus, which it
   can follow with focusout. `value` is the text, and `disabled` disables
   the box.

   Events (bubbling and composed):
     text-commit  detail { value }  Enter was pressed
     text-cancel                    Escape was pressed */

import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-text-box.html");

export class TvTextBox extends HTMLElement {
  static observedAttributes = ["label", "placeholder", "disabled"];

  #textarea;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#textarea = root.querySelector("textarea");
    this.#textarea.addEventListener("input", () => this.#fit());
    /* A box that was hidden when its value was set had no height to fit
       then; it is shown before it takes the focus. */
    this.#textarea.addEventListener("focus", () => this.#fit());
    this.#textarea.addEventListener("keydown", (event) => this.#onKey(event));
  }

  attributeChangedCallback(name, _, value) {
    if (name === "label") {
      this.#textarea.setAttribute("aria-label", value ?? "");
    } else if (name === "disabled") {
      this.#textarea.disabled = value !== null;
    } else {
      this.#textarea.placeholder = value ?? "";
    }
  }

  get value() {
    return this.#textarea.value;
  }

  set value(text) {
    this.#textarea.value = text;
    this.#fit();
  }

  focus(options) {
    this.#textarea.focus(options);
  }

  /* An Enter that confirms an IME composition is not a commit. Both keys are
     taken, so an Escape here does not also close whatever the box is in. */
  #onKey(event) {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      this.#emit("text-commit", { value: this.value });
    } else if (event.key === "Escape") {
      event.preventDefault();
      this.#emit("text-cancel", {});
    }
  }

  /* Reset first, so it can shrink as well as grow. */
  #fit() {
    this.#textarea.style.height = "auto";
    this.#textarea.style.height = this.#textarea.scrollHeight + 2 + "px";
  }

  #emit(type, detail) {
    this.dispatchEvent(
      new CustomEvent(type, { bubbles: true, composed: true, detail }),
    );
  }
}

customElements.define("tv-text-box", TvTextBox);
