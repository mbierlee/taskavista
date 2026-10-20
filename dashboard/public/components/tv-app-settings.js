/* <tv-app-settings></tv-app-settings>

   The Taskavista settings screen, for what belongs to the whole app rather
   than to one project. Its one section so far lists the AI agents, each with
   its runtime, model and effort level as a chip apiece (the mockup joins
   them in one, but the models' real names are too long for that), marks each task
   scheduler, and shows its labels, if it has any, under a divider. After them
   comes "Quick-create an agent", where a person describes an agent for one
   of the agents to draft. The disabled agents follow in a list of their own,
   under "Disabled · n", drawn as outlines. `show()` hands it the agents,
   `clear()` empties it.

   Each agent's "Disable", or "Enable" for a disabled one, raises
   agent-enable. "Disable all" in the heading, disabled when no agent is
   enabled, and "Re-enable all" beside "Disabled · n" raise agents-enable-all.
   The caller writes it and calls `show()` again; the button is disabled
   meanwhile.

   "+ Add agent" and each agent's "Edit" open a tv-agent-dialog, whose events
   come up through this element. The caller writes what they ask for, then
   calls `show()` again and `closeDialog()`, or sets `dialogError` if the
   write was refused; `dialogSaving` holds the dialog while it is under way.

   "Generate" raises agent-draft. The caller has the draft made, holding the
   tile with `generating` meanwhile, then opens it in the dialog with
   `openDraft()`, or sets `draftError` to say why there is none. The error
   shows in the tile, with the description kept to be put right, until the
   next try or the next draft.

   Events (bubbling and composed):
     agent-draft   detail { description }
     agent-enable  detail { id, enabled }
     agents-enable-all  detail { enabled }
   and from the dialog:
     agent-create  detail { name, runtime, model, effort, maxParallelTasks, instructions, labels, taskScheduler }
     agent-save    detail { id, name, runtime, model, effort, maxParallelTasks, instructions, labels, taskScheduler }
     agent-delete  detail { id } */

import { attachTemplate, loadTemplate } from "./template.js";
import "./tv-agent-dialog.js";

const template = await loadTemplate("tv-app-settings.html");

export class TvAppSettings extends HTMLElement {
  #status;
  #disableAll;
  #enableAll;
  #add;
  #agents;
  #disabledHead;
  #disabledHeading;
  #disabledAgents;
  #agentTemplate;
  #quickCreate;
  #description;
  #generate;
  #generateLabel;
  #draftError;
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
    this.#disableAll = root.querySelector(".disable-all");
    this.#enableAll = root.querySelector(".enable-all");
    this.#add = root.querySelector(".add");
    this.#agents = root.querySelector(".agents");
    this.#disabledHead = root.querySelector(".disabled-head");
    this.#disabledHeading = root.querySelector(".disabled-heading");
    this.#disabledAgents = root.querySelector(".disabled-agents");
    this.#agentTemplate = root.querySelector(".agent-template");
    this.#quickCreate = root
      .querySelector(".quick-create-template")
      .content.firstElementChild.cloneNode(true);
    this.#description = this.#quickCreate.querySelector(".quick-create-text");
    this.#generate = this.#quickCreate.querySelector(".generate");
    this.#generateLabel = this.#quickCreate.querySelector(".generate-label");
    this.#draftError = this.#quickCreate.querySelector(".field-error");
    this.#dialog = root.querySelector("tv-agent-dialog");

