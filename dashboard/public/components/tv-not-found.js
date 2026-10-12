/* <tv-not-found path="/bla"></tv-not-found>

   The screen for a URL that no route matches. It raises no events: the link is an ordinary
   <a href>, which app.js's navigate listener picks up. */

import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-not-found.html");

export class TvNotFound extends HTMLElement {
  static observedAttributes = ["path"];

  #path;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#path = root.querySelector(".path");
  }

  attributeChangedCallback() {
    this.#path.textContent = this.getAttribute("path") ?? "";
  }
}

customElements.define("tv-not-found", TvNotFound);
