/**
 * Taskavista
 *
 * The project settings screen, which also creates a project.
 *
 * Author: Mike Bierlee <m.bierlee@lostmoment.com>
 * Copyright: 2026 Mike Bierlee
 * License: MIT. The full terms of the license can be found in the LICENSE.txt file.
 */

/* <tv-project-settings></tv-project-settings>

   The project settings screen, which also creates a project. It edits a
   draft and writes nothing itself: saving reports the whole draft and the
   caller works out what to write.

   Each lane has three checkboxes: Intake (acceptsNewTasks), Closing
   (marksDone) and Agents (agentsPickUp). The project has no AI setting of
   its own: it is managed by AI when any lane has Agents ticked.

   The working directory is under "Advanced", collapsed at first. On a new
   project it follows the name, under the `workingDirRoot` property, until
   it is edited.

   Events (bubbling and composed):
     settings-save   detail { name, description, lanes, workingDir }
                     `lanes` is every lane in the new order, as { id, name,
                     color, marksDone, acceptsNewTasks, agentsPickUp }; id is
                     null for a lane added here, and a lane left out was
                     removed.
     project-create  detail { name, description, lanes, workingDir }  the
                     same, with every id null, and workingDir null when it
                     was left to follow the name, for the server to choose.
     project-delete  detail { id } */

import { attachTemplate, loadTemplate } from "./template.js";
import { store } from "../store.js";
import "./tv-color-picker.js";
import "./tv-lane-row.js";

const template = await loadTemplate("tv-project-settings.html");

/* The colours a lane can always be given, as the project settings mockup
   offers them, and the first of the extra ones its colour picker shows, so
   with the picker's "+" they fill its four-wide grid in two rows. They are
   data rather than style: they are what gets stored. */
const standardColors = [
  "#8fa6ff",
  "#e8b154",
  "#5fd6ab",
  "#f2836b",
  "#c79bf0",
  "#8a929e",
  "#6fc7e8",
];

/* Names that would give a project one of these slugs, which the UI's own
   routes use, cannot be taken. Mirrors reservedSlugs in api/checks.d. */
const reservedSlugs = ["new"];

/* How long typing has to pause before the name is checked, so the field does
   not flash red at every keystroke on the way to a name that is free. */
const nameCheckDelayMs = 300;

/* Example names for a new project, one per visit to the new-project screen.
   They are taken in turn rather than at random so two visits in a row never
   show the same one, from a random start so a reload does not always open on
   the first. */
const examplePlaceholders = [
  "Office move",
  "Spring product launch",
  "Kitchen renovation",
  "Website redesign",
  "Wedding planning",
  "Quarterly report",
  "Garden makeover",
  "Hiring a designer",
  "Conference talk",
  "Mobile app beta",
  "Summer road trip",
  "Charity bake sale",
  "Year-end close",
  "Podcast season two",
  "Customer onboarding",
];

let nextPlaceholder = Math.floor(Math.random() * examplePlaceholders.length);

/* The lane field behind each of a lane row's checkboxes. */
const laneFlags = {
  intake: "acceptsNewTasks",
  closing: "marksDone",
  agents: "agentsPickUp",
};

/* Two names clash when they make the same slug, the project's name in its
   URL. Mirrors slugify in helpers.d. */
function slugify(name) {
  return name
    .toLowerCase()
    .normalize("NFC")
    .split(/[^\p{Alphabetic}\p{N}\p{M}]+/u)
    .filter((word) => word !== "")
    .join("-");
}

/* Mirrors hasLetterOrDigit in helpers.d: a mark alone does not count. */
function hasLetterOrDigit(name) {
  return /[[\p{Alphabetic}\p{N}]--\p{M}]/v.test(name);
}

export class TvProjectSettings extends HTMLElement {
  #project = null;
  #projects = [];
  #noProjects = false;
  #unwatch = null;
  #nameCheck = null;
  /* Each lane has a `key` of its own, since a lane added here has no id yet. */
  #lanes = [];
  #nextKey = 0;
  #offeredColors = standardColors;
  /* The key of the lane whose colour the picker is choosing, or null, and
     that lane's colour from before, to go back to on cancel. */
  #colorKey = null;
  #colorBefore = null;
  #dragKey = null;
  #dropIndex = null;
  #workingDirRoot = null;
  /* Whether the working directory is still the one made from the name. */
  #workingDirFollows = false;

