/* <tv-agent-dialog></tv-agent-dialog>

   The modal dialog an AI agent is added or edited in: its name, runtime,
   model, effort level, instructions, labels (a tv-chip-list, suggesting the
   labels other agents have) and whether it is a task scheduler. It writes nothing itself: it
   reports what was asked for and stays open, so the caller closes it once
   the write has gone through, or sets `error` when it has not.

   `add()` opens it on a new agent, with the runtime, model and effort level
   given as the defaults; `edit()` opens it on an existing one, which adds
   "Delete agent". The models offered are those of the runtime picked, and
   picking another runtime picks its default model, or else its first. The
   effort levels offered are those of the model picked, and picking another
   model keeps the level picked if it takes it, or else picks the default
   level, or else its first.

   Events (bubbling and composed):
     agent-create  detail { name, runtime, model, effort, instructions, labels, taskScheduler }
     agent-save    detail { id, name, runtime, model, effort, instructions, labels, taskScheduler }
     agent-delete  detail { id } */

import { attachTemplate, loadTemplate } from "./template.js";
import "./tv-chip-list.js";
import "./tv-toggle.js";

const template = await loadTemplate("tv-agent-dialog.html");

export class TvAgentDialog extends HTMLElement {
  #dialog;
  #form;
  #fieldset;
  #title;
  #name;
  #runtime;
  #model;
  #effort;
  #instructions;
  #labels;
  #scheduler;
  #error;
  #delete;
  #save;

  /* The agent being edited, or null for a new one. */
  #agent = null;
  #models = [];
  #defaultModel = null;
  #defaultEffort = null;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#dialog = root.querySelector("dialog");
    this.#form = root.querySelector("form");
    this.#fieldset = root.querySelector("fieldset");
    this.#title = root.querySelector(".title");
    this.#name = root.querySelector(".name");
    this.#runtime = root.querySelector(".runtime");
    this.#model = root.querySelector(".model");
    this.#effort = root.querySelector(".effort");
    this.#instructions = root.querySelector(".instructions");
    this.#labels = root.querySelector(".labels");
    this.#scheduler = root.querySelector(".scheduler");
    this.#error = root.querySelector(".error");
    this.#delete = root.querySelector(".delete");
    this.#save = root.querySelector(".save");

