/**
 * Taskavista
 *
 * The web UI's data and router, and the only writer to the store.
 *
 * Author: Mike Bierlee <m.bierlee@lostmoment.com>
 * Copyright: 2026 Mike Bierlee
 * License: MIT. The full terms of the license can be found in the LICENSE.txt file.
 */

/* The screen is assembled from custom elements (see components/), which own all
   of the presentation and interaction. What is left here is the data they
   show, and acting on the events they raise.

   Data reaches the elements two ways. Shared state — the project list, loaded
   from the server, and the project the URL names — goes into the store
   (store.js), which components watch directly. The board's lanes are loaded
   from the server whenever the selected project changes, together with their
   tasks, and handed down as elements: lanes to the board, cards to each lane.
   What was drawn is kept, so a card can be moved on screen without a refetch.
   A card that is clicked opens its task in the details panel, which slides
   over the board. The agent chat sits beside every screen, and its chats last
   as long as the page.

   Which screen is showing follows the URL; see "routing" below. */

import "./components/tv-card.js";
import "./components/tv-lane.js";
import "./components/tv-board.js";
import "./components/tv-topbar.js";
import "./components/tv-not-found.js";
import "./components/tv-project-settings.js";
import "./components/tv-project-prompt.js";
import "./components/tv-app-settings.js";
import "./components/tv-task-details.js";
import "./components/tv-agent-chat.js";
import { store } from "./store.js";

const topbarEl = document.querySelector("tv-topbar");
const boardEl = document.createElement("tv-board");
const detailsEl = document.querySelector("tv-task-details");
const chatEl = document.querySelector("tv-agent-chat");

/* ---------- the board ---------- */

/* Aborts the board fetch for the project shown before, so a slow response
   cannot land on the board of the project shown after it. */
let boardRequest = null;

/* The board on screen: the project, and for each lane id the lane, its
   element and its tasks in lane order. null while it is empty or loading. */
let board = null;

/* The id of the project whose board is on screen or loading, and whether a
   change to it was reported while it loaded. The load may have fetched
   before that change, so the board is fetched again once it is in. */
let boardProjectId = null;
let boardStale = false;

/* Writes go to the server one at a time, in the order they were made, so two
   quick adds cannot race for the same position at the bottom of a lane, and
   a move is not overtaken by the next one. Returns the write's own result;
   a failed write does not hold up the ones after it. */
let writes = Promise.resolve();

function queueWrite(write) {
  const result = writes.then(write);
  writes = result.catch(() => {});
  return result;
}

/* The previous project's lanes are cleared before the fetch rather than left
   up under the new name, and a failed fetch leaves no lanes at all rather
   than lanes that look empty but are not. */
async function showBoard(project) {
  boardRequest?.abort();
  boardRequest = null;
  detailsEl.close();
  board = null;
  boardProjectId = project?.id ?? null;
  boardStale = false;

  boardEl.name = project?.name ?? "";
  boardEl.replaceChildren();
  if (!project) {
    store.update({ boardLoading: false });
    return;
  }

  const request = new AbortController();
  boardRequest = request;
  store.update({ boardLoading: true });

  try {
    const base = `/api/rest/v1/projects/${encodeURIComponent(project.id)}`;
    const [lanes, tasks] = await Promise.all([
      fetchJson(`${base}/lanes`, { signal: request.signal }),
      fetchJson(`${base}/tasks`, { signal: request.signal }),
    ]);

    const tasksByLane = Map.groupBy(tasks, (task) => task.laneId);
    board = {
      project,
      lanes: renderLanes(project, lanes, (id) => tasksByLane.get(id) ?? []),
    };
    boardEl.replaceChildren(...[...board.lanes.values()].map((e) => e.el));
    if (boardStale) {
      boardStale = false;
      refreshBoard();
    }
  } catch (error) {
    if (!request.signal.aborted) {
      console.error(`Could not load the board of ${project.slug}:`, error);
    }
  } finally {
    /* A request that was superseded leaves the flag to the one after it. */
    if (boardRequest === request) {
      boardRequest = null;
      store.update({ boardLoading: false });
    }
  }
}

/* Resolves to the parsed body, or null for an empty one, as a DELETE
   answers. A failure is thrown with the server's statusMessage when it gave
   one, since that is worth showing, and with the response's `status`. */
async function fetchJson(url, options) {
  const response = await fetch(url, options);
  if (!response.ok) {
    const body = await response.json().catch(() => null);
    const error = new Error(
      body?.statusMessage ?? `${response.status} ${response.statusText}`,
    );
    error.status = response.status;
    throw error;
  }
  const text = await response.text();
  return text === "" ? null : JSON.parse(text);
}