  #back;
  #title;
  #status;
  #form;
  #body;
  #name;
  #nameError;
  #description;
  #delete;
  #list;
  #addLane;
  #advancedToggle;
  #advancedBody;
  #workingDir;
  #picker;
  #error;
  #cancel;
  #save;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#back = root.querySelector(".back");
    this.#title = root.querySelector(".title");
    this.#status = root.querySelector(".status");
    this.#form = root.querySelector(".form");
    this.#body = root.querySelector(".body");
    this.#name = root.querySelector(".project-name");
    this.#nameError = root.querySelector(".name-error");
    this.#description = root.querySelector(".project-description");
    this.#delete = root.querySelector(".delete");
    this.#list = root.querySelector(".lanes");
    this.#addLane = root.querySelector(".add-lane");
    this.#advancedToggle = root.querySelector(".advanced-toggle");
    this.#advancedBody = root.querySelector(".advanced-body");
    this.#workingDir = root.querySelector(".working-dir");
    this.#picker = root.querySelector("tv-color-picker");
    this.#error = root.querySelector(".error");
    this.#cancel = root.querySelector(".cancel");
    this.#save = root.querySelector(".save");

    this.#form.addEventListener("submit", (event) => this.#onSubmit(event));
    this.#name.addEventListener("input", () => {
      clearTimeout(this.#nameCheck);
      this.#nameCheck = setTimeout(() => this.#checkName(), nameCheckDelayMs);
      this.#renderWorkingDir();
    });
    this.#advancedToggle.addEventListener("click", () => {
      this.#expandAdvanced(this.#advancedBody.hidden);
    });
    this.#workingDir.addEventListener("input", () => {
      this.#workingDirFollows = false;
    });
    this.#delete.addEventListener("click", () => this.#onDelete());
    this.#addLane.addEventListener("click", () => this.#onAddLane());
    this.#picker.addEventListener("color-input", (event) => {
      this.#previewColor(event.detail.color);
    });
    this.#picker.addEventListener("color-pick", (event) => {
      this.#onPickColor(event.detail);
    });
    this.#picker.addEventListener("color-cancel", () => this.#onCancelColor());

    /* Typing does not re-render: the row already shows what was typed. */
    this.#list.addEventListener("lane-rename", (event) => {
      this.#laneOf(event.target).name = event.detail.name;
    });
    /* Nor does ticking a box, which the row already shows. */
    this.#list.addEventListener("lane-flag", (event) => {
      const { flag, checked } = event.detail;
      this.#laneOf(event.target)[laneFlags[flag]] = checked;
    });
    this.#list.addEventListener("lane-recolor", (event) => {
      this.#onSwatch(this.#laneOf(event.target));
    });
    this.#list.addEventListener("lane-remove", (event) => {
      this.#removeLane(this.#laneOf(event.target));
    });
    this.#list.addEventListener("lane-step", (event) => {
      this.#stepLane(this.#laneOf(event.target), event.detail.step);
    });

    this.#list.addEventListener("dragstart", (event) =>
      this.#onDragStart(event),
    );
    this.#list.addEventListener("dragover", (event) => this.#onDragOver(event));
    this.#list.addEventListener("drop", (event) => this.#onDrop(event));
    this.#list.addEventListener("dragleave", (event) => {
      if (!this.#list.contains(event.relatedTarget)) {
        this.#showDropAt(null);
      }
    });
    this.#list.addEventListener("dragend", () => this.#endDrag());
  }

  connectedCallback() {
    this.setAttribute("role", "region");
    this.#renderTitle();
    this.#unwatch = store.watch(
      (state) => state.projects,
      (projects) => {
        this.#projects = projects.list;
        this.#noProjects =
          projects.status === "ready" && projects.list.length === 0;
        this.#renderTitle();
        this.#checkName();
      },
    );
  }

  disconnectedCallback() {
    this.#unwatch();
  }

  /* Starts a fresh draft of `project`, whose lanes, in board order, are
     `lanes`: { id, name, color, marksDone, acceptsNewTasks, agentsPickUp,
     taskCount }. */
  edit(project, lanes) {
    this.#start(
      project,
      lanes,
      `/projects/${encodeURIComponent(project.slug)}`,
    );
  }

  /* `lanes` are { name, color, marksDone, acceptsNewTasks, agentsPickUp },
     a flag left out being false, and `draft`, when an agent suggested the
     project, has its { name, description } to start from. The name takes
     the focus, so the screen must be on the page by then. "/" goes back to
     the last project shown. */
  create(lanes, draft = null) {
    this.#start(
      null,
      lanes.map((lane) => ({
        ...lane,
        acceptsNewTasks: lane.acceptsNewTasks ?? false,
        agentsPickUp: lane.agentsPickUp ?? false,
        id: null,
        taskCount: 0,
      })),
      "/",
      draft,
    );
    this.#name.focus();
  }

  /* The directory a new project's working directory goes in, from the
     server's defaults, or null while it is not known. */
  set workingDirRoot(root) {
    this.#workingDirRoot = root;
    this.#renderWorkingDir();
  }

  #start(project, lanes, board, draft = null) {
    const fields = project ?? draft;
    this.#project = project;
    this.#closePicker();
    this.#lanes = lanes.map((lane) => ({ ...lane, key: this.#nextKey++ }));
    this.#colorKey = null;
    this.#offeredColors = [
      ...new Set([...standardColors, ...lanes.map((lane) => lane.color)]),
    ];
    this.toggleAttribute("new", !project);
    this.#renderTitle();
    this.saving = false;
    this.error = "";

    this.#back.href = board;
    this.#cancel.href = board;
    this.#name.value = fields?.name ?? "";
    this.#name.placeholder = "";
    if (!project) {
      this.#name.placeholder = `e.g. ${examplePlaceholders[nextPlaceholder]}`;
      nextPlaceholder = (nextPlaceholder + 1) % examplePlaceholders.length;
    }
    this.#description.value = fields?.description ?? "";
    this.#checkName();

    this.#expandAdvanced(false);
    this.#workingDirFollows = !project;
    this.#workingDir.value = project?.workingDir ?? "";
    this.#workingDir.required = Boolean(project);
    this.#workingDir.placeholder = "";
    this.#renderWorkingDir();

    this.#status.hidden = true;
    this.#form.hidden = false;
    this.#renderLanes();
  }

  /* Shows no project, with `message` in its place. */
  clear(message = "") {
    this.#closePicker();
    this.#project = null;
    this.#lanes = [];
    this.#form.hidden = true;
    this.#status.textContent = message;
    this.#status.hidden = message === "";
  }

  get saving() {
    return this.hasAttribute("saving");
  }

  set saving(value) {
    this.toggleAttribute("saving", Boolean(value));
    this.#body.disabled = Boolean(value);
    if (!value) {
      this.#checkName();
    }
    if (this.hasAttribute("new")) {
      this.#save.textContent = value ? "Creating…" : "Create project";
    } else {
      this.#save.textContent = value ? "Saving…" : "Save changes";
    }
  }

  get error() {
    return this.#error.textContent;
  }

  set error(message) {
    this.#error.textContent = message;
    this.#error.hidden = !message;
  }

  /* ---------- the form ---------- */

  #onSubmit(event) {
    event.preventDefault();
    /* Enter may come before the pause that would have checked the name. A
       name that is only spaces fails the fields' pattern. */
    this.#checkName();
    /* A field left blank under a collapsed "Advanced" could not show why. */
    if (!this.#workingDir.checkValidity()) {
      this.#expandAdvanced(true);
    }
    if (this.#save.disabled || !this.#form.reportValidity()) {
      return;
    }

    this.error = "";
    this.dispatchEvent(
      new CustomEvent(this.#project ? "settings-save" : "project-create", {
        bubbles: true,
        composed: true,
        detail: {
          name: this.#name.value.trim(),
          description: this.#description.value.trim(),
          lanes: this.#lanes.map(
            ({ id, name, color, marksDone, acceptsNewTasks, agentsPickUp }) => ({
              id,
              name: name.trim(),
              color,
              marksDone,
              acceptsNewTasks,
              agentsPickUp,
            }),
          ),
          workingDir: this.#workingDirFollows
            ? null
            : this.#workingDir.value.trim(),
        },
      }),
    );
  }

  #onDelete() {
    const name = this.#project.name;
    if (
      !confirm(
        `Delete “${name}”, with all of its lanes and tasks? This cannot be undone.`,
      )
    ) {
      return;
    }

    this.dispatchEvent(
      new CustomEvent("project-delete", {
        bubbles: true,
        composed: true,
        detail: { id: this.#project.id },
      }),
    );
  }

  /* Blank is left to the field's own validation on submit. Not while
     saving: the project list reloaded then may hold the very project
     being saved, under its new name. */
  #checkName() {
    clearTimeout(this.#nameCheck);
    if (this.saving) {
      return;
    }
    const slug = slugify(this.#name.value);
    let message = "";
    if (this.#name.value.trim() !== "" && !hasLetterOrDigit(this.#name.value)) {
      message =
        "That name is not allowed. A name needs at least one letter or digit.";
    } else if (reservedSlugs.includes(slug)) {
      message = `A project cannot be called “${this.#name.value.trim()}”. Pick another name.`;
    } else if (slug !== "") {
      const other = this.#projects.find(
        (p) => p.slug === slug && p.id !== this.#project?.id,
      );
      if (other) {
        message = `A project called “${other.name}” already exists. Pick another name.`;
      }
    }

    this.#nameError.textContent = message;
    this.#nameError.hidden = message === "";
    this.#name.setAttribute("aria-invalid", message !== "");
    this.#save.disabled = message !== "";
  }

  #expandAdvanced(expanded) {
    this.#advancedToggle.setAttribute("aria-expanded", expanded);
    this.#advancedBody.hidden = !expanded;
  }

  /* ---------- lanes ---------- */

  #laneOf(el) {
    const key = Number(el.closest("tv-lane-row")?.dataset.key);
    return this.#lanes.find((lane) => lane.key === key);
  }

  #onAddLane() {
    const used = new Set(this.#lanes.map((lane) => lane.color));
    const lane = {
      key: this.#nextKey++,
      id: null,
      name: "",
      color:
        this.#offeredColors.find((color) => !used.has(color)) ??
        this.#offeredColors[0],
      marksDone: false,
      acceptsNewTasks: false,
      agentsPickUp: false,
      taskCount: 0,
    };
    this.#lanes = [...this.#lanes, lane];
    this.#renderLanes();
    this.#focusLane(lane.key, "name");
  }

  /* A lane with tasks takes them with it, so that is asked first. It only
     goes from the list here; nothing is deleted until the draft is saved. */
  #removeLane(lane) {
    const count = lane.taskCount;
    if (
      count > 0 &&
      !confirm(
        `Remove the lane “${lane.name}”? Its ${taskCount(count)} will be deleted with it when you save.`,
      )
    ) {
      return;
    }

    if (this.#colorKey === lane.key) {
      this.#closePicker();
    }
    const index = this.#lanes.indexOf(lane);
    this.#lanes = this.#lanes.filter((other) => other !== lane);
    this.#renderLanes();

    const next = this.#lanes[Math.min(index, this.#lanes.length - 1)];
    if (next) {
      this.#focusLane(next.key, "remove");
    } else {
      this.#addLane.focus();
    }
  }

  /* ---------- lane colours ---------- */

  #onSwatch(lane) {
    const reopen = this.#colorKey !== lane.key;
    this.#closePicker();
    if (!reopen) {
      return;
    }

    /* Closing the picker redraws the lanes, so the row clicked may be gone;
       the picker is anchored to the one drawn now. */
    const row = this.#rowOf(lane.key);
    this.#colorKey = lane.key;
    this.#colorBefore = lane.color;
    row.toggleAttribute("picking", true);
    this.#picker.open(row.swatch, this.#offeredColors, lane.color);
  }

  /* Closing fires color-cancel, which puts the lane's colour back. It is
     handled straight away, rather than when the event arrives, so a picker
     closed in order to reopen it, or to redraw the lanes, has let go of its
     lane by the time it returns. */
  #closePicker() {
    if (this.#colorKey === null) {
      return;
    }
    if (this.#picker.isOpen) {
      this.#picker.hidePopover();
    }
    this.#onCancelColor();
  }

  /* Shows a custom colour on the lane while it is being made, by changing
     only its row: redrawing the list would take the picker's anchor away. */
  #previewColor(color) {
    const lane = this.#lanes.find((l) => l.key === this.#colorKey);
    if (!lane) {
      return;
    }
    lane.color = color;
    this.#rowOf(lane.key)?.setAttribute("color", color);
  }

  #onPickColor({ color, custom }) {
    const lane = this.#lanes.find((l) => l.key === this.#colorKey);
    this.#colorKey = null;
    if (!lane) {
      return;
    }
    lane.color = color;
    if (custom && !this.#offeredColors.includes(color)) {
      this.#offeredColors = [...this.#offeredColors, color];
    }
    this.#renderLanes();
    this.#focusLane(lane.key, "swatch");
  }

  /* Focus goes back to the swatch only if it was in the picker, so a click
     elsewhere keeps it where it went. */
  #onCancelColor() {
    const lane = this.#lanes.find((l) => l.key === this.#colorKey);
    this.#colorKey = null;
    if (!lane) {
      return;
    }
    lane.color = this.#colorBefore;
    const focused = this.#picker.matches(":focus-within");
    this.#renderLanes();
    if (focused) {
      this.#focusLane(lane.key, "swatch");
    }
  }

  #stepLane(lane, step) {
    const index = this.#lanes.indexOf(lane);
    const to = index + step;
    if (to < 0 || to >= this.#lanes.length) {
      return;
    }
    this.#moveLane(lane, step > 0 ? to + 1 : to);
    this.#focusLane(lane.key, "handle");
  }

  /* Moves `lane` to just above the lane now at `index`, or to the end when
     `index` is the length of the list. */
  #moveLane(lane, index) {
    const from = this.#lanes.indexOf(lane);
    const rest = this.#lanes.filter((other) => other !== lane);
    const to = index > from ? index - 1 : index;
    this.#lanes = rest.toSpliced(to, 0, lane);
    this.#renderLanes();
  }

  /* ---------- dragging ---------- */

  #onDragStart(event) {
    const row = event.target.closest?.("tv-lane-row");
    if (!row) {
      return;
    }
    this.#dragKey = Number(row.dataset.key);
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", this.#laneOf(row).name);
    /* After the drag image is taken, so it is not faded too. */
    requestAnimationFrame(() => row.toggleAttribute("dragging", true));
  }

  #onDragOver(event) {
    if (this.#dragKey === null) {
      return;
    }
    const row = event.target.closest("tv-lane-row");
    if (!row) {
      return;
    }

    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    const box = row.getBoundingClientRect();
    const index = [...this.#list.children].indexOf(row);
    this.#showDropAt(
      event.clientY < box.top + box.height / 2 ? index : index + 1,
    );
  }

  #onDrop(event) {
    if (this.#dragKey === null || this.#dropIndex === null) {
      return;
    }
    event.preventDefault();
    const lane = this.#lanes.find((l) => l.key === this.#dragKey);
    const index = this.#dropIndex;
    this.#endDrag();
    this.#moveLane(lane, index);
  }

  #endDrag() {
    this.#dragKey = null;
    this.#showDropAt(null);
    for (const row of this.#list.children) {
      row.removeAttribute("dragging");
    }
  }

  #showDropAt(index) {
    this.#dropIndex = index;
    const rows = [...this.#list.children];
    rows.forEach((row, i) => {
      row.toggleAttribute("drop-before", i === index);
      row.toggleAttribute(
        "drop-after",
        i === rows.length - 1 && index === rows.length,
      );
    });
  }

  /* ---------- rendering ---------- */

  /* With no projects yet, "/" shows the project prompt rather than a board,
     so that is what the back link goes to. */
  #renderTitle() {
    const isNew = this.hasAttribute("new");
    const title = isNew ? "New project" : "Project settings";
    this.#title.textContent = title;
    this.setAttribute("aria-label", title);
    this.#back.textContent =
      isNew && this.#noProjects ? "← Back to AI setup" : "← Back to board";
  }

  /* The list is short, so it is drawn again whole after every change to it
     other than typing. */
  #renderLanes() {
    this.#closePicker();
    this.#list.replaceChildren(
      ...this.#lanes.map((lane) => this.#renderLane(lane)),
    );
  }

  #renderLane(lane) {
    const row = document.createElement("tv-lane-row");
    row.dataset.key = lane.key;
    row.setAttribute("name", lane.name);
    row.setAttribute("color", lane.color);
    for (const [flag, field] of Object.entries(laneFlags)) {
      row.toggleAttribute(flag, lane[field]);
    }
    /* A new project has no tasks to count, and a lane added here none yet. */
    row.setAttribute(
      "count",
      lane.id === null ? "" : taskCount(lane.taskCount),
    );
    return row;
  }

  /* Only a new project's, while it follows the name; the server gives a
     project whose directory of that name is another's one with a number
     after it. */
  #renderWorkingDir() {
    if (!this.#workingDirFollows) {
      return;
    }
    const root = this.#workingDirRoot?.replace(/\/+$/, "");
    const slug = slugify(this.#name.value);
    this.#workingDir.value = root && slug ? `${root}/${slug}` : "";
    this.#workingDir.placeholder = root
      ? `${root}/…`
      : "Chosen when the project is created";
  }

  #rowOf(key) {
    return this.#list.querySelector(`tv-lane-row[data-key="${key}"]`);
  }

  /* `control` is one of the row's, as focusControl() names them. */
  #focusLane(key, control) {
    this.#rowOf(key)?.focusControl(control);
  }
}

function taskCount(count) {
  return count === 1 ? "1 task" : `${count} tasks`;
}

customElements.define("tv-project-settings", TvProjectSettings);
