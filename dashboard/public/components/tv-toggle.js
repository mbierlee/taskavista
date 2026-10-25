/**
 * Taskavista
 *
 * An on/off switch.
 *
 * Author: Mike Bierlee <m.bierlee@lostmoment.com>
 * Copyright: 2026 Mike Bierlee
 * License: MIT. The full terms of the license can be found in the LICENSE.txt file.
 */

/* <tv-toggle checked>Label</tv-toggle>

   An on/off switch, labelled by its own content. `checked` is the state, as
   an attribute and as a property. A click anywhere on it, or Space or Enter,
   flips it.

   It is form-associated, so a disabled <fieldset> around it disables it as it
   would a native input, and it matches :disabled then.

   Events (bubbling and composed):
     toggle-change  detail { checked }  the user flipped it; setting
                    `checked` from code raises nothing */

import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-toggle.html");

export class TvToggle extends HTMLElement {
  static formAssociated = true;
  static observedAttributes = ["checked"];

  #internals;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#internals = this.attachInternals();
    this.#internals.role = "switch";

    this.addEventListener("click", () => this.#flip());
    this.addEventListener("keydown", (event) => {
      if (event.key === " " || event.key === "Enter") {
        event.preventDefault();
        this.#flip();
      }
    });
  }

  connectedCallback() {
    if (!this.matches(":disabled")) {
      this.tabIndex = 0;
    }
    this.#sync();
  }

  attributeChangedCallback() {
    this.#sync();
  }

  formDisabledCallback(disabled) {
    if (disabled) {
      this.removeAttribute("tabindex");
    } else {
      this.tabIndex = 0;
    }
    this.#internals.ariaDisabled = String(disabled);
  }

  get checked() {
    return this.hasAttribute("checked");
  }

  set checked(value) {
    this.toggleAttribute("checked", Boolean(value));
  }

  #flip() {
    if (this.matches(":disabled")) {
      return;
    }
    this.checked = !this.checked;
    this.dispatchEvent(
      new CustomEvent("toggle-change", {
        bubbles: true,
        composed: true,
        detail: { checked: this.checked },
      }),
    );
  }

  #sync() {
    this.#internals.ariaChecked = String(this.checked);
  }
}

customElements.define("tv-toggle", TvToggle);
