/* <tv-menu label="Projects" heading="Projects">
     chip content
     <a slot="actions" href="…">…</a>
   </tv-menu>

   A chip that opens a menu of items, one of them marked as the current one.
   What the chip says is the element's own content; the items are set as
   `items`, each { value, label, color, current }, where a `color` puts a
   lane's dot before the label. Links slotted as "actions" go under the
   items, past a divider.

   Attributes: `label` names the menu, `heading` is shown over the items,
   `busy` disables the chip and closes the menu, and `offset` is the gap in
   pixels between the menu and what it opens under (6 by default). The menu
   opens under the chip, or under `below` when that is set to an element,
   such as the bar the chip sits in.

   Events (bubbling and composed):
     menu-pick  detail { value }  an item was picked; the menu has closed */

import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-menu.html");

export class TvMenu extends HTMLElement {
  static observedAttributes = ["label", "heading", "busy"];

  /* The element the menu opens under, or null for the chip. */
  below = null;

  #chip;
  #menu;
  #heading;
  #items;
  #note;
  #actions;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#chip = root.querySelector(".chip");
    this.#menu = root.querySelector(".menu");
    this.#heading = root.querySelector(".heading");
    this.#items = root.querySelector(".items");
    this.#note = root.querySelector(".note");
    this.#actions = root.querySelector(".actions");

    this.#menu.addEventListener("beforetoggle", (event) => {
      if (event.newState === "open") {
        this.#place();
      }
    });
    this.#menu.addEventListener("toggle", (event) => {
      const open = event.newState === "open";
      this.#chip.setAttribute("aria-expanded", open);
      if (open) {
        (
          this.#items.querySelector('[aria-current="true"]') ??
          this.#items.querySelector(".item")
        )?.focus();
      }
    });
    this.#items.addEventListener("click", (event) => this.#onPick(event));

    /* The links navigate by themselves; the menu only has to get out of the
       way. The divider goes with them when there are none. */
    const actions = root.querySelector('slot[name="actions"]');
    actions.addEventListener("slotchange", () => {
      this.#actions.hidden = actions.assignedElements().length === 0;
    });
    actions.addEventListener("click", () => this.hide());
  }

  attributeChangedCallback(name) {
    if (name === "label") {
      this.#menu.setAttribute("aria-label", this.getAttribute("label") ?? "");
    } else if (name === "heading") {
      this.#heading.textContent = this.getAttribute("heading") ?? "";
      this.#heading.hidden = !this.hasAttribute("heading");
    } else if (name === "busy") {
      this.#chip.disabled = this.busy;
      this.#chip.setAttribute("aria-busy", this.busy);
      if (this.busy) {
        this.hide();
      }
    }
  }

  get busy() {
    return this.hasAttribute("busy");
  }

  set busy(value) {
    this.toggleAttribute("busy", Boolean(value));
  }

  get open() {
    return this.#menu.matches(":popover-open");
  }

  hide() {
    if (this.open) {
      this.#menu.hidePopover();
    }
  }

  set items(items) {
    this.#items.replaceChildren(...items.map(renderItem));
  }

  /* Shown under the items, such as when there are none; "" for none. */
  set note(text) {
    this.#note.textContent = text;
    this.#note.hidden = text === "";
  }

  #onPick(event) {
    const item = event.target.closest(".item");
    if (!item) {
      return;
    }

    this.hide();
    this.dispatchEvent(
      new CustomEvent("menu-pick", {
        bubbles: true,
        composed: true,
        detail: { value: item.dataset.value },
      }),
    );
  }

  /* The popover is position: fixed in the top layer, so viewport coordinates
     are what it wants. */
  #place() {
    const offset = Number(this.getAttribute("offset") ?? 6);
    const top = (this.below ?? this.#chip).getBoundingClientRect().bottom;
    this.#menu.style.position = "fixed";
    this.#menu.style.top = `${top + offset}px`;
    this.#menu.style.left = `${this.#chip.getBoundingClientRect().left}px`;
  }
}

function renderItem({ value, label, color, current }) {
  const item = document.createElement("button");
  item.type = "button";
  item.className = "item";
  item.setAttribute("role", "menuitem");
  item.setAttribute("aria-current", Boolean(current));
  item.dataset.value = value;

  if (color) {
    const dot = document.createElement("span");
    dot.className = "dot";
    dot.style.setProperty("--dot", color);
    item.append(dot);
  }
  const name = document.createElement("span");
  name.className = "name";
  name.textContent = label;
  const check = document.createElement("span");
  check.className = "check";
  check.setAttribute("aria-hidden", "true");
  check.textContent = "✓";
  item.append(name, check);
  return item;
}

customElements.define("tv-menu", TvMenu);
