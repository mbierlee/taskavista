/* <tv-chip-list label="Labels" placeholder="Add label…" lowercase></tv-chip-list>

   A field holding a list of short texts, each a tv-chip with a ✕ to remove
   it, and a text box after them to add another. `values` is the list, set
   and read from script; `options` are the values to suggest, as
   { value, hint }. `label` names the text box, `placeholder` is its
   placeholder, and `lowercase` lowercases what is typed, for values that
   are stored lowercase, so that a chip shows what will be stored.

   Typing shows the options that contain the text, those starting with it
   first, and offers creating the text as it is unless an option or a value
   already has it, whatever its case. Up and Down move through the
   suggestions, Enter adds the one picked, Escape closes them, and Backspace
   in an empty box removes the last value. Text left in the box is not a
   value until it is added.

   It is form-associated, so a disabled <fieldset> around it disables it as
   it would a native input.

   Events (bubbling and composed):
     chips-change  detail { values }  the user added or removed a value;
                   setting `values` from code raises nothing */

import { attachTemplate, loadTemplate } from "./template.js";
import "./tv-chip.js";
import "./tv-chip-suggestions.js";

const template = await loadTemplate("tv-chip-list.html");

export class TvChipList extends HTMLElement {
  static formAssociated = true;
  static observedAttributes = ["label", "placeholder"];

  #chips;
  #draft;
  #suggestions;

  #values = [];
  #options = [];

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.attachInternals();
    this.#chips = root.querySelector(".chips");
    this.#draft = root.querySelector(".draft");
    this.#suggestions = root.querySelector("tv-chip-suggestions");

    // Also what a click on a <label> around it arrives as.
    this.addEventListener("click", () => {
      if (!this.#draft.disabled) {
        this.#draft.focus();
      }
    });
    this.#draft.addEventListener("input", () => this.#suggest());
    this.#draft.addEventListener("keydown", (event) => this.#onKey(event));
    this.#draft.addEventListener("blur", () => this.#closeSuggestions());

    // Both are this element's to act on; nothing above it listens for them.
    root.addEventListener("chip-remove", (event) => {
      event.stopPropagation();
      this.#remove(Number(event.target.dataset.index));
    });
    root.addEventListener("suggestion-pick", (event) => {
      event.stopPropagation();
      this.#add(event.detail.value);
    });
  }

  attributeChangedCallback(name, _old, value) {
    if (name === "label") {
      this.#draft.setAttribute("aria-label", value ?? "");
    } else {
      this.#draft.placeholder = value ?? "";
    }
  }

  formDisabledCallback(disabled) {
    this.#draft.disabled = disabled;
    for (const chip of this.#chips.children) {
      chip.toggleAttribute("disabled", disabled);
    }
    this.#closeSuggestions();
  }

  get values() {
    return [...this.#values];
  }

  set values(values) {
    this.#values = [...values];
    this.#draft.value = "";
    this.#closeSuggestions();
    this.#renderChips();
  }

  set options(options) {
    this.#options = [...options];
  }

  #onKey(event) {
    const open = !this.#suggestions.hidden;
    switch (event.key) {
      case "ArrowDown":
      case "ArrowUp":
        event.preventDefault();
        if (open) {
          this.#suggestions.move(event.key === "ArrowDown" ? 1 : -1);
        } else {
          this.#suggest();
        }
        break;
      case "Enter":
        event.preventDefault();
        if (open) {
          this.#suggestions.pick();
        } else {
          this.#addTyped();
        }
        break;
      case "Escape":
        // Otherwise the Escape also closes a dialog the list is in.
        if (open) {
          event.preventDefault();
          this.#closeSuggestions();
        }
        break;
      case "Backspace":
        if (this.#draft.value === "" && this.#values.length > 0) {
          event.preventDefault();
          this.#remove(this.#values.length - 1);
        }
        break;
    }
  }

  #suggest() {
    const text = this.#typed();
    if (text === "") {
      this.#closeSuggestions();
      return;
    }

    const key = text.toLowerCase();
    const taken = new Set(this.#values.map((value) => value.toLowerCase()));
    const matches = this.#options.filter(({ value }) => {
      const lower = value.toLowerCase();
      return !taken.has(lower) && lower.includes(key);
    });
    const starts = matches.filter(({ value }) =>
      value.toLowerCase().startsWith(key),
    );
    const contains = matches.filter((option) => !starts.includes(option));
    const known =
      taken.has(key) ||
      this.#options.some(({ value }) => value.toLowerCase() === key);

    this.#suggestions.show([...starts, ...contains], known ? "" : text);
    this.#draft.ariaExpanded = String(!this.#suggestions.hidden);
  }

  #closeSuggestions() {
    this.#suggestions.hidden = true;
    this.#draft.ariaExpanded = "false";
  }

  /* With the suggestions closed, Enter adds the option the text names, in
     the option's own case, or else the text as it is. */
  #addTyped() {
    const text = this.#typed();
    if (text === "") {
      return;
    }
    const key = text.toLowerCase();
    const option = this.#options.find(
      ({ value }) => value.toLowerCase() === key,
    );
    this.#add(option?.value ?? text);
  }

  #typed() {
    const text = this.#draft.value.trim();
    return this.hasAttribute("lowercase") ? text.toLowerCase() : text;
  }

  #add(value) {
    const key = value.toLowerCase();
    this.#draft.value = "";
    this.#closeSuggestions();
    if (this.#values.some((existing) => existing.toLowerCase() === key)) {
      return;
    }
    this.#values = [...this.#values, value];
    this.#renderChips();
    this.#changed();
  }

  #remove(index) {
    this.#values = this.#values.filter((_, i) => i !== index);
    this.#renderChips();
    this.#draft.focus();
    this.#changed();
  }

  #renderChips() {
    const disabled = this.#draft.disabled;
    this.#chips.replaceChildren(
      ...this.#values.map((value, index) => {
        const chip = document.createElement("tv-chip");
        chip.textContent = value;
        chip.dataset.index = index;
        chip.toggleAttribute("disabled", disabled);
        return chip;
      }),
    );
  }

  #changed() {
    this.dispatchEvent(
      new CustomEvent("chips-change", {
        bubbles: true,
        composed: true,
        detail: { values: this.values },
      }),
    );
  }
}

customElements.define("tv-chip-list", TvChipList);