    this.#add.addEventListener("click", () =>
      this.#dialog.add(
        this.#runtimes,
        this.#models,
        this.#defaults,
        this.#labels,
      ),
    );
    for (const [button, enabled] of [
      [this.#disableAll, false],
      [this.#enableAll, true],
    ]) {
      button.addEventListener("click", () => {
        button.disabled = true;
        this.dispatchEvent(
          new CustomEvent("agents-enable-all", {
            bubbles: true,
            composed: true,
            detail: { enabled },
          }),
        );
      });
    }
    this.#description.addEventListener("input", () => this.#updateGenerate());
    // Enter generates, as the button would; Shift+Enter is left to add a newline.
    this.#description.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" || event.shiftKey || event.isComposing) {
        return;
      }
      event.preventDefault();
      this.#generate.click();
    });
    this.#generate.addEventListener("click", () =>
      this.dispatchEvent(
        new CustomEvent("agent-draft", {
          bubbles: true,
          composed: true,
          detail: { description: this.#description.value.trim() },
        }),
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
     ids as { runtime, model, effort }, for a new agent. An agent's runtime, model and effort
     level are shown by name, or by id if the lists have no such entry. */
  show(agents, runtimes, models, defaults) {
    this.#runtimes = runtimes;
    this.#models = models;
    this.#defaults = defaults;
    this.#labels = countLabels(agents);
    this.#add.disabled = false;

    const runtimeNames = new Map(runtimes.map((r) => [r.id, r.name]));
    const modelNames = new Map(models.map((m) => [m.id, m.name]));
    const item = (agent) => this.#agentItem(agent, runtimeNames, modelNames);

    const disabled = agents.filter((agent) => !agent.enabled);
    this.#disableAll.disabled = disabled.length === agents.length;
    this.#agents.replaceChildren(
      ...agents.filter((agent) => agent.enabled).map(item),
      this.#quickCreate,
    );
    this.#disabledAgents.replaceChildren(...disabled.map(item));
    this.#disabledHeading.textContent = `Disabled · ${disabled.length}`;
    this.#enableAll.disabled = false;
    this.#disabledHead.hidden = disabled.length === 0;
    this.#disabledAgents.hidden = disabled.length === 0;
    this.#setStatus(agents.length === 0 ? "There are no agents yet." : "");
  }

  clear(message = "") {
    this.#add.disabled = true;
    this.#disableAll.disabled = true;
    this.#dialog.close();
    this.#agents.replaceChildren();
    this.#disabledAgents.replaceChildren();
    this.#disabledHead.hidden = true;
    this.#disabledAgents.hidden = true;
    this.#setStatus(message);
  }

  closeDialog() {
    this.#dialog.close();
  }

  /* Opens the dialog on a new agent filled in from `draft`, which has the
     fields of the agent-create event, and empties the tile, since the
     description has done its job. */
  openDraft(draft) {
    this.#description.value = "";
    this.draftError = "";
    this.#dialog.add(
      this.#runtimes,
      this.#models,
      this.#defaults,
      this.#labels,
      draft,
    );
  }

  set generating(value) {
    this.#description.disabled = Boolean(value);
    if (value) {
      this.draftError = "";
    } else {
      this.#updateGenerate();
    }
  }

  set draftError(message) {
    this.#draftError.textContent = message;
    this.#draftError.hidden = !message;
    this.#description.setAttribute("aria-invalid", String(Boolean(message)));
    this.#updateGenerate();
  }

  set dialogSaving(value) {
    this.#dialog.saving = value;
  }

  set dialogError(message) {
    this.#dialog.error = message;
  }

  /* The textarea is disabled only while a draft is being generated. */
  #updateGenerate() {
    const generating = this.#description.disabled;
    this.#generate.disabled =
      generating || this.#description.value.trim() === "";
    const failed = !this.#draftError.hidden;
    this.#generate.classList.toggle("retry", failed && !generating);
    this.#generateLabel.textContent = generating
      ? "Generating"
      : failed
        ? "Try again"
        : "Generate";
    if (generating) {
      const dots = document.createElement("span");
      dots.className = "dots";
      dots.setAttribute("aria-hidden", "true");
      dots.innerHTML = "<span>.</span><span>.</span><span>.</span>";
      this.#generateLabel.append(dots);
    }
  }

  #agentItem(agent, runtimeNames, modelNames) {
    const item = this.#agentTemplate.content.firstElementChild.cloneNode(true);
    item.classList.toggle("off", !agent.enabled);
    item.querySelector(".agent-name").textContent = agent.name;
    item.querySelector(".runtime").textContent =
      runtimeNames.get(agent.runtime) ?? agent.runtime;
    item.querySelector(".model").textContent =
      modelNames.get(agent.model) ?? agent.model;
    item.querySelector(".effort").textContent =
      this.#models
        .find((m) => m.id === agent.model)
        ?.effortLevels.find((e) => e.id === agent.effort)?.name ??
      agent.effort;
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
    const enable = item.querySelector(".enable");
    enable.textContent = agent.enabled ? "Disable" : "Enable";
    enable.addEventListener("click", () => {
      enable.disabled = true;
      this.dispatchEvent(
        new CustomEvent("agent-enable", {
          bubbles: true,
          composed: true,
          detail: { id: agent.id, enabled: !agent.enabled },
        }),
      );
    });
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
