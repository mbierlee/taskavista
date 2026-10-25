/**
 * Taskavista
 *
 * The task details panel over the board.
 *
 * Author: Mike Bierlee <m.bierlee@lostmoment.com>
 * Copyright: 2026 Mike Bierlee
 * License: MIT. The full terms of the license can be found in the LICENSE.txt file.
 */

/* <tv-task-details></tv-task-details>

   The task details panel, which slides over the right of the board: the
   task's lane, which a menu moves it out of, its description, which can be
   edited in place, the AI agent working on it, its notes, and a button that deletes it. In a
   project managed by AI, a task never handed to the agents, such as one added before the
   project was, has a "Schedule for AI" button by that one instead. It holds no data of its own:
   show() hands it a task and the board's lanes, and the notes follow once they are
   loaded; the agent's name and whether the project is managed by AI come from the store.
   Closed, it shows nothing; `open` is set while it shows.

   Events (bubbling and composed):
     task-edit   detail { taskId, description }  the description was changed:
                 on Enter, when it loses focus, or when the panel closes
                 while it is being edited. Not raised for a blank one or one
                 that did not change.
     task-move   detail { taskId, lane, before }  a lane was picked in the menu:
                 move the task to the bottom of the lane with id `lane`.
                 `before` is always null, as from the board.
     task-delete detail { taskId }                "Delete task" was confirmed. The
                 panel stays open, its button disabled, until the page
                 closes it or sets deleteError.
     task-schedule detail { taskId }              "Schedule for AI" was clicked. The
                 button stays disabled until the page sets handedToAgents
                 or scheduleError.
     task-close  detail { taskId }                the panel was closed, by its
                 close button, Escape, or a click on the board around it */

import { store } from "../store.js";
import { attachTemplate, loadTemplate } from "./template.js";
import "./tv-menu.js";
import "./tv-task-notes.js";
import "./tv-text-box.js";

const template = await loadTemplate("tv-task-details.html");

export class TvTaskDetails extends HTMLElement {
  #task = null;
  #lanes = [];
  #opener = null;
  #agents = [];
  #project = null;
  #unwatch = [];

  #layer;
  #panel;
  #menu;
  #dot;
  #laneName;
  #description;
  #error;
  #notes;
  #delete;
  #deleteError;
  #agent;
  #agentName;
  #schedule;
  #scheduleError;

  #onKey = (event) => this.#onKeyDown(event);
  #onMove = () => this.#placeLayer();

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#layer = root.querySelector(".layer");
    this.#panel = root.querySelector(".panel");
    this.#menu = root.querySelector(".lane");
    this.#dot = root.querySelector(".dot");
    this.#laneName = root.querySelector(".lane-name");
    this.#description = root.querySelector(".description");
    this.#error = root.querySelector(".field-error");
    this.#notes = root.querySelector("tv-task-notes");
    this.#delete = root.querySelector(".delete");
    this.#deleteError = root.querySelector(".delete-error");
    this.#agent = root.querySelector(".agent");
    this.#agentName = root.querySelector(".agent-name");
    this.#schedule = root.querySelector(".schedule");
    this.#scheduleError = root.querySelector(".schedule-error");

    root.querySelector(".close").addEventListener("click", () => this.close());
    root.querySelector(".backdrop").addEventListener("click", () => this.close());
    this.#delete.addEventListener("click", () => this.#onDelete());
    this.#schedule.addEventListener("click", () => this.#onSchedule());

