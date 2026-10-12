/* <tv-task-history></tv-task-history>

   A task's history as a timeline, newest first, with a dot in the colour of
   the lane each change put the task in. `entries` is the history as the API
   returns it, or null while it is loading; `error` is shown in its place
   when it could not be loaded. It raises no events. */

import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-task-history.html");

const timeFormat = new Intl.DateTimeFormat(undefined, {
  day: "numeric",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
});
const timeFormatWithYear = new Intl.DateTimeFormat(undefined, {
  day: "numeric",
  month: "short",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
});

export class TvTaskHistory extends HTMLElement {
  #entries;
  #note;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#entries = root.querySelector(".entries");
    this.#note = root.querySelector(".note");
    this.entries = null;
  }

  set entries(entries) {
    this.#entries.replaceChildren(...(entries ?? []).map(renderEntry));
    if (entries === null) {
      this.#showNote("Loading…");
    } else if (entries.length === 0) {
      this.#showNote("Nothing has happened to this task yet.");
    } else {
      this.#showNote("");
    }
  }

  set error(message) {
    this.#entries.replaceChildren();
    this.#showNote(message);
  }

  #showNote(text) {
    this.#note.textContent = text;
    this.#note.hidden = text === "";
  }
}

function renderEntry(entry) {
  const el = document.createElement("li");
  el.className = "entry";
  if (entry.laneColor) {
    el.style.setProperty("--dot", entry.laneColor);
  } else {
    el.setAttribute("no-lane", "");
  }

  const change = document.createElement("span");
  change.className = "change";
  change.textContent = entry.change;

  const when = document.createElement("time");
  when.className = "when";
  when.dateTime = entry.changedAt;
  when.textContent = formatTime(new Date(entry.changedAt));

  el.append(change, when);
  return el;
}

/* The year only when it is not this one, as the mockup's "18 Sep, 09:40". */
function formatTime(date) {
  const format =
    date.getFullYear() === new Date().getFullYear()
      ? timeFormat
      : timeFormatWithYear;
  return format.format(date);
}

customElements.define("tv-task-history", TvTaskHistory);
