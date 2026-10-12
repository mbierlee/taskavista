/* <tv-app-settings></tv-app-settings>

   The Taskavista settings screen, for what belongs to the whole app rather
   than to one project. Its one section so far lists the AI agents, each with
   its runtime and model as a chip apiece (the mockup joins them in one, but
   the models' real names are too long for that), marks each task
   scheduler, and shows its labels, if it has any, under a divider. `show()` hands it the agents, `clear()` empties it.

   "+ Add agent" and each agent's "Edit" open a tv-agent-dialog, whose events
   come up through this element. The caller writes what they ask for, then
   calls `show()` again and `closeDialog()`, or sets `dialogError` if the
   write was refused; `dialogSaving` holds the dialog while it is under way.

   Events (bubbling and composed), from the dialog:
     agent-create  detail { name, runtime, model, effort, labels, taskScheduler }
     agent-save    detail { id, name, runtime, model, effort, labels, taskScheduler }
     agent-delete  detail { id } */

import { attachTemplate, loadTemplate } from "./template.js";
import "./tv-agent-dialog.js";

const template = await loadTemplate("tv-app-settings.html");

export class TvAppSettings extends HTMLElement {
  #status;
  #add;
  #agents;
  #agentTemplate;
  #dialog;

  /* What `show()` was last given, for the dialog to offer. */
  #runtimes = [];
  #models = [];
  #defaults = {};
  /* Every label an agent has, as { label, agents }, for the dialog to
     suggest. */
  #labels = [];

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#status = root.querySelector(".status");
    this.#add = root.querySelector(".add");
    this.#agents = root.querySelector(".agents");
    this.#agentTemplate = root.querySelector(".agent-template");
    this.#dialog = root.querySelector("tv-agent-dialog");

    this.#add.addEventListener("click", () =>
      this.#dialog.add(
        this.#runtimes,
        this.#models,
        this.#defaults,
        this.#labels,
      ),
    );
  }

  connectedCallback() {
    this.setAttribute("aria-label", "Taskavista settings");
  }

  disconnectedCallback() {
    this.#dialog.close();
  }

  /* `agents`, `runtimes` and `models` are as their REST endpoints return
     them, and `defaults` holds the default runtime, model and effort level
     ids as { runtime, model, effort }, for a new agent. An agent's runtime and model are
     shown by name, or by id if the list has no such entry. */
  show(agents, runtimes, models, defaults) {
    this.#runtimes = runtimes;
    this.#models = models;
    this.#defaults = defaults;
    this.#labels = countLabels(agents);
    this.#add.disabled = false;

    const runtimeNames = new Map(runtimes.map((r) => [r.id, r.name]));
    const modelNames = new Map(models.map((m) => [m.id, m.name]));

    this.#agents.replaceChildren(
      ...agents.map((agent) => {
        const item = this.#agentTemplate.content.firstElementChild.cloneNode(true);
        item.querySelector(".agent-name").textContent = agent.name;
        item.querySelector(".runtime").textContent =
          runtimeNames.get(agent.runtime) ?? agent.runtime;
        item.querySelector(".model").textContent =
          modelNames.get(agent.model) ?? agent.model;
        item.querySelector(".scheduler").hidden = !agent.taskScheduler;
        const labels = item.querySelector(".agent-labels");
        labels.hidden = agent.labels.length === 0;
        labels.replaceChildren(
          ...agent.labels.map((label) => {
            const labelEl = document.createElement("span");
            labelEl.className = "agent-label";
            labelEl.textContent = label;
            return labelEl;
          }),
        );
        item.querySelector(".edit").addEventListener("click", () =>
          this.#dialog.edit(
            agent,
            this.#runtimes,
            this.#models,
            this.#defaults,
            this.#labels,
          ),
        );
        return item;
      }),
    );
    this.#setStatus(agents.length === 0 ? "There are no agents yet." : "");
  }

  clear(message = "") {
    this.#add.disabled = true;
    this.#dialog.close();
    this.#agents.replaceChildren();
    this.#setStatus(message);
  }

  closeDialog() {
    this.#dialog.close();
  }

  set dialogSaving(value) {
    this.#dialog.saving = value;
  }

  set dialogError(message) {
    this.#dialog.error = message;
  }

  #setStatus(message) {
    this.#status.textContent = message;
    this.#status.hidden = message === "";
  }
}

/* The labels the agents have, in alphabetical order, each with the number
   of agents that have it. */
function countLabels(agents) {
  const counts = new Map();
  for (const agent of agents) {
    for (const label of agent.labels) {
      counts.set(label, (counts.get(label) ?? 0) + 1);
    }
  }
  return [...counts]
    .map(([label, agents]) => ({ label, agents }))
    .sort((a, b) => a.label.localeCompare(b.label));
}

customElements.define("tv-app-settings", TvAppSettings);
