/* <tv-project-switcher></tv-project-switcher>

   The chip naming the current project, and the menu it opens. It takes no
   attributes: everything it shows comes from the store. With no current
   project the chip is blank while the list is still loading, so it never
   claims there are no projects before it knows. The chip is disabled while
   the project list or the board's lanes are loading, so a switch cannot
   start before the last one has finished.

   Events (bubbling and composed):
     project-select  detail { slug, name }  a project was picked from the menu */

import { attachTemplate, loadTemplate } from "./template.js";
import { store } from "../store.js";
import "./tv-menu.js";

const template = await loadTemplate("tv-project-switcher.html");

export class TvProjectSwitcher extends HTMLElement {
  #projects;
  #currentSlug;
  #boardLoading = false;
  #unwatch = [];
  #menu;
  #project;
  #settings;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#menu = root.querySelector("tv-menu");
    this.#project = root.querySelector(".project");
    this.#settings = root.querySelector(".settings");

    /* Raised again as project-select, which is what the page listens for. */
    this.#menu.addEventListener("menu-pick", (event) => {
      event.stopPropagation();
      this.#onPick(event.detail.value);
    });
  }

  connectedCallback() {
    /* Below the whole bar rather than the chip, as the mockup has it. */
    this.#menu.below = this.getRootNode().host ?? this;
    this.#unwatch = [
      store.watch(
        (state) => state.projects,
        (projects) => {
          this.#projects = projects;
          this.#render();
        },
      ),
      store.watch(
        (state) => state.currentProjectSlug,
        (slug) => {
          this.#currentSlug = slug;
          this.#render();
        },
      ),
      store.watch(
        (state) => state.boardLoading,
        (loading) => {
          this.#boardLoading = loading;
          this.#render();
        },
      ),
    ];
  }

  disconnectedCallback() {
    for (const unwatch of this.#unwatch) {
      unwatch();
    }
  }

  #onPick(slug) {
    const project = this.#projects.list.find((p) => p.slug === slug);
    this.dispatchEvent(
      new CustomEvent("project-select", {
        bubbles: true,
        composed: true,
        detail: { slug, name: project?.name },
      }),
    );
  }

  #render() {
    /* The first watch renders before the second has supplied the current slug. */
    if (!this.#projects) {
      return;
    }

    const { status, list } = this.#projects;
    const current = list.find((p) => p.slug === this.#currentSlug);
    this.#project.textContent = current?.name ?? this.#placeholder();
    this.#project.toggleAttribute("placeholder", !current);
    this.#settings.hidden = !current;
    if (current) {
      this.#settings.href = `/projects/${encodeURIComponent(current.slug)}/settings`;
    }
    this.#menu.busy = status === "loading" || this.#boardLoading;

    this.#menu.items = list.map((project) => ({
      value: project.slug,
      label: project.name,
      current: project.slug === this.#currentSlug,
    }));
    if (status === "unavailable") {
      this.#menu.note = "Projects could not be loaded.";
    } else if (list.length === 0) {
      this.#menu.note = "No projects yet.";
    } else {
      this.#menu.note = "";
    }
  }

  /* What the chip says when no project is current. */
  #placeholder() {
    const { status, list } = this.#projects;
    if (status === "loading") {
      return "";
    } else if (status === "unavailable") {
      return "Projects unavailable";
    } else if (list.length === 0) {
      return "No projects";
    } else {
      return "Choose a project";
    }
  }
}

customElements.define("tv-project-switcher", TvProjectSwitcher);