    this.#form.addEventListener("submit", (event) => {
      event.preventDefault();
      this.#onSubmit();
    });
    this.#name.addEventListener("input", () => this.#updateSave());
    this.#runtime.addEventListener("change", () =>
      this.#fillModels(this.#defaultModel, this.#effort.value),
    );
    this.#model.addEventListener("change", () =>
      this.#fillEfforts(this.#effort.value),
    );
    this.#delete.addEventListener("click", () => this.#onDelete());
    root.querySelector(".close").addEventListener("click", () => this.close());
    root.querySelector(".cancel").addEventListener("click", () => this.close());
    // These are the dialog's own business; nothing above it listens for them.
    this.#scheduler.addEventListener("toggle-change", (event) =>
      event.stopPropagation(),
    );
    this.#labels.addEventListener("chips-change", (event) =>
      event.stopPropagation(),
    );
  }

  /* `runtimes` and `models` are as their REST endpoints return them;
     `defaults` holds the ids a new agent starts from, { runtime, model,
     effort }, any of which may be missing or name nothing that exists. `labels`
     are those to suggest, as { label, agents }, with the number of agents
     that have each. */
  add(runtimes, models, defaults, labels) {
    this.#open(null, runtimes, models, defaults, labels);
    this.#title.textContent = "New agent";
    this.#save.dataset.label = "Add agent";
    this.#name.value = "";
    this.#instructions.value = "";
    this.#labels.values = [];
    this.#scheduler.checked = false;
    this.#pick(this.#runtime, defaults.runtime);
    this.#fillModels(defaults.model, defaults.effort);
    this.#finishOpening();
  }

  /* As `add()`, but on `agent` as the agents endpoint returns it. A runtime,
     model or effort level the lists do not have is offered anyway, so
     opening the dialog never changes the agent by itself. */
  edit(agent, runtimes, models, defaults, labels) {
    const known = (list, id) => list.some((item) => item.id === id);
    if (!known(runtimes, agent.runtime)) {
      runtimes = [...runtimes, { id: agent.runtime, name: agent.runtime }];
    }
    const model = models.find((item) => item.id === agent.model) ?? {
      id: agent.model,
      name: agent.model,
      runtime: agent.runtime,
      effortLevels: [],
    };
    if (!known(model.effortLevels, agent.effort)) {
      models = [
        ...models.filter((item) => item !== model),
        {
          ...model,
          effortLevels: [
            ...model.effortLevels,
            { id: agent.effort, name: agent.effort },
          ],
        },
      ];
    } else if (!known(models, agent.model)) {
      models = [...models, model];
    }

    this.#open(agent, runtimes, models, defaults, labels);
    this.#title.textContent = "Edit agent";
    this.#save.dataset.label = "Save";
    this.#name.value = agent.name;
    this.#instructions.value = agent.instructions;
    this.#labels.values = agent.labels;
    this.#scheduler.checked = agent.taskScheduler;
    this.#pick(this.#runtime, agent.runtime);
    this.#fillModels(agent.model, agent.effort);
    this.#finishOpening();
  }

  close() {
    this.#dialog.close();
  }

  get saving() {
    return this.#fieldset.disabled;
  }

  set saving(value) {
    this.#fieldset.disabled = Boolean(value);
    this.#updateSave();
  }

  set error(message) {
    this.#error.textContent = message;
    this.#error.hidden = !message;
  }

  #open(agent, runtimes, models, defaults, labels) {
    this.#agent = agent;
    this.#labels.options = labels.map(({ label, agents }) => ({
      value: label,
      hint: agents === 1 ? "1 agent" : `${agents} agents`,
    }));
    this.#models = models;
    this.#defaultModel = defaults.model ?? null;
    this.#defaultEffort = defaults.effort ?? null;
    this.#runtime.replaceChildren(
      ...runtimes.map((runtime) => new Option(runtime.name, runtime.id)),
    );
    this.#delete.hidden = agent === null;
    this.error = "";
    this.#fieldset.disabled = false;
  }

  #finishOpening() {
    this.#updateSave();
    if (!this.#dialog.open) {
      this.#dialog.showModal();
    }
  }

  /* Offers the models of the runtime picked, and picks `preferred` among
     them if it is one, or else the first, then the effort levels of that
     model, preferring `preferredEffort`. */
  #fillModels(preferred, preferredEffort) {
    const runtime = this.#runtime.value;
    this.#model.replaceChildren(
      ...this.#models
        .filter((model) => model.runtime === runtime)
        .map((model) => new Option(model.name, model.id)),
    );
    this.#pick(this.#model, preferred);
    this.#fillEfforts(preferredEffort);
  }

  /* Offers the effort levels of the model picked, and picks `preferred`
     among them if it is one, or else the default, or else the first. */
  #fillEfforts(preferred) {
    const model = this.#models.find((item) => item.id === this.#model.value);
    const levels = model?.effortLevels ?? [];
    this.#effort.replaceChildren(
      ...levels.map((level) => new Option(level.name, level.id)),
    );
    if (!this.#pick(this.#effort, preferred)) {
      this.#pick(this.#effort, this.#defaultEffort);
    }
    this.#updateSave();
  }

  /* Leaves the select on its first option when `id` is not among them.
     Returns whether it was. */
  #pick(select, id) {
    if ([...select.options].some((option) => option.value === id)) {
      select.value = id;
      return true;
    }
    return false;
  }

  #updateSave() {
    const saving = this.#fieldset.disabled;
    this.#save.disabled =
      saving ||
      this.#name.value.trim() === "" ||
      this.#model.value === "" ||
      this.#effort.value === "";
    this.#save.textContent = saving ? "Saving…" : this.#save.dataset.label;
  }

  #onSubmit() {
    if (this.#save.disabled) {
      return;
    }

    this.error = "";
    const detail = {
      name: this.#name.value.trim(),
      runtime: this.#runtime.value,
      model: this.#model.value,
      effort: this.#effort.value,
      instructions: this.#instructions.value.trim(),
      labels: this.#labels.values,
      taskScheduler: this.#scheduler.checked,
    };
    if (this.#agent === null) {
      this.#raise("agent-create", detail);
    } else {
      this.#raise("agent-save", { id: this.#agent.id, ...detail });
    }
  }

  #onDelete() {
    if (
      this.#agent === null ||
      !confirm(`Delete the agent “${this.#agent.name}”? This cannot be undone.`)
    ) {
      return;
    }
    this.error = "";
    this.#raise("agent-delete", { id: this.#agent.id });
  }

  #raise(type, detail) {
    this.dispatchEvent(
      new CustomEvent(type, { bubbles: true, composed: true, detail }),
    );
  }
}

customElements.define("tv-agent-dialog", TvAgentDialog);