function sendJson(method, url, body) {
  return fetchJson(url, {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

/* The board's lanes, for `board.lanes`, each drawn with its cards. The API
   returns lanes in board order and each lane's tasks in lane order, so
   neither is sorted here, and the first lane is the one that takes new tasks
   under the "first_lane" rule. */
function renderLanes(project, lanes, tasksOf) {
  const addAnywhere = project.taskAddRule === "any_lane";
  const entries = lanes.map((lane, index) => ({
    lane,
    el: renderLane(lane, addAnywhere || index === 0),
    tasks: tasksOf(lane.id),
  }));
  entries.forEach(renderCards);
  return new Map(entries.map((entry) => [entry.lane.id, entry]));
}

function renderLane(lane, canAdd) {
  const el = document.createElement("tv-lane");
  el.setAttribute("lane-id", lane.id);
  el.setAttribute("name", lane.name);
  el.setAttribute("color", lane.color);
  el.toggleAttribute("marks-done", lane.marksDone);
  el.canAdd = canAdd;
  return el;
}

/* A task has no done flag of its own: it is done when its lane marks it so. */
function renderCards({ lane, el, tasks }) {
  el.replaceChildren(...tasks.map((task) => renderCard(task, lane.marksDone)));
}

function renderCard(task, done) {
  const el = document.createElement("tv-card");
  el.taskId = task.id;
  el.done = done;
  el.selected = task.id === openTaskId;
  el.workingAgentId = task.workingAgentId;
  el.textContent = task.description;
  return el;
}

/* On screen straight away, then on the server. If the server refuses, the
   board is loaded again, so it shows what was actually stored. */
async function moveTask(taskId, laneId, before) {
  if (!board) {
    return;
  }
  const from = [...board.lanes.values()].find((entry) =>
    entry.tasks.some((task) => task.id === taskId),
  );
  const to = board.lanes.get(laneId);
  if (!from || !to) {
    return;
  }

  const task = { ...from.tasks.find((t) => t.id === taskId), laneId };
  from.tasks = from.tasks.filter((t) => t.id !== taskId);
  const index = to.tasks.findIndex((t) => t.id === before);
  to.tasks =
    index === -1 ? [...to.tasks, task] : to.tasks.toSpliced(index, 0, task);

  renderCards(from);
  if (to !== from) {
    renderCards(to);
  }
  if (openTaskId === taskId) {
    detailsEl.laneId = laneId;
  }

  const shown = board;
  try {
    await queueWrite(() =>
      sendJson("POST", "/api/rpc/v1/moveTask", {
        taskId,
        laneId,
        beforeTaskId: before,
      }),
    );
    /* A move to another lane is a new note on the task. */
    if (to !== from && openTaskId === taskId) {
      loadNotes(taskId);
    }
  } catch (error) {
    console.error(`Could not move the task ${taskId}:`, error);
    if (board === shown) {
      showBoard(shown.project);
    }
  }
}

/* The card appears once the server has stored the task, since a card cannot
   be moved without the task's id. It is appended rather than the lane re-rendered, so
   a card being dragged in that lane is left alone. */
async function addTask(laneId, description) {
  const shown = board;
  if (!shown?.lanes.has(laneId)) {
    return;
  }

  try {
    const task = await queueWrite(() =>
      sendJson("POST", `/api/rest/v1/lanes/${encodeURIComponent(laneId)}/tasks`, {
        description,
      }),
    );

    /* The board may have been switched or reloaded while it was saving. */
    const entry = board === shown ? board.lanes.get(laneId) : undefined;
    if (entry) {
      entry.tasks = [...entry.tasks, task];
      const card = renderCard(task, entry.lane.marksDone);
      card.added = true;
      entry.el.append(card);
    }
  } catch (error) {
    console.error(`Could not add the task "${description}":`, error);
  }
}

/* ---------- task details ---------- */

/* The task open in the details panel, or null while it is closed. */
let openTaskId = null;

/* Counts notes requests, so a slow one cannot land on the panel after it
   has been closed, or switched to another task. */
let notesRequest = 0;

function openTask(taskId) {
  const entry = laneOf(taskId);
  if (!entry) {
    return;
  }

  openTaskId = taskId;
  markOpenCard();
  detailsEl.show(
    entry.tasks.find((t) => t.id === taskId),
    [...board.lanes.values()].map((e) => e.lane),
  );
  loadNotes(taskId);
}

/* The panel has already closed itself. A card re-rendered while it was open
   is not the element that opened it, which the panel would otherwise have
   given focus back to. */
function taskClosed(taskId) {
  openTaskId = null;
  markOpenCard();
  if (document.activeElement === document.body) {
    cardOf(taskId)?.focus();
  }
}

/* Updates the cards on the board rather than re-rendering them, so a card
   keeps its focus. */
function markOpenCard() {
  for (const entry of board?.lanes.values() ?? []) {
    for (const card of entry.el.cards) {
      card.selected = card.taskId === openTaskId;
    }
  }
}

/* On screen straight away, then on the server. If the server refuses, the
   old description is put back, and the panel says why. */
async function editTask(taskId, description) {
  const old = laneOf(taskId)?.tasks.find((t) => t.id === taskId).description;
  if (old === undefined) {
    return;
  }
  showDescription(taskId, description);

  const shown = board;
  try {
    await queueWrite(async () => {
      /* A PUT replaces the whole task, and the position kept here can be
         stale, since a move renumbers the tasks below it on the server
         only; so the stored task is read back first. */
      const url = `/api/rest/v1/tasks/${encodeURIComponent(taskId)}`;
      const stored = await fetchJson(url);
      return sendJson("PUT", url, { ...stored, description });
    });
    if (openTaskId === taskId) {
      loadNotes(taskId);
    }
  } catch (error) {
    console.error(`Could not save the description of the task ${taskId}:`, error);
    if (board === shown) {
      showDescription(taskId, old);
    }
    if (openTaskId === taskId) {
      detailsEl.description = old;
      detailsEl.descriptionError = `Not saved: ${error.message.replace(/\.$/, "")}.`;
    }
  }
}

/* On the server first, then on screen, since a card cannot be put back once
   it is gone. A task already gone from the server counts as deleted. Its card
   is removed rather than the lane re-rendered, so a card being dragged in that
   lane is left alone, and it fades out before the cards below it close up. */
async function deleteTask(taskId) {
  const shown = board;
  try {
    await queueWrite(() =>
      fetchJson(`/api/rest/v1/tasks/${encodeURIComponent(taskId)}`, {
        method: "DELETE",
      }),
    );
  } catch (error) {
    if (error.status !== 404) {
      console.error(`Could not delete the task ${taskId}:`, error);
      if (openTaskId === taskId) {
        detailsEl.deleteError = `Not deleted: ${error.message.replace(/\.$/, "")}.`;
      }
      return;
    }
  }

  const entry = board === shown ? laneOf(taskId) : undefined;
  if (entry) {
    entry.tasks = entry.tasks.filter((t) => t.id !== taskId);
    boardEl.animateMoves(() => cardOf(taskId)?.remove());
  }
  if (openTaskId === taskId) {
    detailsEl.close();
  }
}

/* On the server first, then on screen, since whether the task can be
   scheduled is the server's to say. The board fetches the task again for
   its event, which is all a card shows of it. */
async function scheduleTask(taskId) {
  const shown = board;
  try {
    await queueWrite(() =>
      sendJson("POST", "/api/rpc/v1/rescheduleTask", { taskId }),
    );
  } catch (error) {
    console.error(`Could not schedule the task ${taskId} for AI:`, error);
    if (openTaskId === taskId) {
      detailsEl.scheduleError = `Not scheduled: ${error.message.replace(/\.$/, "")}.`;
    }
    return;
  }

  const task = board === shown ? laneOf(taskId)?.tasks.find((t) => t.id === taskId) : undefined;
  if (task) {
    task.handedToAgents = true;
  }
  if (openTaskId === taskId) {
    detailsEl.handedToAgents = true;
  }
}

/* On the server first, then on screen, as a single delete would be. The
   cards are removed rather than the lane re-rendered, and fade out together. */
async function clearLane(laneId) {
  const shown = board;
  try {
    await queueWrite(() =>
      sendJson("POST", "/api/rpc/v1/clearLane", { laneId }),
    );
  } catch (error) {
    console.error(`Could not clear the lane ${laneId}:`, error);
    return;
  }

  const entry = board === shown ? board.lanes.get(laneId) : undefined;
  if (!entry) {
    return;
  }
  const open = openTaskSnapshot();
  entry.tasks = [];
  boardEl.animateMoves(() => {
    for (const card of entry.el.cards) {
      card.remove();
    }
  });
  showOpenTask(open);
}

/* In the board's copy and on the card. */
function showDescription(taskId, description) {
  const entry = laneOf(taskId);
  if (!entry) {
    return;
  }
  entry.tasks = entry.tasks.map((t) =>
    t.id === taskId ? { ...t, description } : t,
  );
  const card = cardOf(taskId);
  if (card) {
    card.textContent = description;
  }
}

function laneOf(taskId) {
  for (const entry of board?.lanes.values() ?? []) {
    if (entry.tasks.some((t) => t.id === taskId)) {
      return entry;
    }
  }
  return undefined;
}

function cardOf(taskId) {
  for (const entry of board?.lanes.values() ?? []) {
    const card = entry.el.cards.find((c) => c.taskId === taskId);
    if (card) {
      return card;
    }
  }
  return null;
}

async function loadNotes(taskId) {
  const request = ++notesRequest;
  const current = () => request === notesRequest && openTaskId === taskId;
  try {
    const notes = await fetchJson(
      `/api/rest/v1/tasks/${encodeURIComponent(taskId)}/notes`,
    );
    if (current()) {
      detailsEl.notes = notes;
    }
  } catch (error) {
    console.error(`Could not load the notes of the task ${taskId}:`, error);
    if (current()) {
      detailsEl.notesError = "The notes could not be loaded.";
    }
  }
}

/* ---------- projects ---------- */

/* The last project shown survives a reload through localStorage, so the root
   can go back to it. Storage can be missing or refuse access (a private
   window, blocked site data), and then the root goes to the first project. */
const lastProjectKey = "taskavista.currentProjectSlug";

function readSavedProjectSlug() {
  try {
    return localStorage.getItem(lastProjectKey);
  } catch {
    return null;
  }
}

function saveProjectSlug(slug) {
  try {
    localStorage.setItem(lastProjectKey, slug);
  } catch {
    /* Not persisted; the root will pick the first project instead. */
  }
}

/* Counts the fetches of the project list, here and when a change to a
   project is reported, so that one answered after a later one cannot put
   back the older list. */
let projectListRequests = 0;
let projectListShown = 0;

/* Whether the fetch numbered `request` is the latest answered, which it then
   becomes. */
function latestProjectList(request) {
  if (request < projectListShown) {
    return false;
  }
  projectListShown = request;
  return true;
}

/* Never throws: the rest of the UI carries on without the list. */
async function loadProjects() {
  const request = ++projectListRequests;
  try {
    const list = await fetchJson("/api/rest/v1/projects");
    if (latestProjectList(request)) {
      store.update({ projects: { status: "ready", list } });
    }
  } catch (error) {
    console.error("Could not load projects:", error);
    if (latestProjectList(request)) {
      store.update({ projects: { status: "unavailable", list: [] } });
    }
  }
}

/* Whether `slug` names a project, as far as is known: until the list is in,
   or when it could not be loaded, any slug is given the benefit of the doubt. */
function projectExists(slug) {
  const { status, list } = store.state.projects;
  return status !== "ready" || list.some((p) => p.slug === slug);
}

/* ---------- AI agents ---------- */

/* Set while the project list is replaced only to record that a project's
   agents were paused or resumed, which changes nothing on the board, so the
   board is not loaded again for it. */
let keepBoard = false;

/* On screen straight away, then on the server. If the server refuses, the
   strip over the board goes back to what it said before. Its button is
   disabled until the server has answered, so a second press, such as the
   second click of a double click, cannot undo the first. */
async function setAiPaused(projectId, paused) {
  if (store.state.aiPausing.includes(projectId)) {
    return;
  }

  store.update({ aiPausing: [...store.state.aiPausing, projectId] });
  showAiPaused(projectId, paused);
  try {
    await queueWrite(() =>
      sendJson("POST", "/api/rpc/v1/setAiPaused", { projectId, paused }),
    );
  } catch (error) {
    console.error(
      `Could not ${paused ? "pause" : "resume"} the AI agents of the project ${projectId}:`,
      error,
    );
    showAiPaused(projectId, !paused);
  } finally {
    store.update({
      aiPausing: store.state.aiPausing.filter((id) => id !== projectId),
    });
  }
}

function showAiPaused(projectId, paused) {
  const { projects } = store.state;
  const list = projects.list.map((p) =>
    p.id === projectId ? { ...p, aiPaused: paused } : p,
  );
  keepBoard = true;
  try {
    store.update({ projects: { ...projects, list } });
  } finally {
    keepBoard = false;
  }
}

/* ---------- project settings ---------- */

const settingsEl = document.createElement("tv-project-settings");

/* The project the settings screen was given to edit, as the server had it.
   null while none is loaded. */
let settings = null;

/* The screen is emptied first, so it never shows the draft of a project it
   was showing before. */
async function loadSettings(project, signal) {
  settings = null;
  settingsEl.clear();

  try {
    const base = `/api/rest/v1/projects/${encodeURIComponent(project.id)}`;
    const [lanes, tasks] = await Promise.all([
      fetchJson(`${base}/lanes`, { signal }),
      fetchJson(`${base}/tasks`, { signal }),
    ]);
    const counts = Map.groupBy(tasks, (task) => task.laneId);
    const edited = lanes.map((lane) => ({
      ...lane,
      taskCount: counts.get(lane.id)?.length ?? 0,
    }));
    settings = { project };
    settingsEl.edit(project, edited);
  } catch (error) {
    if (!signal.aborted) {
      console.error(`Could not load the settings of ${project.slug}:`, error);
      settingsEl.clear("The project's lanes could not be loaded.");
    }
  }
}

/* The draft is saved whole or not at all, so a refusal leaves the draft as it is to
   be put right. A rename gives the project a new slug, which the server makes
   from the new name, and so a new URL; the settings page at the old one is
   replaced by the board at the new. */
async function saveSettings(draft) {
  const shown = settings;
  if (!shown) {
    return;
  }

  settingsEl.saving = true;
  let saved;
  try {
    saved = await queueWrite(() =>
      sendJson("POST", "/api/rpc/v1/saveProjectSettings", {
        projectId: shown.project.id,
        name: draft.name,
        description: draft.description,
        taskAddRule: draft.taskAddRule,
        managedByAi: draft.managedByAi,
        lanes: draft.lanes,
      }),
    );
  } catch (error) {
    console.error(`Could not save the settings of ${shown.project.slug}:`, error);
    settingsEl.saving = false;
    settingsEl.error = `Nothing was saved: ${error.message.replace(/\.$/, "")}.`;
    return;
  }

  /* A fresh list gives the project a new identity, so the board, which
     follows it, loads the new lanes. */
  await loadProjects();
  if (settings === shown && settingsEl.isConnected) {
    const renamed = saved.slug !== shown.project.slug;
    navigation.navigate(projectPath(saved.slug), {
      history: renamed ? "replace" : "auto",
    });
  }
}

/* The settings URL is replaced rather than left in the history, since it no
   longer names anything. */
async function deleteProject(id) {
  settingsEl.saving = true;
  try {
    await queueWrite(() =>
      fetchJson(`/api/rest/v1/projects/${encodeURIComponent(id)}`, {
        method: "DELETE",
      }),
    );
  } catch (error) {
    console.error(`Could not delete the project ${id}:`, error);
    settingsEl.saving = false;
    const reason = error.message.replace(/\.$/, "");
    settingsEl.error = `The project could not be deleted (${reason}).`;
    return;
  }

  settings = null;
  await loadProjects();
  redirect("/");
}

/* ---------- new project ---------- */

const newProjectEl = document.createElement("tv-project-settings");

/* As the new project mockup has them. */
const startingLanes = [
  { name: "To do", color: "#8fa6ff", marksDone: false },
  { name: "In progress", color: "#e8b154", marksDone: false },
  { name: "Done", color: "#5fd6ab", marksDone: true },
];

/* Counts the drafts the new project screen has started, so a create that
   finishes after the screen was left, or opened afresh, leaves it alone. */
let newProjectDraft = 0;

/* The project is created whole or not at all, so a refusal
   leaves the draft as it is to be put right. */
async function createProject(draft) {
  const shown = newProjectDraft;
  newProjectEl.saving = true;
  let created;
  try {
    created = await queueWrite(() =>
      sendJson("POST", "/api/rpc/v1/createProject", {
        name: draft.name,
        description: draft.description,
        taskAddRule: draft.taskAddRule,
        managedByAi: draft.managedByAi,
        lanes: draft.lanes,
      }),
    );
  } catch (error) {
    console.error(`Could not create the project "${draft.name}":`, error);
    if (newProjectDraft === shown) {
      newProjectEl.saving = false;
      newProjectEl.error = error.message;
    }
    return;
  }

  await loadProjects();
  if (newProjectDraft === shown && newProjectEl.isConnected) {
    navigation.navigate(projectPath(created.slug), { history: "replace" });
  }
}

/* ---------- project prompt ---------- */

const projectPromptEl = document.createElement("tv-project-prompt");

/* An agent suggests the project, which can take a while, and
   the person then reviews it on the new project screen: nothing is created
   until they create it there. The draft goes with that screen's history
   entry, so back and forward, and a reload, show it again. */
async function draftProject(description) {
  projectPromptEl.generating = true;
  let draft;
  try {
    draft = await sendJson("POST", "/api/rpc/v1/draftProject", {
      description,
    });
  } catch (error) {
    console.error("Could not draft the project:", error);
    draft = { error: error.message };
  } finally {
    projectPromptEl.generating = false;
  }

  if (draft.error) {
    projectPromptEl.error = `Couldn’t set up a project. ${draft.error}`;
  } else if (projectPromptEl.isConnected) {
    navigation.navigate("/projects/new", { state: { draft } });
  }
}

/* ---------- Taskavista settings ---------- */

const appSettingsEl = document.createElement("tv-app-settings");

/* The agents are fetched each time the screen opens, with the runtimes and
   models their names come from and the defaults a new agent starts from,
   rather than taken from the store, so the screen shows them as they are
   now. */
async function loadAppSettings(signal) {
  appSettingsEl.clear();

  try {
    await fetchAppSettings(signal);
  } catch (error) {
    if (!signal.aborted) {
      console.error("Could not load the AI agents:", error);
      appSettingsEl.clear("The AI agents could not be loaded.");
    }
  }
}

/* The agents fetched for the screen go into the store as well, so the agent
   chat offers them as they now are. */
async function fetchAppSettings(signal) {
  const request = ++agentListRequests;
  const [agents, runtimes, models, defaults] = await Promise.all([
    fetchJson("/api/rest/v1/agents", { signal }),
    fetchJson("/api/rest/v1/runtimes", { signal }),
    fetchJson("/api/rest/v1/models", { signal }),
    fetchJson("/api/rest/v1/defaults", { signal }),
  ]);
  if (!latestAgentList(request)) {
    return;
  }
  store.update({
    agents: { status: "ready", list: agents, runtimes, models },
  });
  appSettingsEl.show(
    agents,
    runtimes,
    models,
    Object.fromEntries(defaults.map((d) => [d.key, d.value])),
  );
}

/* The dialog stays open, and the agent list as it was, until the server has
   answered, so a refusal leaves what was typed to be put right. The list is
   then fetched again rather than patched, since the server decides the
   order. */
async function writeAgent(write, failure) {
  appSettingsEl.dialogSaving = true;
  try {
    await queueWrite(write);
  } catch (error) {
    console.error(`${failure}:`, error);
    appSettingsEl.dialogSaving = false;
    appSettingsEl.dialogError = `${failure}: ${error.message}`;
    return;
  }

  appSettingsEl.dialogSaving = false;
  appSettingsEl.closeDialog();
  try {
    await fetchAppSettings();
  } catch (error) {
    console.error("Could not reload the AI agents:", error);
    appSettingsEl.clear("The AI agents could not be loaded.");
  }
}

/* An agent drafts the new agent, which can take a while, and the person
   then reviews it in the dialog: nothing is created until they add it there. */
async function draftAgent(description) {
  appSettingsEl.generating = true;
  let draft;
  try {
    draft = await sendJson("POST", "/api/rpc/v1/draftAgent", { description });
  } catch (error) {
    console.error("Could not draft the agent:", error);
    draft = { error: error.message };
  } finally {
    appSettingsEl.generating = false;
  }

  if (draft.error) {
    appSettingsEl.draftError = `Couldn’t generate an agent. ${draft.error}`;
  } else if (appSettingsEl.isConnected) {
    appSettingsEl.openDraft(draft);
  }
}

function createAgent(agent) {
  writeAgent(
    () => sendJson("POST", "/api/rest/v1/agents", agent),
    "The agent could not be added",
  );
}

function saveAgent({ id, ...agent }) {
  writeAgent(
    () =>
      sendJson("PUT", `/api/rest/v1/agents/${encodeURIComponent(id)}`, agent),
    "The agent could not be saved",
  );
}

/* The list is fetched again once the server has answered, whether or not it
   took the change, so the agents show as they now are. */
async function setAgentEnabled(agentId, enabled) {
  try {
    await queueWrite(() =>
      sendJson("POST", "/api/rpc/v1/setAgentEnabled", { agentId, enabled }),
    );
  } catch (error) {
    console.error(
      `Could not ${enabled ? "enable" : "disable"} the agent ${agentId}:`,
      error,
    );
  }
  await reloadAgentList();
}

async function setAllAgentsEnabled(enabled) {
  try {
    await queueWrite(() =>
      sendJson("POST", "/api/rpc/v1/setAllAgentsEnabled", { enabled }),
    );
  } catch (error) {
    console.error(
      `Could not ${enabled ? "enable" : "disable"} the AI agents:`,
      error,
    );
  }
  await reloadAgentList();
}

async function reloadAgentList() {
  try {
    await fetchAppSettings();
  } catch (error) {
    console.error("Could not reload the AI agents:", error);
    appSettingsEl.clear("The AI agents could not be loaded.");
  }
}

function deleteAgent(id) {
  writeAgent(
    () =>
      fetchJson(`/api/rest/v1/agents/${encodeURIComponent(id)}`, {
        method: "DELETE",
      }),
    "The agent could not be deleted",
  );
}

/* ---------- agent chat ---------- */

/* Counts the fetches of the agents, as the project list's are counted. */
let agentListRequests = 0;
let agentListShown = 0;

function latestAgentList(request) {
  if (request < agentListShown) {
    return false;
  }
  agentListShown = request;
  return true;
}

/* Never throws: the chat says the agents could not be loaded instead. */
async function loadAgents() {
  const request = ++agentListRequests;
  try {
    const [list, runtimes, models] = await Promise.all([
      fetchJson("/api/rest/v1/agents"),
      fetchJson("/api/rest/v1/runtimes"),
      fetchJson("/api/rest/v1/models"),
    ]);
    if (latestAgentList(request)) {
      store.update({ agents: { status: "ready", list, runtimes, models } });
    }
  } catch (error) {
    console.error("Could not load the AI agents:", error);
    if (latestAgentList(request)) {
      store.update({
        agents: { status: "unavailable", list: [], runtimes: [], models: [] },
      });
    }
  }
}

/* The chats are only in the store, so they end when the page is reloaded. Session ids need only be unique for
   the page's lifetime. */
let lastSessionId = 0;

function updateChat(patch) {
  store.update({ chat: { ...store.state.chat, ...patch } });
}

/* A panel with no chats in it opens on a "New chat" tab, so it never shows
   empty. */
function toggleChat() {
  const { open, sessions, current } = store.state.chat;
  if (open) {
    updateChat({ open: false });
  } else if (sessions.length === 0) {
    newChat();
  } else {
    selectChat(current);
    updateChat({ open: true });
  }
}

/* There is one "New chat" tab at most: "+" goes back to it if it is there. */
function newChat() {
  const { sessions } = store.state.chat;
  const picking = sessions.find((s) => s.agentId === null);
  if (picking) {
    selectChat(picking.id);
    updateChat({ open: true });
    return;
  }

  const session = {
    id: ++lastSessionId,
    agentId: null,
    number: null,
    messages: [],
    unread: 0,
    waiting: false,
    agentSessionId: null,
    projectId: null,
  };
  updateChat({ open: true, sessions: [...sessions, session], current: session.id });
}

/* The replies in a chat are read once its tab shows. */
function selectChat(sessionId) {
  const sessions = store.state.chat.sessions.map((s) =>
    s.id === sessionId && s.unread !== 0 ? { ...s, unread: 0 } : s,
  );
  updateChat({ sessions, current: sessionId });
}

/* The tab next to an ended one shows in its place, the one before it if
   there is one; ending the last chat hides the panel. */
function endChats(sessionIds) {
  const { sessions, current } = store.state.chat;
  const kept = sessions.filter((s) => !sessionIds.includes(s.id));
  if (kept.length === sessions.length) {
    return;
  }

  let next = current;
  if (sessionIds.includes(current)) {
    const index = sessions.findIndex((s) => s.id === current);
    const before = sessions.slice(0, index).findLast((s) => kept.includes(s));
    next = (before ?? kept.find((s) => sessions.indexOf(s) > index))?.id ?? null;
  }
  updateChat({
    open: store.state.chat.open && kept.length > 0,
    sessions: kept,
    current: next,
  });
  if (next !== null) {
    selectChat(next);
  }
}

/* An agent can be in any number of chats, each a session of its own, so
   picking one always starts a new chat in the "New chat" tab. The chat is
   numbered one past the agent's highest open one, and keeps its number, so
   ending a chat does not renumber the others. */
function pickAgent(sessionId, agentId) {
  const { sessions } = store.state.chat;
  const number =
    Math.max(0, ...sessions.filter((s) => s.agentId === agentId).map((s) => s.number)) + 1;
  updateChat({
    sessions: sessions.map((s) => (s.id === sessionId ? { ...s, agentId, number } : s)),
  });
}

/* The first message starts a session on the agent's runtime, and the rest
   go in it, so the agent remembers the chat (see AgentChat in agent.d). One
   message is answered before the next is sent, since each continues the
   last. The project the person is in is the selected one, which the
   Taskavista settings keep too; it is only told to the agent when the chat
   starts, but is sent with every message after that, since the agent reaches
   the project's working directory only through it. A reply for a chat that
   has ended in the meantime is dropped. */
async function sendMessage(sessionId, text) {
  const session = store.state.chat.sessions.find((s) => s.id === sessionId);
  if (!session || session.waiting) {
    return;
  }
  updateSession(sessionId, (s) => ({
    ...s,
    messages: [...s.messages, { from: "user", text }],
    waiting: true,
  }));

  const { list } = store.state.projects;
  const projectId = session.agentSessionId
    ? session.projectId
    : (list.find((p) => p.slug === store.state.currentProjectSlug)?.id ?? null);
  let reply;
  let agentSessionId = session.agentSessionId;
  try {
    const result = await sendJson("POST", "/api/rpc/v1/sendChatMessage", {
      agentId: session.agentId,
      message: text,
      projectId,
      sessionId: session.agentSessionId,
    });
    reply = { from: "agent", text: result.reply };
    agentSessionId = result.sessionId;
  } catch (error) {
    console.error("Could not send the chat message:", error);
    reply = { from: "error", text: error.message };
  }

  if (!store.state.chat.sessions.some((s) => s.id === sessionId)) {
    if (!session.agentSessionId && agentSessionId) {
      endAgentSession(session.agentId, agentSessionId);
    }
    return;
  }

  const { open, current } = store.state.chat;
  const seen = open && current === sessionId;
  updateSession(sessionId, (s) => ({
    ...s,
    messages: [...s.messages, reply],
    waiting: false,
    agentSessionId,
    projectId: agentSessionId ? projectId : null,
    unread: seen ? s.unread : s.unread + 1,
  }));
}

/* Stops the agent if it is still answering, and has the server remove what
   the chat kept, since nothing can continue it once its tab is gone. */
async function endAgentSession(agentId, agentSessionId) {
  try {
    await sendJson("POST", "/api/rpc/v1/endChat", { agentId, sessionId: agentSessionId });
  } catch (error) {
    console.error(`Could not end the chat ${agentSessionId}:`, error);
  }
}

function updateSession(sessionId, change) {
  const sessions = store.state.chat.sessions.map((s) =>
    s.id === sessionId ? change(s) : s,
  );
  updateChat({ sessions });
}

/* ---------- changes made elsewhere ---------- */

/* The server reports every write, whoever made it, over a WebSocket (see
   EventStream in eventing.d), so that what an AI agent does through the API
   shows straight away. A message is only an event and the ids it concerns,
   such as { type: "task-moved", taskId, projectId, fromLaneId, toLaneId };
   what the screen needs of it is fetched here. The writes made on this page are reported as well, and
   the screen already shows those, so what is fetched is compared with what is
   drawn, and only what differs is drawn again. */

const eventsUrl = new URL("/api/events/v1", location.href);
eventsUrl.protocol = location.protocol === "https:" ? "wss:" : "ws:";

/* A socket that drops, or cannot connect, is tried again after a pause. The
   changes made while no socket was open are never reported, which includes
   those between the first fetches and the first socket opening, so
   everything on screen is fetched again whenever one opens. */
function listenForChanges() {
  const socket = new WebSocket(eventsUrl);
  socket.addEventListener("open", () => {
    refreshEverything();
  });
  socket.addEventListener("message", (event) => {
    try {
      applyChange(JSON.parse(event.data));
    } catch (error) {
      console.error("Could not apply a change reported by the server:", error);
    }
  });
  socket.addEventListener("close", () => {
    setTimeout(listenForChanges, 2000);
  });
}

/* A change to a project can change its lanes as well, as saving its
   settings does. A cleared lane is one event for all of its tasks, so only
   that lane's tasks are fetched again. */
function applyChange(change) {
  const resource = change.type.slice(0, change.type.indexOf("-"));
  const onBoard =
    change.projectId !== undefined && change.projectId === boardProjectId;
  if (resource === "task" && onBoard) {
    changeBoard((shown) =>
      refreshTask(shown, [change.fromLaneId, change.toLaneId]),
    );
  } else if (change.type === "lane-cleared" && onBoard) {
    changeBoard((shown) => refreshTask(shown, [change.laneId]));
  } else if (resource === "lane" && onBoard) {
    changeBoard(refreshLanes);
  } else if (resource === "project") {
    refreshProjectList();
    if (change.type === "project-changed" && onBoard) {
      changeBoard(refreshLanes);
    }
  } else if (resource === "agent") {
    refreshAgents();
  } else if (resource === "note" && change.taskId === openTaskId) {
    loadNotes(openTaskId);
  }
}

function refreshEverything() {
  refreshProjectList();
  refreshBoard();
  refreshAgents();
}

function refreshBoard() {
  changeBoard(refreshLanes);
  changeBoard(refreshAllTasks);
}

/* A board still loading is marked to be fetched again once it is in. */
function changeBoard(update) {
  if (board) {
    updateBoard(update);
  } else if (boardRequest) {
    boardStale = true;
  }
}

/* Board updates run one at a time, in the order the changes came in, so a
   later fetch is never drawn over by an earlier one. One that finds the
   board switched or reloaded meanwhile is dropped, since the new board was
   fetched after the change. One that fails would leave a lane as it was
   before its change, with nothing to put it right, so the whole board is
   fetched again, once. */
let boardUpdates = Promise.resolve();

function updateBoard(update, retry = true) {
  const shown = board;
  if (!shown) {
    return;
  }
  boardUpdates = boardUpdates.then(async () => {
    try {
      if (board === shown) {
        await update(shown);
      }
    } catch (error) {
      console.error("Could not show a change to the board:", error);
      if (retry && board === shown) {
        updateBoard(refreshLanes, false);
        updateBoard(refreshAllTasks, false);
      }
    }
  });
}

/* Runs `load` once no write is waiting and no card is being dragged, and
   again if either started while it ran: a fetch that overtakes a write
   would draw back what the write changes, and drawing a lane again mid-drag
   ends the drag. */
async function fetchSettled(load) {
  for (;;) {
    const pending = writes;
    await pending;
    if (cardDragging()) {
      await dragEnd();
      continue;
    }
    if (pending !== writes) {
      continue;
    }

    const result = await load();
    if (pending === writes && !cardDragging()) {
      return result;
    }
  }
}

function cardDragging() {
  return boardEl.querySelector("tv-card[dragging]") !== null;
}

/* A drop that draws the card again keeps dragend from reaching the board, so
   either ends the wait; the timeout covers a drag that ends in neither. */
function dragEnd() {
  return new Promise((resolve) => {
    const listening = new AbortController();
    const end = () => {
      listening.abort();
      resolve();
    };
    boardEl.addEventListener("drop", end, { signal: listening.signal });
    boardEl.addEventListener("dragend", end, { signal: listening.signal });
    setTimeout(end, 1000);
  });
}

/* The lanes the server named, the one the task left and the one it is in
   now, are fetched again. They are not worked out from the board, which is
   behind while changes are still queued. A lane that is not drawn, or has
   been deleted, is left to its own lane event. */
async function refreshTask(shown, laneIds) {
  const ids = [...new Set(laneIds)].filter((id) => shown.lanes.has(id));
  const lanes = await fetchSettled(() =>
    Promise.all(ids.map(async (id) => [id, await fetchLaneTasks(id)])),
  );
  if (board === shown) {
    showTasks(new Map(lanes.filter(([, tasks]) => tasks !== null)));
  }
}

async function refreshAllTasks(shown) {
  const tasks = await fetchSettled(() =>
    fetchJson(
      `/api/rest/v1/projects/${encodeURIComponent(shown.project.id)}/tasks`,
    ),
  );
  if (board === shown) {
    const tasksByLane = Map.groupBy(tasks, (task) => task.laneId);
    showTasks(
      new Map([...shown.lanes.keys()].map((id) => [id, tasksByLane.get(id) ?? []])),
    );
  }
}

/* null for a lane that has been deleted. */
async function fetchLaneTasks(laneId) {
  try {
    return await fetchJson(
      `/api/rest/v1/lanes/${encodeURIComponent(laneId)}/tasks`,
    );
  } catch (error) {
    if (error.status === 404) {
      return null;
    }
    throw error;
  }
}

/* Draws again only the lanes whose cards differ from what is drawn. A card
   for a task that was on no lane before glows, as one added here does.

   A fetched lane can hold tasks whose own events have not been handled yet,
   such as when an agent moves several in a row, and the lanes those tasks
   left were not fetched. The fetched lanes are newer than anything drawn,
   so a task in one of them is taken off any other lane it is still drawn
   in, rather than showing twice until its own event comes up.

   A card that moved slides from where it was drawn to where it is now. The
   page's own moves are drawn before their events come back, so only moves
   made elsewhere are seen to fly. */
function showTasks(tasksByLane) {
  const open = openTaskSnapshot();
  const known = new Set(
    [...board.lanes.values()].flatMap((e) => e.tasks.map((t) => t.id)),
  );
  const placed = new Set(
    [...tasksByLane.values()].flatMap((tasks) => tasks.map((t) => t.id)),
  );
  boardEl.animateMoves(() => {
    for (const entry of board.lanes.values()) {
      if (
        !tasksByLane.has(entry.lane.id) &&
        entry.tasks.some((t) => placed.has(t.id))
      ) {
        entry.tasks = entry.tasks.filter((t) => !placed.has(t.id));
        renderCards(entry);
      }
    }
    for (const [laneId, tasks] of tasksByLane) {
      const entry = board.lanes.get(laneId);
      const same =
        tasks.length === entry.tasks.length &&
        tasks.every(
          (t, i) =>
            t.id === entry.tasks[i].id &&
            t.description === entry.tasks[i].description,
        );
      entry.tasks = tasks;
      if (!same) {
        renderCards(entry);
        for (const card of entry.el.cards) {
          card.added = !known.has(card.taskId);
        }
      } else {
        /* An agent starting or stopping on a task changes only its card, which
           keeps its focus and is not glowed again. */
        for (const card of entry.el.cards) {
          card.workingAgentId = tasks.find(
            (t) => t.id === card.taskId,
          )?.workingAgentId;
        }
      }
    }
  });
  showOpenTask(open);
}

/* The lanes are drawn again only if they differ from what is drawn; a lane
   that stays keeps the tasks drawn in it, and a new one has its own
   fetched. */
async function refreshLanes(shown) {
  const { lanes, tasks } = await fetchSettled(async () => {
    const lanes = await fetchJson(
      `/api/rest/v1/projects/${encodeURIComponent(shown.project.id)}/lanes`,
    );
    const added = lanes.filter((lane) => !shown.lanes.has(lane.id));
    const tasks = await Promise.all(
      added.map(async (lane) => [lane.id, await fetchLaneTasks(lane.id)]),
    );
    return { lanes, tasks: new Map(tasks) };
  });

  const drawn = [...shown.lanes.values()];
  if (
    board !== shown ||
    (lanes.length === drawn.length &&
      lanes.every((lane, i) => sameJson(lane, drawn[i].lane)))
  ) {
    return;
  }

  const open = openTaskSnapshot();
  /* Changed in place, so updates already queued for this board still find
     it. */
  shown.lanes = renderLanes(
    shown.project,
    lanes,
    (id) => shown.lanes.get(id)?.tasks ?? tasks.get(id) ?? [],
  );
  boardEl.replaceChildren(...[...shown.lanes.values()].map((e) => e.el));
  markOpenCard();
  if (open && laneOf(open.id)) {
    detailsEl.show(
      laneOf(open.id).tasks.find((t) => t.id === open.id),
      lanes,
    );
    loadNotes(open.id);
  } else {
    showOpenTask(open);
  }
}

/* The open task as it was before an update, to tell what the update changed
   about it. */
function openTaskSnapshot() {
  const task = laneOf(openTaskId)?.tasks.find((t) => t.id === openTaskId);
  return task
    ? {
        id: task.id,
        laneId: task.laneId,
        description: task.description,
        workingAgentId: task.workingAgentId,
        handedToAgents: task.handedToAgents,
      }
    : null;
}

/* The panel follows the open task, and closes if it has gone. Its notes
   are fetched again for any change, since every change is a note on it. */
function showOpenTask(open) {
  if (!open || openTaskId !== open.id) {
    return;
  }
  const task = laneOf(open.id)?.tasks.find((t) => t.id === open.id);
  if (!task) {
    detailsEl.close();
    return;
  }
  /* Set only when changed, since setting handedToAgents enables the
     schedule button while it may be waiting on the server. */
  if (task.workingAgentId !== open.workingAgentId) {
    detailsEl.workingAgentId = task.workingAgentId;
  }
  if (task.handedToAgents !== open.handedToAgents) {
    detailsEl.handedToAgents = task.handedToAgents;
  }
  if (task.laneId === open.laneId && task.description === open.description) {
    return;
  }
  detailsEl.laneId = task.laneId;
  detailsEl.description = task.description;
  loadNotes(task.id);
}

/* The whole list, since the server decides its order, which a rename
   changes. */
async function refreshProjectList() {
  const request = ++projectListRequests;
  try {
    const list = await fetchJson("/api/rest/v1/projects");
    if (latestProjectList(request)) {
      showProjects(list);
    }
  } catch (error) {
    console.error("Could not load projects:", error);
  }
}

/* A project that has not changed keeps the object it had, since the board
   follows the selected project's identity and would otherwise load again
   for nothing; one that only had its AI agents paused or resumed, or gained
   or lost a page to open, does not load it again either. A board whose project was renamed goes to its new
   URL, and one whose project was deleted to the root. */
function showProjects(list) {
  const { projects, currentProjectSlug } = store.state;
  const before = new Map(projects.list.map((p) => [p.id, p]));
  list = list.map((p) => {
    const old = before.get(p.id);
    return old && sameJson(old, p) ? old : p;
  });
  if (
    projects.status === "ready" &&
    list.length === projects.list.length &&
    list.every((p, i) => p === projects.list[i])
  ) {
    return;
  }

  const shown = projects.list.find((p) => p.slug === currentProjectSlug);
  const now = list.find((p) => p.id === shown?.id);
  keepBoard =
    shown !== undefined &&
    now !== undefined &&
    now !== shown &&
    sameJson(
      { ...shown, aiPaused: now.aiPaused, canBeOpened: now.canBeOpened },
      now,
    );
  try {
    store.update({ projects: { status: "ready", list } });
  } finally {
    keepBoard = false;
  }

  if (shown && location.pathname === projectPath(shown.slug)) {
    if (!now) {
      redirect("/");
    } else if (now.slug !== shown.slug) {
      redirect(projectPath(now.slug));
    }
  }
}

/* The settings screen fetches the agents for itself, and puts them in the
   store as well. */
function refreshAgents() {
  if (appSettingsEl.isConnected) {
    fetchAppSettings().catch((error) => {
      console.error("Could not reload the AI agents:", error);
    });
  } else {
    loadAgents();
  }
}

/* The API writes an object's fields in the same order every time. */
function sameJson(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

/* ---------- routing ---------- */

/* Each screen has its own URL, routed here in the browser. The server hands
   every path that is not a file or an /api/ endpoint the same page (see
   serveUiRoutes in app.d), and the route decides what goes in <main>.

   Moving between routes is a same-document navigation intercepted through the
   Navigation API, so a link is an ordinary <a href>, back and forward work,
   and nothing reloads. A path the server would answer with this page but no
   route matches gets the not-found screen, at its own URL. Any other path,
   such as an /api/ endpoint or a file, is left to load from the server. */

const mainEl = document.querySelector("main");
const notFoundEl = document.createElement("tv-not-found");

/* A route with `switcher: false` hides the topbar's project switcher while
   its screen shows, and one with `settings: true` marks the topbar's gear. "new" is a reserved slug (see enforceSlug in api/checks.d),
   and comes before the pattern that would take it for one. */
const routes = [
  {
    pattern: new URLPattern({ pathname: "/" }),
    show: showRoot,
    switcher: false,
  },
  {
    pattern: new URLPattern({ pathname: "/settings" }),
    show: showAppSettings,
    settings: true,
  },
  {
    pattern: new URLPattern({ pathname: "/projects/new" }),
    show: showNewProject,
    switcher: false,
  },
  {
    pattern: new URLPattern({ pathname: "/projects/new/quick" }),
    show: showQuickCreateProject,
    switcher: false,
  },
  { pattern: new URLPattern({ pathname: "/projects/:slug" }), show: showProject },
  {
    pattern: new URLPattern({ pathname: "/projects/:slug/settings" }),
    show: showProjectSettings,
  },
];

function matchRoute(url) {
  for (const route of routes) {
    const match = route.pattern.exec(url);
    if (match) {
      return { ...route, params: match.pathname.groups };
    }
  }

  if (isPagePath(url)) {
    return { show: showNotFound, params: { path: new URL(url).pathname } };
  }
  return null;
}

/* Whether the server answers `url` with this page, which mirrors
   serveUiRoutes in app.d: anything not under /api/ whose last segment has no
   file extension. */
function isPagePath(url) {
  const { pathname } = new URL(url);
  const last = pathname.slice(pathname.lastIndexOf("/") + 1);
  return !pathname.startsWith("/api/") && !last.includes(".");
}

/* A route's parameters arrive percent-encoded. Malformed encoding (/%E0) is
   kept as it is rather than failing the navigation. */
function decodeParam(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function projectPath(slug) {
  return `/projects/${encodeURIComponent(slug)}`;
}

function settingsPath(slug) {
  return `${projectPath(slug)}/settings`;
}

/* Replaces the entry, so back skips the URL that was redirected away from. */
function redirect(path) {
  navigation.navigate(path, { history: "replace" });
}

/* The root has no screen of its own, and shows nothing, not even the
   switcher, until the project list says which screen it is. */
async function showRoot(params, signal) {
  await projectsLoaded;
  if (signal.aborted) {
    return;
  }

  const saved = readSavedProjectSlug();
  const slug =
    saved !== null && projectExists(saved)
      ? saved
      : (store.state.projects.list[0]?.slug ?? null);
  if (slug === null) {
    store.update({ currentProjectSlug: null });
    /* With no projects at all, the first project is set up here. A list that
       could not be loaded is not known to be empty, so that gets the board. */
    if (store.state.projects.status === "ready") {
      projectPromptEl.toggleAttribute("first-run", true);
      mainEl.replaceChildren(projectPromptEl);
      projectPromptEl.focus();
    } else {
      topbarEl.toggleAttribute("no-switcher", false);
      mainEl.replaceChildren(boardEl);
    }
    return;
  }

  redirect(projectPath(slug));
}

/* The route only selects the project; the board follows the selection (see
   the watcher at the bottom). */
function showProject({ slug }, signal) {
  return showForProject(decodeParam(slug), boardEl, signal);
}

/* The project's settings screen, loaded fresh each time it is opened, so it
   starts from what is saved rather than from a draft left behind. */
async function showProjectSettings({ slug }, signal) {
  const name = decodeParam(slug);
  settingsEl.clear();
  await showForProject(name, settingsEl, signal);
  if (signal.aborted || !settingsEl.isConnected) {
    return;
  }

  const project = store.state.projects.list.find((p) => p.slug === name);
  if (project) {
    await loadSettings(project, signal);
  } else {
    settingsEl.clear("Projects could not be loaded.");
  }
}

/* The route names no project, so the selection is left as it was, and the
   switcher and "Back to board" still go by it. */
function showAppSettings(params, signal) {
  mainEl.replaceChildren(appSettingsEl);
  return loadAppSettings(signal);
}

/* A fresh draft each time, as the settings screen is, or the one an agent
   suggested, which the project prompt puts in the history entry. The route
   names no project, so the selection is left as it was, and "Back to board"
   goes to it by way of the root. */
function showNewProject() {
  newProjectDraft++;
  mainEl.replaceChildren(newProjectEl);
  const draft = navigation.currentEntry.getState()?.draft ?? null;
  newProjectEl.create(draft?.lanes ?? startingLanes, draft);
}

/* The project prompt the first run has, here for a project alongside the
   others. A fresh prompt each time, as the new project screen is. */
function showQuickCreateProject() {
  projectPromptEl.toggleAttribute("first-run", false);
  projectPromptEl.clear();
  mainEl.replaceChildren(projectPromptEl);
  projectPromptEl.focus();
}

/* Before the project list is in, the screen shows on trust, so a fresh load
   of a bad slug shows it briefly before the 404. */
async function showForProject(slug, el, signal) {
  const previous = store.state.currentProjectSlug;
  const notFound = () => {
    store.update({ currentProjectSlug: previous });
    showNotFound({ path: location.pathname });
  };

  if (!projectExists(slug)) {
    notFound();
    return;
  }

  store.update({ currentProjectSlug: slug });
  mainEl.replaceChildren(el);

  await projectsLoaded;
  if (signal.aborted) {
    return;
  }

  if (!projectExists(slug)) {
    notFound();
  }
}

/* The server has already answered with a 200, since it cannot tell a route
   from a typo; the 404 is only on screen. */
function showNotFound({ path }) {
  notFoundEl.setAttribute("path", decodeParam(path));
  mainEl.replaceChildren(notFoundEl);
}

navigation.addEventListener("navigate", (event) => {
  if (
    !event.canIntercept ||
    event.hashChange ||
    event.downloadRequest !== null
  ) {
    return;
  }

  const route = matchRoute(event.destination.url);
  if (!route) {
    return;
  }

  event.intercept({
    handler: () => {
      detailsEl.close();
      topbarEl.toggleAttribute("no-switcher", route.switcher === false);
      topbarEl.toggleAttribute("settings", route.settings === true);
      return route.show(route.params, event.signal);
    },
  });
});

/* ---------- changes reported by the elements ---------- */

boardEl.addEventListener("task-add", (event) => {
  addTask(event.detail.lane, event.detail.description);
});

boardEl.addEventListener("task-move", (event) => {
  const { taskId, lane, before } = event.detail;
  moveTask(taskId, lane, before);
});

boardEl.addEventListener("lane-clear", (event) => {
  clearLane(event.detail.lane);
});

boardEl.addEventListener("task-open", (event) => {
  openTask(event.detail.taskId);
});

boardEl.addEventListener("agents-pause", (event) => {
  setAiPaused(event.detail.projectId, event.detail.paused);
});

detailsEl.addEventListener("task-move", (event) => {
  const { taskId, lane, before } = event.detail;
  moveTask(taskId, lane, before);
});

detailsEl.addEventListener("task-edit", (event) => {
  editTask(event.detail.taskId, event.detail.description);
});

detailsEl.addEventListener("task-delete", (event) => {
  deleteTask(event.detail.taskId);
});

detailsEl.addEventListener("task-schedule", (event) => {
  scheduleTask(event.detail.taskId);
});

detailsEl.addEventListener("task-close", (event) => {
  taskClosed(event.detail.taskId);
});

settingsEl.addEventListener("settings-save", (event) => {
  saveSettings(event.detail);
});

settingsEl.addEventListener("project-delete", (event) => {
  deleteProject(event.detail.id);
});

newProjectEl.addEventListener("project-create", (event) => {
  createProject(event.detail);
});

projectPromptEl.addEventListener("project-draft", (event) => {
  draftProject(event.detail.description);
});

appSettingsEl.addEventListener("agent-draft", (event) => {
  draftAgent(event.detail.description);
});

appSettingsEl.addEventListener("agent-create", (event) => {
  createAgent(event.detail);
});

appSettingsEl.addEventListener("agent-save", (event) => {
  saveAgent(event.detail);
});

appSettingsEl.addEventListener("agent-enable", (event) => {
  setAgentEnabled(event.detail.id, event.detail.enabled);
});

appSettingsEl.addEventListener("agents-enable-all", (event) => {
  setAllAgentsEnabled(event.detail.enabled);
});

appSettingsEl.addEventListener("agent-delete", (event) => {
  deleteAgent(event.detail.id);
});

topbarEl.addEventListener("project-select", (event) => {
  navigation.navigate(projectPath(event.detail.slug));
});

topbarEl.addEventListener("chat-toggle", () => {
  toggleChat();
});

chatEl.addEventListener("chat-hide", () => {
  updateChat({ open: false });
});

chatEl.addEventListener("chat-new", () => {
  newChat();
});

chatEl.addEventListener("chat-select", (event) => {
  selectChat(event.detail.sessionId);
});

/* Only a tab the person closes ends its chat on the server: a deleted agent's
   chats are ended by the server itself. One still waiting for the reply to its
   first message has no session yet, and is ended once the reply brings it. */
chatEl.addEventListener("chat-end", (event) => {
  const session = store.state.chat.sessions.find((s) => s.id === event.detail.sessionId);
  if (session?.agentSessionId) {
    endAgentSession(session.agentId, session.agentSessionId);
  }
  endChats([event.detail.sessionId]);
});

chatEl.addEventListener("chat-pick", (event) => {
  pickAgent(event.detail.sessionId, event.detail.agentId);
});

chatEl.addEventListener("chat-send", (event) => {
  sendMessage(event.detail.sessionId, event.detail.text);
});

/* A route that names no project, such as the Taskavista settings, keeps the
   last one selected, even straight after a load. null only means no project is
   on screen, which is no reason to forget the last one that was. */
store.update({ currentProjectSlug: readSavedProjectSlug() });
store.watch(
  (state) => state.currentProjectSlug,
  (slug) => {
    if (slug !== null) {
      saveProjectSlug(slug);
    }
  },
);

/* The board shows the selected project once the list says which one that is.
   The project is looked up rather than built, so it keeps its identity until
   the selection or the list changes, and the lanes are fetched only then. */
store.watch(
  (state) =>
    state.projects.list.find((p) => p.slug === state.currentProjectSlug) ??
    null,
  (project) => {
    if (!keepBoard) {
      showBoard(project);
    }
  },
);

/* A project made elsewhere, such as by an agent in the chat or in another
   window, ends the first run: the root goes to it. */
store.watch(
  (state) => state.projects.list,
  (list) => {
    if (
      projectPromptEl.isConnected &&
      projectPromptEl.hasAttribute("first-run") &&
      list.length > 0
    ) {
      redirect("/");
    }
  },
);

/* An agent that has been deleted ends its chat. */
store.watch(
  (state) => state.agents,
  ({ status, list }) => {
    if (status !== "ready") {
      return;
    }
    const ids = new Set(list.map((a) => a.id));
    endChats(
      store.state.chat.sessions
        .filter((s) => s.agentId !== null && !ids.has(s.agentId))
        .map((s) => s.id),
    );
  },
);

const projectsLoaded = loadProjects();
loadAgents();
listenForChanges();

/* The navigate event does not fire for the page load itself, so the first
   route is taken by navigating to where the page already is. Every path the
   page is served at has a route, if only the not-found screen. The entry's
   state goes along, so a reload keeps a draft the project prompt put there. */
navigation.navigate(location.href, {
  history: "replace",
  state: navigation.currentEntry.getState(),
});
