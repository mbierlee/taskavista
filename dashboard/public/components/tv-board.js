/* <tv-board name="Website relaunch"> ...lanes... </tv-board>

   The board owns the one piece of behaviour no single lane can: dragging a
   card from one lane to another. It holds no data — it reports the move and lets the caller decide.
   Over its head sits a tv-agents-bar, whose agents-pause event comes up
   through the board.

   Events (bubbling and composed):
     task-move  detail { taskId, lane, before }  a card was dropped in a new
                place: into the lane with id `lane`, just above the card
                whose task id is `before`, or at the bottom when `before` is
                null. `lane` may be the lane the card is already in. */

import { attachTemplate, loadTemplate } from "./template.js";
import "./tv-agents-bar.js";

const template = await loadTemplate("tv-board.html");

export class TvBoard extends HTMLElement {
  static observedAttributes = ["name"];

  #slot;
  #title;
  #count;

  /* The card being dragged, and where it would land if dropped now: a lane
     and the card it would go above (null for the bottom). View state, so the
     board keeps it to itself. */
  #dragging = null;
  #target = null;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#slot = root.querySelector("slot");
    this.#title = root.querySelector(".title");
    this.#count = root.querySelector(".count");

    this.#slot.addEventListener("slotchange", () => this.#renderCount());
    /* Lanes announce their own total whenever their cards change. */
    this.addEventListener("lane-change", () => this.#renderCount());

    /* Lanes and cards are light-DOM children, so their drag events reach
       the host by bubbling. */
    this.addEventListener("dragstart", (event) => this.#onDragStart(event));
    this.addEventListener("dragover", (event) => this.#onDragOver(event));
    this.addEventListener("drop", (event) => this.#onDrop(event));
    this.addEventListener("dragleave", (event) => this.#onDragLeave(event));
    this.addEventListener("dragend", () => this.#clearDragState());
  }

  connectedCallback() {
    this.setAttribute("role", "region");
    this.#render();
  }

  attributeChangedCallback() {
    this.#render();
  }

  get name() {
    return this.getAttribute("name") ?? "";
  }

  set name(value) {
    this.setAttribute("name", value);
  }

  get lanes() {
    return this.#slot.assignedElements().filter((el) => el.matches("tv-lane"));
  }

  get taskCount() {
    return this.lanes.reduce((total, lane) => total + lane.cards.length, 0);
  }

  /* ---------- dragging ---------- */

  #onDragStart(event) {
    const card = event.target.closest("tv-card");
    if (!card) {
      return;
    }

    this.#dragging = card;
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", card.taskId);

    /* Applied after the drag image is captured, so the lifted card is not skewed. */
    requestAnimationFrame(() => card.setAttribute("dragging", ""));
  }

  #onDragOver(event) {
    if (!this.#dragging) {
      return;
    }
    const lane = this.#laneAt(event);
    if (!lane) {
      return;
    }

    event.preventDefault();
    event.dataTransfer.dropEffect = "move";

    const before = this.#cardBelow(lane, event.clientY);
    for (const other of this.lanes) {
      if (other !== lane) {
        other.hideDropSlot();
      }
    }
    lane.showDropSlot(before);
    this.#target = { lane, before };
  }

  /* Over the gaps and padding around the lanes, the nearest lane, so there is
     nowhere on the board that a card cannot be dropped. */
  #laneAt(event) {
    const lane = event.target.closest("tv-lane");
    if (lane) {
      return lane;
    }

    let nearest = null;
    let nearestDistance = Infinity;
    for (const candidate of this.lanes) {
      const box = candidate.getBoundingClientRect();
      const dx = Math.max(
        box.left - event.clientX,
        0,
        event.clientX - box.right,
      );
      const dy = Math.max(
        box.top - event.clientY,
        0,
        event.clientY - box.bottom,
      );
      const distance = Math.hypot(dx, dy);
      if (distance < nearestDistance) {
        nearest = candidate;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  /* null means the bottom. The choice is stable while the slot shifts the cards: a card the slot has
     pushed down only moves further from the pointer. */
  #cardBelow(lane, y) {
    return (
      lane.cards.find((card) => {
        if (card === this.#dragging) {
          return false;
        }
        const box = card.getBoundingClientRect();
        return y < box.top + box.height / 2;
      }) ?? null
    );
  }

  /* Leaving the board takes the slot away, so it does not promise a drop
     that would not happen. */
  #onDragLeave(event) {
    if (this.#dragging && !this.contains(event.relatedTarget)) {
      for (const lane of this.lanes) {
        lane.hideDropSlot();
      }
      this.#target = null;
    }
  }

  #onDrop(event) {
    if (!this.#dragging || !this.#target) {
      return;
    }

    event.preventDefault();
    const card = this.#dragging;
    const { lane, before } = this.#target;
    /* Cleared first: the move re-renders the cards, and dragend would not
       reach a card that is no longer there. */
    this.#clearDragState();

    const cards = lane.cards;
    const index = cards.indexOf(card);
    if (index !== -1 && (cards[index + 1] ?? null) === before) {
      return;
    }

    this.dispatchEvent(
      new CustomEvent("task-move", {
        bubbles: true,
        composed: true,
        detail: {
          taskId: card.taskId,
          lane: lane.laneId,
          before: before?.taskId ?? null,
        },
      }),
    );
  }

  #clearDragState() {
    this.#dragging = null;
    this.#target = null;
    for (const lane of this.lanes) {
      lane.hideDropSlot();
      for (const card of lane.cards) {
        card.removeAttribute("dragging");
      }
    }
  }

  /* ---------- moves made elsewhere ---------- */

  /* Runs `draw`, which draws cards again, then slides every card it moved
     from where it was to where it is now, so a task moved elsewhere, such as
     by an AI agent, is seen to fly to its new lane rather than vanish from one
     and appear in another. Cards are matched by task id, since a draw
     replaces the elements. A card that leaves its lane is lifted above the
     others while it flies. */
  animateMoves(draw) {
    const before = new Map(
      this.#cards().map((card) => [
        card.taskId,
        { box: card.getBoundingClientRect(), lane: card.parentElement },
      ]),
    );
    draw();
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) {
      return;
    }

    /* Every card is measured before any is animated, so the layout is
       worked out once rather than once a card. */
    const moves = [];
    for (const card of this.#cards()) {
      const from = before.get(card.taskId);
      if (!from) {
        continue;
      }
      const to = card.getBoundingClientRect();
      const dx = from.box.left - to.left;
      const dy = from.box.top - to.top;
      if (Math.abs(dx) >= 1 || Math.abs(dy) >= 1) {
        moves.push({ card, dx, dy, lifted: from.lane !== card.parentElement });
      }
    }
    for (const { card, dx, dy, lifted } of moves) {
      card.toggleAttribute("flying", lifted);
      const flight = card.animate(
        [{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "none" }],
        { duration: lifted ? 550 : 250, easing: "cubic-bezier(0.3, 0, 0.2, 1)" },
      );
      const land = () => card.removeAttribute("flying");
      flight.addEventListener("finish", land);
      flight.addEventListener("cancel", land);
    }
  }

  #cards() {
    return this.lanes.flatMap((lane) => lane.cards);
  }

  /* ---------- rendering ---------- */

  #render() {
    this.#title.textContent = this.name;
    this.setAttribute("aria-label", this.name);
    this.#renderCount();
  }

  #renderCount() {
    const total = this.taskCount;
    this.#count.textContent = total === 1 ? "1 task" : total + " tasks";
  }
}

customElements.define("tv-board", TvBoard);
