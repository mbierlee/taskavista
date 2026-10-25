/**
 * Taskavista
 *
 * One value in a tv-chip-list.
 *
 * Author: Mike Bierlee <m.bierlee@lostmoment.com>
 * Copyright: 2026 Mike Bierlee
 * License: MIT. The full terms of the license can be found in the LICENSE.txt file.
 */

/* <tv-chip>finance</tv-chip>

   One value in a tv-chip-list, shown as its own text content, with a ✕ that
   asks for it to be removed. It removes nothing itself. `disabled` disables
   the ✕.

   Events (bubbling and composed):
     chip-remove  the ✕ was pressed */

import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-chip.html");

export class TvChip extends HTMLElement {
  static observedAttributes = ["disabled"];

  #remove;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#remove = root.querySelector(".remove");
    this.#remove.addEventListener("click", () =>
      this.dispatchEvent(
        new CustomEvent("chip-remove", { bubbles: true, composed: true }),
      ),
    );
    root
      .querySelector("slot")
      .addEventListener("slotchange", () => this.#nameRemove());
  }

  connectedCallback() {
    this.#nameRemove();
  }

  attributeChangedCallback() {
    this.#remove.disabled = this.hasAttribute("disabled");
  }

  #nameRemove() {
    this.#remove.setAttribute("aria-label", `Remove ${this.textContent}`);
  }
}

customElements.define("tv-chip", TvChip);
