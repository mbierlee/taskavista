/**
 * Taskavista
 *
 * A lane on the board, with its cards and its "+ Add a task".
 *
 * Author: Mike Bierlee <m.bierlee@lostmoment.com>
 * Copyright: 2026 Mike Bierlee
 * License: MIT. The full terms of the license can be found in the LICENSE.txt file.
 */

/* <tv-lane lane-id="todo" name="To do" color="#8fa6ff" can-add marks-done> ...cards... </tv-lane>

   A lane owns everything that is not board data: its heading, the task count,
   the drop slot and the "add a task" composer. The board only ever supplies
   <tv-card> children, says where the drop slot goes, and listens for the
   events below. `can-add` exists because a project's rule may limit new
   tasks to its first lane. A lane whose tasks are done (`marks-done`) has a
   "Clear" button in its heading, shown while it holds any cards.

   Events (all bubbling and composed):
     task-add     detail { lane, description }  a description was submitted in the composer
     lane-compose detail { lane, open }         the composer opened or closed
     lane-change  detail { lane, count }        the cards in the lane changed
     lane-clear   detail { lane }               "Clear" was confirmed */

import { attachTemplate, loadTemplate } from "./template.js";
import "./tv-text-box.js";

const template = await loadTemplate("tv-lane.html");

export class TvLane extends HTMLElement {
  static observedAttributes = ["name", "color", "can-add"];

  #slot;
  #name;
  #count;
  #clear;
  #add;
  #compose;

  /* Marks where a dragged card will land. It goes between cards, which are
     light-DOM children, so it has to be one too; the lane is the only thing
     that adds or moves it. Not being a tv-card, it stays out of `cards` and
     the count. */
  #dropSlot = Object.assign(document.createElement("div"), {
    className: "drop-slot",
  });

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#slot = root.querySelector("slot");
    this.#name = root.querySelector(".name");
    this.#count = root.querySelector(".count");
    this.#clear = root.querySelector(".clear");
    this.#add = root.querySelector(".add");
    this.#compose = root.querySelector(".compose");

    /* The count follows the cards the board hands over, so nothing has to
       keep a separate tally in sync. */
    this.#slot.addEventListener("slotchange", () => this.#renderCount());

    this.#clear.addEventListener("click", () => this.#onClear());
    this.#add.addEventListener("click", () => this.startComposing());
    /* The composer stays open on Enter, so several tasks can be added in a
       row. */
    this.#compose.addEventListener("text-commit", (event) => {
      event.stopPropagation();
      this.#submit();
    });
    this.#compose.addEventListener("text-cancel", (event) => {
      event.stopPropagation();
      this.#compose.value = "";
      this.stopComposing();
    });
    this.#compose.addEventListener("focusout", () => {
      this.#submit();
      this.stopComposing();
    });
  }

  connectedCallback() {
    this.setAttribute("role", "group");
    this.#render();
  }

  attributeChangedCallback(name) {
    if (name === "can-add" && !this.canAdd) {
      this.stopComposing();
    }
    this.#render();
  }

  get laneId() {
    return this.getAttribute("lane-id");
  }

  get canAdd() {
    return this.hasAttribute("can-add");
  }

  set canAdd(value) {
    this.toggleAttribute("can-add", Boolean(value));
  }

  get cards() {
    return this.#slot.assignedElements().filter((el) => el.matches("tv-card"));
  }

  get composing() {
    return !this.#compose.hidden;
  }

  /* Shows the drop slot just above `before`, one of this lane's cards, or
     after the last card when `before` is null. Only the slot moves, never a
     card, so a drag in progress is not interrupted. */
  showDropSlot(before) {
    if (
      this.#dropSlot.parentNode === this &&
      this.#dropSlot.nextElementSibling === before
    ) {
      return;
    }
    this.insertBefore(this.#dropSlot, before);
  }

  hideDropSlot() {
    this.#dropSlot.remove();
  }

  startComposing() {
    if (this.composing || !this.canAdd) {
      return;
    }
    this.#add.hidden = true;
    this.#compose.hidden = false;
    this.#compose.focus();
    this.#emit("lane-compose", { open: true });
  }

  stopComposing() {
    if (!this.composing) return;
    this.#compose.value = "";
    this.#compose.hidden = true;
    this.#add.hidden = false;
    this.#emit("lane-compose", { open: false });
  }

  /* Cleared before the event is raised: the board may move focus while it
     re-renders, and the blur handler would otherwise submit the same
     description a second time. */
  #submit() {
    const description = this.#compose.value.trim();
    this.#compose.value = "";
    if (description) this.#emit("task-add", { description });
  }

  #onClear() {
    const count = this.cards.length;
    const name = this.getAttribute("name") ?? "";
    if (
      !confirm(
        `Delete ${count === 1 ? "the 1 task" : `all ${count} tasks`} in “${name}”? This cannot be undone.`,
      )
    ) {
      return;
    }
    this.#emit("lane-clear", {});
  }

  #emit(type, detail) {
    this.dispatchEvent(
      new CustomEvent(type, {
        bubbles: true,
        composed: true,
        detail: { lane: this.laneId, ...detail },
      }),
    );
  }

  #render() {
    const name = this.getAttribute("name") ?? "";
    this.#name.textContent = name;
    this.setAttribute("aria-label", name);
    this.style.setProperty("--lane-color", this.getAttribute("color") ?? "");
    this.#renderCount();
  }

  /* The board keeps a running total, so a change is announced rather than
     left for it to discover. */
  #renderCount() {
    const count = this.cards.length;
    this.#clear.hidden = count === 0;
    if (this.#count.textContent === String(count)) return;
    this.#count.textContent = count;
    this.#emit("lane-change", { count });
  }
}

customElements.define("tv-lane", TvLane);
