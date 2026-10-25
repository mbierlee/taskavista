/**
 * Taskavista
 *
 * A task's notes as a timeline.
 *
 * Author: Mike Bierlee <m.bierlee@lostmoment.com>
 * Copyright: 2026 Mike Bierlee
 * License: MIT. The full terms of the license can be found in the LICENSE.txt file.
 */

/* <tv-task-notes></tv-task-notes>

   A task's notes as a timeline, newest first, with a dot in the colour of
   the lane each note says the task went into. `entries` are the notes as
   the API returns them, or null while they are loading; `error` is shown
   in their place when they could not be loaded. It raises no events. */

import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-task-notes.html");

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

export class TvTaskNotes extends HTMLElement {
  #entries;
  #status;

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#entries = root.querySelector(".entries");
    this.#status = root.querySelector(".status");
    this.entries = null;
  }

  set entries(entries) {
    this.#entries.replaceChildren(...(entries ?? []).map(renderEntry));
    if (entries === null) {
      this.#showStatus("Loading…");
    } else if (entries.length === 0) {
      this.#showStatus("Nothing has happened to this task yet.");
    } else {
      this.#showStatus("");
    }
  }

  set error(message) {
    this.#entries.replaceChildren();
    this.#showStatus(message);
  }

  #showStatus(text) {
    this.#status.textContent = text;
    this.#status.hidden = text === "";
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

  const note = document.createElement("span");
  note.className = "note";
  note.textContent = entry.note;

  const when = document.createElement("time");
  when.className = "when";
  when.dateTime = entry.insertedAt;
  when.textContent = formatTime(new Date(entry.insertedAt));

  el.append(note, when);
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

customElements.define("tv-task-notes", TvTaskNotes);