    /* Raised again as task-move, which is what the page listens for. */
    this.#menu.addEventListener("menu-pick", (event) => {
      event.stopPropagation();
      this.#onPick(event.detail.value);
    });

    this.#description.addEventListener("text-commit", (event) => {
      event.stopPropagation();
      this.#commitDescription();
      this.#panel.focus();
    });
    /* Undoes the edit, and leaves the panel open: the box has taken the
       Escape, so #onKeyDown lets it be. */
    this.#description.addEventListener("text-cancel", (event) => {
      event.stopPropagation();
      this.description = this.#task.description;
      this.#panel.focus();
    });
    this.#description.addEventListener("focusout", () =>
      this.#commitDescription(),
    );
  }

  connectedCallback() {
    this.#unwatch = [
      store.watch(
        (state) => state.agents.list,
        (list) => {
          this.#agents = list;
          this.#renderAgent();
        },
      ),
      store.watch(
        (state) =>
          state.projects.list.find((p) => p.slug === state.currentProjectSlug) ??
          null,
        (project) => {
          this.#project = project;
          this.#renderAgent();
        },
      ),
    ];
  }

  disconnectedCallback() {
    this.#stopListening();
    this.#unwatch.forEach((unwatch) => unwatch());
    this.#unwatch = [];
  }

  get open() {
    return this.hasAttribute("open");
  }

  /* The id of the task showing, or null while closed. */
  get taskId() {
    return this.#task?.id ?? null;
  }

  /* Opens the panel on `task`, or switches it to another task while open.
     `lanes` are the board's, in board order, with the task's among them. The
     notes show as loading until they are set. */
  show(task, lanes) {
    const wasOpen = this.open;
    this.#task = task;
    this.#lanes = lanes;
    this.#renderLane();
    this.descriptionError = "";
    this.deleteError = "";
    this.scheduleError = "";
    this.#renderAgent();
    this.notes = null;

    if (!wasOpen) {
      /* Focus goes back to whatever opened the panel, usually a card, once
         it closes. */
      this.#opener = document.activeElement;
      this.setAttribute("open", "");
      this.#placeLayer();
      window.addEventListener("keydown", this.#onKey);
      window.addEventListener("scroll", this.#onMove, { passive: true });
      window.addEventListener("resize", this.#onMove);
    }
    /* Set once the panel shows, since a hidden textarea has no height to
       fit. */
    this.description = task.description;
    this.#panel.scrollTop = 0;
    this.#panel.focus();
  }

  /* After the task has been moved, by the menu here or on the board. */
  set laneId(value) {
    if (this.#task) {
      this.#task = { ...this.#task, laneId: value };
      this.#renderLane();
      this.#renderAgent();
    }
  }

  /* The AI agent at work on the task, or null when none is. */
  set workingAgentId(value) {
    if (this.#task) {
      this.#task = { ...this.#task, workingAgentId: value };
      this.#renderAgent();
    }
  }

  /* Whether the task was handed to the AI agents; set once it has been
     scheduled for AI, which also enables the button again. */
  set handedToAgents(value) {
    if (this.#task) {
      this.#task = { ...this.#task, handedToAgents: value };
      this.#schedule.disabled = false;
      this.#renderAgent();
    }
  }

  /* Shown under the schedule button when the task could not be scheduled,
     which also enables the button again. */
  set scheduleError(message) {
    this.#schedule.disabled = false;
    this.#scheduleError.textContent = message;
    this.#scheduleError.hidden = message === "";
  }

  /* What the description box shows; set back when a change could not be
     saved. */
  set description(value) {
    if (this.#task) {
      this.#task = { ...this.#task, description: value };
    }
    this.#description.value = value;
  }

  /* Shown under the description, until the next edit or task. */
  set descriptionError(message) {
    this.#error.textContent = message;
    this.#error.hidden = message === "";
  }

  /* Shown under the delete button when the task could not be deleted, which
     also enables the button again. */
  set deleteError(message) {
    this.#delete.disabled = false;
    this.#deleteError.textContent = message;
    this.#deleteError.hidden = message === "";
  }

  /* The task's notes, newest first, as the API returns them; null while
     they are loading. */
  set notes(entries) {
    this.#notes.entries = entries;
  }

  /* Shown in place of the notes when they could not be loaded. */
  set notesError(message) {
    this.#notes.error = message;
  }

  close() {
    if (!this.open) {
      return;
    }

    /* Hiding the box does not blur it, so an edit in progress is saved
       here. */
    this.#commitDescription();
    const taskId = this.taskId;
    this.#menu.hide();
    this.removeAttribute("open");
    this.#stopListening();
    this.#task = null;

    if (this.#opener?.isConnected) {
      this.#opener.focus();
    }
    this.#opener = null;

    this.dispatchEvent(
      new CustomEvent("task-close", {
        bubbles: true,
        composed: true,
        detail: { taskId },
      }),
    );
  }

  #stopListening() {
    window.removeEventListener("keydown", this.#onKey);
    window.removeEventListener("scroll", this.#onMove);
    window.removeEventListener("resize", this.#onMove);
  }

  /* An Escape that closes the lane menu is the menu's alone. */
  #onKeyDown(event) {
    if (
      event.key === "Escape" &&
      !event.defaultPrevented &&
      !this.#menu.open
    ) {
      this.close();
    }
  }

  /* A blank description is not one the task can have, so it is put back
     rather than saved. */
  #commitDescription() {
    if (!this.#task) {
      return;
    }
    const description = this.#description.value.trim();
    if (description === "" || description === this.#task.description) {
      this.description = this.#task.description;
      return;
    }

    this.description = description;
    this.descriptionError = "";
    this.dispatchEvent(
      new CustomEvent("task-edit", {
        bubbles: true,
        composed: true,
        detail: { taskId: this.#task.id, description },
      }),
    );
  }

  #onDelete() {
    if (!confirm("Delete this task? This cannot be undone.")) {
      return;
    }

    this.deleteError = "";
    this.#delete.disabled = true;
    this.dispatchEvent(
      new CustomEvent("task-delete", {
        bubbles: true,
        composed: true,
        detail: { taskId: this.#task.id },
      }),
    );
  }

  #onSchedule() {
    this.scheduleError = "";
    this.#schedule.disabled = true;
    this.dispatchEvent(
      new CustomEvent("task-schedule", {
        bubbles: true,
        composed: true,
        detail: { taskId: this.#task.id },
      }),
    );
  }

  #onPick(lane) {
    if (lane === this.#task.laneId) {
      return;
    }
    this.dispatchEvent(
      new CustomEvent("task-move", {
        bubbles: true,
        composed: true,
        detail: { taskId: this.#task.id, lane, before: null },
      }),
    );
  }

  /* The layer covers the window below the topbar, which scrolls with the
     page, so it starts wherever the host, just under the topbar, now is. */
  #placeLayer() {
    const top = Math.max(0, this.getBoundingClientRect().top);
    this.#layer.style.setProperty("--top", `${top}px`);
  }

  #renderLane() {
    const lane = this.#lanes.find((l) => l.id === this.#task.laneId);
    this.#laneName.textContent = lane?.name ?? "";
    this.#dot.style.setProperty("--dot", lane?.color ?? "");
    this.#menu.items = this.#lanes.map((l) => ({
      value: l.id,
      label: l.name,
      color: l.color,
      current: l.id === this.#task.laneId,
    }));
  }

  /* Neither shows for a project not managed by AI, and a task in a done
     lane cannot be scheduled. An agent the store does not know yet, such
     as one added since the agents were loaded, is shown unnamed until it
     does. */
  #renderAgent() {
    const task = this.#task;
    const managed = Boolean(task && this.#project?.managedByAi);
    const agentId = managed ? (task.workingAgentId ?? null) : null;
    this.#agent.hidden = agentId === null;
    this.#agentName.textContent =
      agentId === null
        ? ""
        : (this.#agents.find((a) => a.id === agentId)?.name ?? "An AI agent");

    const lane = this.#lanes.find((l) => l.id === task?.laneId);
    this.#schedule.hidden =
      !managed || task.handedToAgents || Boolean(lane?.marksDone);
  }
}

customElements.define("tv-task-details", TvTaskDetails);
