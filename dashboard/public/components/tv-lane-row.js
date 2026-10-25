/**
 * Taskavista
 *
 * One lane in the project settings' list of lanes.
 *
 * Author: Mike Bierlee <m.bierlee@lostmoment.com>
 * Copyright: 2026 Mike Bierlee
 * License: MIT. The full terms of the license can be found in the LICENSE.txt file.
 */

/* <tv-lane-row name="To do" color="#8fa6ff" intake agents count="3 tasks">
   </tv-lane-row>

   One lane in the project settings' list: a handle to reorder it by, its
   name, its colour swatch, its three checkboxes, its task count and a button
   to remove it. It edits nothing itself, but says what was asked for; the
   list it is in owns the lanes, their order and the colour picker.

   The checkboxes follow the boolean attributes `intake` (new tasks can be
   created in the lane), `closing` (its tasks count as done) and `agents`
   (agents pick up its tasks). Its columns are the inherited `--lane-columns`
   and `--lane-gap`, so the list can line its head up with them. `count` is the text after the
   checkboxes, empty for none. `picking` marks the row whose colour the
   picker is choosing. The
   handle makes the row draggable while it is held; the list sets `dragging`,
   and `drop-before` or `drop-after` to show where a dragged row will land.

   It is form-associated, so the form it is in checks its name, which may not
   be blank, and a disabled <fieldset> around it disables it.

   Events (bubbling and composed):
     lane-rename  detail { name }  the name was typed in
     lane-recolor                  the swatch was clicked
     lane-remove                   the remove button was clicked
     lane-flag    detail { flag, checked }  a checkbox was ticked or
                                   cleared; `flag` is "intake", "closing" or
                                   "agents"
     lane-step    detail { step }  arrow up (-1) or down (1) on the handle,
                                   for anyone who cannot drag */

import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-lane-row.html");

export class TvLaneRow extends HTMLElement {
  static formAssociated = true;
  static observedAttributes = [
    "name",
    "color",
    "count",
    "picking",
    "intake",
    "closing",
    "agents",
  ];

  #internals;
  #handle;
  #name;
  #swatch;
  #flags;
  #count;
  #remove;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#internals = this.attachInternals();
    this.#internals.role = "listitem";

    this.#handle = root.querySelector(".handle");
    this.#name = root.querySelector(".name");
    this.#swatch = root.querySelector(".swatch");
    this.#flags = Object.fromEntries(
      [...root.querySelectorAll(".flag")].map((box) => [box.dataset.flag, box]),
    );
    this.#count = root.querySelector(".count");
    this.#remove = root.querySelector(".remove");

    this.#name.addEventListener("input", () => {
      this.#renderLabels();
      this.#syncValidity();
      this.#emit("lane-rename", { name: this.#name.value });
    });
    /* Enter would otherwise do nothing at all: the input is not in the form,
       so it does not submit it. Leaving the field says the name is done. */
    this.#name.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        this.#name.blur();
      }
    });
    this.#swatch.addEventListener("click", () => this.#emit("lane-recolor"));
    this.#remove.addEventListener("click", () => this.#emit("lane-remove"));
    for (const [flag, box] of Object.entries(this.#flags)) {
      box.addEventListener("change", () => {
        this.#emit("lane-flag", { flag, checked: box.checked });
      });
    }
    this.#handle.addEventListener("keydown", (event) => {
      const step = { ArrowUp: -1, ArrowDown: 1 }[event.key];
      if (step) {
        event.preventDefault();
        this.#emit("lane-step", { step });
      }
    });

    /* Only draggable while the handle is held, so dragging across the name
       still selects text. */
    this.#handle.addEventListener("pointerdown", () => {
      this.draggable = true;
    });
    for (const type of ["pointerup", "pointercancel", "dragend"]) {
      this.addEventListener(type, () => {
        this.draggable = false;
      });
    }
  }

  connectedCallback() {
    this.#renderLabels();
    this.#syncValidity();
  }

  attributeChangedCallback(name, _, value) {
    if (name === "name") {
      /* Only when it differs, so the caret stays put while typing. */
      if (this.#name.value !== (value ?? "")) {
        this.#name.value = value ?? "";
      }
      this.#renderLabels();
      this.#syncValidity();
    } else if (name === "color") {
      this.#swatch.style.setProperty("--swatch", value ?? "");
    } else if (name === "count") {
      this.#count.textContent = value ?? "";
    } else if (name === "picking") {
      this.#swatch.setAttribute("aria-expanded", value !== null);
    } else {
      this.#flags[name].checked = value !== null;
    }
  }

  formDisabledCallback(disabled) {
    for (const control of [
      this.#handle,
      this.#name,
      this.#swatch,
      ...Object.values(this.#flags),
      this.#remove,
    ]) {
      control.disabled = disabled;
    }
  }

  /* The swatch, for the colour picker to open under. */
  get swatch() {
    return this.#swatch;
  }

  /* Focuses one of the row's controls: "handle", "name", "swatch", one of
     the checkboxes by its flag, or "remove". */
  focusControl(control) {
    ({
      handle: this.#handle,
      name: this.#name,
      swatch: this.#swatch,
      ...this.#flags,
      remove: this.#remove,
    })[control]?.focus();
  }

  #renderLabels() {
    const label = this.#name.value || "new lane";
    this.#handle.setAttribute("aria-label", `Move ${label} (arrow up or down)`);
    this.#swatch.setAttribute("aria-label", `Color of ${label}`);
    this.#flags.intake.setAttribute(
      "aria-label",
      `New tasks can be created in ${label}`,
    );
    this.#flags.closing.setAttribute(
      "aria-label",
      `Tasks in ${label} count as done`,
    );
    this.#flags.agents.setAttribute(
      "aria-label",
      `Agents pick up tasks in ${label}`,
    );
    this.#remove.setAttribute("aria-label", `Remove ${label}`);
  }

  /* The input's own checks, reported as the row's, so the form's validation
     points at the input. */
  #syncValidity() {
    this.#internals.setValidity(
      this.#name.validity,
      this.#name.validationMessage,
      this.#name,
    );
  }

  #emit(type, detail = {}) {
    this.dispatchEvent(
      new CustomEvent(type, { bubbles: true, composed: true, detail }),
    );
  }
}

customElements.define("tv-lane-row", TvLaneRow);
