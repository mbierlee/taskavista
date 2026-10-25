/**
 * Taskavista
 *
 * The values a tv-chip-list suggests for what is typed in it.
 *
 * Author: Mike Bierlee <m.bierlee@lostmoment.com>
 * Copyright: 2026 Mike Bierlee
 * License: MIT. The full terms of the license can be found in the LICENSE.txt file.
 */

/* <tv-chip-suggestions></tv-chip-suggestions>

   The values a tv-chip-list offers for what is being typed in it, each with
   an optional hint, and a "+ Create" row for the typed text when it is new.
   One row is active at a time, the first when shown; the keyboard stays in
   the chip list's text box, which moves the active row with `move()` and
   picks it with `pick()`. A row is also picked by clicking it, without
   taking the focus from the text box.

   Events (bubbling and composed):
     suggestion-pick  detail { value }  a row was picked; for "+ Create",
                      the typed text */

import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-chip-suggestions.html");

export class TvChipSuggestions extends HTMLElement {
  #list;

  /* The value each row stands for, in the order shown. */
  #values = [];
  #active = 0;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#list = root.querySelector(".list");
    this.#list.addEventListener("pointerdown", (event) =>
      event.preventDefault(),
    );
    this.#list.addEventListener("click", (event) => {
      const row = event.target.closest(".option");
      if (row) {
        this.#active = Number(row.dataset.index);
        this.pick();
      }
    });
    this.#list.addEventListener("pointermove", (event) => {
      const row = event.target.closest(".option");
      if (row) {
        this.#activate(Number(row.dataset.index));
      }
    });
  }

  /* `items` are { value, hint } and `create` is the text to offer creating,
     or "" for none. Hides itself when that leaves nothing to show. */
  show(items, create) {
    const rows = items.map(({ value, hint }) => {
      const row = this.#row();
      const text = document.createElement("span");
      text.className = "value";
      text.textContent = value;
      row.append(text);
      if (hint) {
        const hintEl = document.createElement("span");
        hintEl.className = "hint";
        hintEl.textContent = hint;
        row.append(hintEl);
      }
      return row;
    });
    if (create) {
      const row = this.#row();
      row.classList.add("create");
      row.textContent = `+ Create “${create}”`;
      rows.push(row);
    }

    this.#values = [...items.map((item) => item.value), ...(create ? [create] : [])];
    rows.forEach((row, index) => (row.dataset.index = index));
    this.#list.replaceChildren(...rows);
    this.hidden = rows.length === 0;
    this.#activate(0);
  }

  /* Moves the active row by `step`, wrapping round at either end. */
  move(step) {
    const count = this.#values.length;
    if (count > 0) {
      this.#activate((this.#active + step + count) % count);
    }
  }

  /* Picks the active row. False when there is none to pick. */
  pick() {
    if (this.hidden || this.#values.length === 0) {
      return false;
    }
    this.dispatchEvent(
      new CustomEvent("suggestion-pick", {
        bubbles: true,
        composed: true,
        detail: { value: this.#values[this.#active] },
      }),
    );
    return true;
  }

  #row() {
    const row = document.createElement("div");
    row.className = "option";
    row.setAttribute("role", "option");
    return row;
  }

  #activate(index) {
    this.#active = index;
    for (const row of this.#list.children) {
      const active = Number(row.dataset.index) === index;
      row.setAttribute("aria-selected", String(active));
      if (active) {
        this.#reveal(row);
      }
    }
  }

  /* Scrolls the list alone, where scrollIntoView() would scroll the dialog
     and the page around it too. */
  #reveal(row) {
    const list = this.#list;
    const bottom = row.offsetTop + row.offsetHeight;
    if (row.offsetTop < list.scrollTop) {
      list.scrollTop = row.offsetTop;
    } else if (bottom > list.scrollTop + list.clientHeight) {
      list.scrollTop = bottom - list.clientHeight;
    }
  }
}

customElements.define("tv-chip-suggestions", TvChipSuggestions);
