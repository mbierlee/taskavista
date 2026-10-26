# The dashboard UI is native web components

No framework, no bundler, no npm. `index.html` loads `app.js` as an ES module, and the screen is
assembled from custom elements in `dashboard/public/components/`. Work with the platform here
rather than reaching for a library — most of what a framework would be doing for us is something
the browser already does, and the sections below are mostly about letting it.

## The current set

| Element | What it is |
|---|---|
| `tv-card` | One task. Its description is the element's own text content. Clicking it, or Enter or Space on it, opens the task in the details panel; `selected` marks the card whose task is open there, and `added` sweeps a glow in its lane's colour across a card just added, then removes itself. `flying` lifts a card above the others while the board flies it to another lane. `working-agent-id`, the task's `workingAgentId`, is the AI agent at work on it, the task scheduler included: its lane's colour sweeps along the card's border, and the agent is named under the description, from the store's `agents`. |
| `tv-lane` | A column of cards. Owns its heading, count, drop slot and "add a task" composer, and on a lane that marks tasks done, a "Clear" button that asks for confirmation before reporting it. |
| `tv-board` | The lanes laid out in a grid, plus the board head and dragging between lanes. `animateMoves(draw)` runs a function that draws cards again and slides each card it moved from its old place to its new one, so a move made elsewhere is seen to fly across the board; a card the function took off the board fades out where it was first, and the others close up after. |
| `tv-agents-bar` | The strip at the top of the board saying whether the project's AI agents are at work or paused, with the button that pauses or resumes them. Inside the board's shadow root. Watches `projects` and `currentProjectSlug` in the store, for the project's `aiPaused`, and `boardAgentLanes`, hiding itself unless a lane of the board is one the agents pick up; also `aiPausing`, and disables its button while the project's pause or resume is being saved. Only the first click of a double click counts, as the second would undo it. |
| `tv-topbar` | Wordmark (see [wordmark.md](wordmark.md)), project switcher, the "Open project" button, which opens the selected project's page in a new tab and shows only when the project has one (`canBeOpened`), search, the button that shows or hides the agent chat, and the ⚙ gear linking to the Taskavista settings (`/settings`). Search is inert for now. Its `no-switcher` attribute hides the switcher, for a screen about no project, and its `settings` attribute marks the gear current. Watches `chat` in the store, to mark the chat button while the chat shows and badge it with the replies not yet read. |
| `tv-agent-chat` | The agent chat, a panel down the right of the window beside every screen, which the board and the settings screens reflow to make room for: a tab per chat with an AI agent, the open chat's agent's runtime and model (its name is on the tab) and messages, and a `tv-text-box` to write in. "+" opens a "New chat" tab that lists the agents, with their runtime, model and effort level, to pick one, any of them, a disabled one too, which is drawn as an outline with a "Disabled" badge and "chat only", since an agent can be in several chats at once, each its own session (its chats after the first are numbered, and keep their number when another ends); ✕ on a tab ends that chat, and ✕ at the end of the row hides the panel. Shows `chat` and `agents` from the store, and keeps only the drafts, per chat. Sits in `index.html` beside `<main>`, in `.workspace`, so the routes leave it alone. No agent answers yet: a message sent is only shown. |
| `tv-not-found` | The 404 screen, for a URL no route matches. Its `path` attribute names that URL. |
| `tv-project-switcher` | The project chip and its menu (a `tv-menu`), inside the topbar. Watches `projects`, `currentProjectSlug` and `boardLoading` in the store, and disables the chip while the projects or the board's lanes are loading. The menu's "Project settings" entry links to the current project's settings, "+ New project" to `/projects/new`, and "✦ Quick-create project" to the project prompt at `/projects/new/quick`. |
| `tv-project-settings` | The project settings screen: name and, under it, description (free text, which can carry directions for the AI agents), then the lanes, a `tv-lane-row` each (rename, recolour with `tv-color-picker`, tick Intake, Closing and Agents, reorder, add, remove) under a head naming those columns, each with an "i" that explains it on hover or focus, plus deleting the project. The project has no AI setting of its own: it is managed by AI when any lane has Agents ticked. The head and the rows share their columns through `--lane-columns` and `--lane-gap`, which narrow with the screen. Edits a draft handed in with `edit()`, and reports it whole on save. Also the new project screen: `create(lanes, draft)` starts a draft of a new project from a set of starting lanes, and from the name, description, add-task rule and AI setting an agent suggested when `draft` is given, which tick the starting lanes' Intake and Agents boxes, and sets the `new` attribute, which drops the delete button and the task counts. Its back link reads "Back to AI setup" on the new project screen while there are no projects, as `/` then shows the project prompt. Watches `projects` in the store to check the name as it is typed, once typing pauses: a name another project has, or a reserved one, is marked under the field and disables saving. |
| `tv-project-prompt` | The screen a project is described on for an AI agent to draft: "What are you working on?" and a textarea to describe the project in, with "✦ Set up project", which raises `project-draft` (as does Enter; Shift+Enter starts a new line), and "Set up manually", a link to the new project screen. `generating` holds the screen while the agent drafts the project, with the button reading "Setting up…", and `error` shows why there is no draft under the textarea, which keeps what was typed and turns the button into "Try again". With `first-run` it is the first run's screen, shown at `/` in place of the board while there are no projects, and speaks of the first project; without it, it is the switcher's quick-create screen at `/projects/new/quick`, with "← Back to board" above it. `clear()` empties it for a new project, unless a draft is still being made. |
| `tv-app-settings` | The Taskavista settings screen, for what belongs to the whole app rather than one project: a column of sections (only "AI agents" so far) and the AI agents as cards, each with its runtime, its model, its effort level, for each task scheduler a "Scheduler" tag, and its labels, if it has any, under a divider; the schedulers come first. Each agent's "Disable" raises `agent-enable`; the disabled agents are listed after the rest under "Disabled · n", as dashed outlines with "Enable" in the accent beside "Edit". "Disable all" in the heading, disabled when no agent is enabled, and "Re-enable all" beside "Disabled · n" raise `agents-enable-all`. After the enabled agents comes the "Quick-create an agent" tile, whose "Generate" raises `agent-draft`; `generating` holds the tile while the draft is made, `openDraft(draft)` opens it in the dialog, and `draftError` shows why there is none inside the tile, which turns the button into "Try again" and keeps the description to be put right. `show(agents, runtimes, models, defaults)` fills it, `clear(message)` empties it. "+ Add agent" and each "Edit" open a `tv-agent-dialog`, whose events come up through it; `dialogSaving`, `dialogError` and `closeDialog()` reach the dialog from outside. |
| `tv-agent-dialog` | The modal dialog (a native `<dialog>`) an AI agent is added or edited in, inside the Taskavista settings screen: name, runtime, model — only those of the runtime picked — effort level — only those the model picked takes, `default` among them, which leaves it to the runtime — how many tasks it works on at once, as a row of segments (no limit, 1, 5, 10, 20, or "Custom…", which turns into a box for any other number) — its instructions, in a textarea — labels (a `tv-chip-list`, suggesting the labels other agents have, with how many have each) and whether it is a task scheduler (a `tv-toggle`). `add(runtimes, models, defaults, labels, draft)` opens it on a new agent at the default runtime, model and effort level, and 5 parallel tasks, or filled in from `draft` when one is given, `edit(agent, runtimes, models, defaults, labels)` on an existing one, with "Delete agent". It writes nothing and stays open on save, for the caller to close once the write has gone through or to show why it was refused. Closes on its ✕, Cancel and Escape. |
| `tv-task-details` | The task details panel, which slides over the right of the board and dims the rest, below the topbar: the task's lane, as a `tv-menu` that moves the task to the bottom of another lane, its description, edited in place in a `tv-text-box` (Enter or leaving the box saves it, Shift+Enter starts a new line, Escape undoes), the AI agent at work on it, under "Agent", its notes, a `tv-task-notes`, and "Delete task", which asks for confirmation first. A task in a lane the agents pick up (`agentsPickUp`) that was not yet handed to them (`handedToAgents`), outside a done lane, has "✦ Schedule for AI" beside "Delete task", which raises `task-schedule`. `show(task, lanes)` opens it, and `app.js` sets `notes` once they are loaded, and `workingAgentId` and `handedToAgents` when the task changes. Watches `agents` in the store, for the agent's name; whether the task's lane is one the agents pick up comes from the lanes `show()` is given. It closes on its ✕, on Escape, and on a click on the board around it. Sits in `index.html` just under the topbar, outside `<main>`, so the routes leave it alone. |
| `tv-color-picker` | The popover a lane's colour is chosen in, inside the settings screen: a grid of the colours on offer and a custom colour from hue and lightness sliders or a hex, kept to a readable range. `open(anchor, colors, color)` shows it; the caller keeps the list of colours on offer (the standard ones, those the project's lanes had when the screen opened, and custom ones chosen since). |
| `tv-menu` | A chip that opens a menu of items, one marked current, each with an optional lane dot. The chip shows the element's own content; `items` is set from script, and links slotted as `actions` go under a divider. `busy` disables the chip. Used by the switcher and the task details panel. |
| `tv-lane-row` | One lane in the settings screen's list: drag handle, name, colour swatch, the Intake, Closing and Agents checkboxes (its `intake`, `closing` and `agents` attributes), task count, remove button. It changes nothing itself and reports what was asked for; the settings screen owns the lanes, their order and the colour picker. Form-associated, so the settings form checks its name and its disabled fieldset disables it. |
| `tv-text-box` | A text box that grows with its text: Enter commits, Shift+Enter starts a new line, Escape backs out. What those do is the caller's: the lane's composer, the task description and the agent chat's message box all use it. `disabled` disables it. |
| `tv-task-notes` | A task's notes as a timeline, newest first, with a dot in the colour of the lane each change put the task in. |
| `tv-chip-list` | A field holding a list of short texts as `tv-chip`s, with a text box after them to add another; the agent dialog's labels. `values` is the list and `options` the values to suggest, as `{ value, hint }`; typing shows the matching ones in a `tv-chip-suggestions` under the field. Up and Down move through them, Enter adds one, Escape closes them without closing a dialog around it, and Backspace in the empty box removes the last chip. Its `lowercase` attribute lowercases what is typed, for values stored lowercase, as the agents' labels are. Form-associated, like `tv-toggle`. |
| `tv-chip` | One value in a `tv-chip-list`, as its own text content, with a ✕ that asks for it to be removed. |
| `tv-chip-suggestions` | The suggestions under a `tv-chip-list`, each with an optional hint, and "+ Create" for typed text that is new. The keyboard stays in the chip list's text box, which drives it with `move()` and `pick()`; a click picks a row without taking the focus. |
| `tv-toggle` | An on/off switch, labelled by its own content; `checked` is its state, as an attribute and a property. A click on it, Space or Enter flips it. It is form-associated, so a disabled `<fieldset>` around it disables it as it does a native input. |

Elements are all prefixed `tv-`.

## Anatomy of a component

Each one is a pair of files: `tv-thing.js` holds the class, `tv-thing.html` holds its shadow
markup and the `<style>` block that goes with it. Keeping the markup in a real `.html` file means
the editor treats it as HTML and CSS instead of as a string.

The JS fetches its own markup at module load, and gives itself a shadow root from it:

```js
import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-card.html");

// in the constructor
const root = attachTemplate(this, template);
```

`loadTemplate()` lives in `components/template.js` and resolves the name against *that* module's
directory, not against the page — `fetch` on its own would resolve a relative path against the
document and look in the site root. Templates therefore have to sit beside `template.js`.
`attachTemplate()` attaches the shadow root, adopts the shared stylesheet into it (see
[Styles](#styles-shared-first-then-the-components-own)) and clones the template in.

## How the pieces talk

Data goes **down** as attributes and light-DOM children, or through the store. Changes
come **up** as `CustomEvent`s marked `bubbles` and `composed` — `composed` is what lets them
cross the shadow boundary:

```js
this.dispatchEvent(new CustomEvent("task-add", {
  bubbles: true,
  composed: true,
  detail: { lane: this.laneId, description },
}));
```

The events in use: `task-add` and `lane-compose` from a lane, `lane-change` when its cards
change, `task-move` from the board when a card is dropped in a new place (its lane, and the card
it went above), `task-open` from a card that is clicked, `agents-pause` from the agents strip, `task-edit`, `task-move` again,
`task-delete` and `task-close` from the details panel, `project-select` from the switcher (`app.js` navigates to that project), `chat-toggle` from the topbar's chat button, `chat-hide`, `chat-new`, `chat-select`, `chat-end`, `chat-pick` and `chat-send` from the agent chat, `agent-draft`, `agent-enable` and `agents-enable-all` from the Taskavista settings screen, and `agent-create`, `agent-save` and `agent-delete` from the agent dialog, through that screen, `settings-save` and
`project-delete` from the settings screen, which raises `project-create` instead of `settings-save`
when it is the new project screen, `project-draft` from the project prompt, `color-input`, `color-pick` and `color-cancel` from the
colour picker inside it, `lane-rename`, `lane-recolor`, `lane-remove`, `lane-step` and `lane-flag` from its
lane rows, and `toggle-change` from a `tv-toggle` the user flips, and `chips-change` from a `tv-chip-list` the user adds to or removes from. Inside other components:
`menu-pick` from a `tv-menu`, `text-commit` and `text-cancel` from a `tv-text-box`, and
`chip-remove` from a `tv-chip` and `suggestion-pick` from a `tv-chip-suggestions`, both inside a
`tv-chip-list`; the switcher, the panel, the lane and the chip list turn these into their own
events and stop them there.

`app.js` owns the data and nothing else. It puts the projects in the store, fetches the
selected project's lanes and tasks and builds them as the board's children — a `tv-lane` per
lane, holding a `tv-card` per task — and then waits for those events. It keeps what it drew, so
on `task-move` it moves the task in that copy, re-renders the cards of the lanes involved, and
then tells the server; if the server refuses, it loads the board again. On `task-add` it creates
the task and appends its card once the server has answered, since a card needs its task's id. It
On `task-open` it opens the details panel on that task and fetches the task's notes; a move
of the open task, from the panel or the board, updates the panel's lane and fetches the notes
again. On `task-edit` it changes the card's text, then saves the description with a `PUT` of
the task as the server has it, since a full replacement needs a current position; if the save
is refused, it puts the old description back and the panel says why. On `task-delete` it deletes
the task on the server first, and only then removes its card, which fades out, and closes the panel; a refusal is
shown in the panel, under the button. Switching project or
screen closes the panel. It
marks the lanes that may take new tasks with `can-add` — only the first under the project's
`"first_lane"` rule — and only those offer the composer. Writes go to the server one at a time,
in order. On `agents-pause` it records the new state in the store's project list straight away,
without reloading the board, then saves it with the `setAiPaused` RPC call, and puts the old state
back if the save is refused. On `agent-create`, `agent-save` and `agent-delete` it writes the agent
with the agents endpoints, keeping the dialog open until the server answers, then closes it and
fetches the agents again; a refusal is shown in the dialog. On `agent-enable` it makes the `setAgentEnabled` RPC call, and on `agents-enable-all` the `setAllAgentsEnabled` one, and fetches the agents again, whether or not the call went through. It loads the agents into the store
on start-up, and again whenever the settings screen fetches them. The agent chat's events change
the store's `chat`, and nothing else yet: the chats live only as long as the page, an agent that is
deleted ends its chat, and a message sent is added to its chat without reaching the agent. Changes
made elsewhere, such as by an AI agent, come in over the event stream, and it fetches and draws them
as described in [event-stream.md](event-stream.md). It never reads state back out of the DOM.

### The store

Data that is shared across the screen, or would otherwise have to be passed through components
that do not use it, goes through `store.js` instead: components watch it directly, and only
`app.js` writes to it. See [store.md](store.md).

### Screens and routes

Each screen has its own URL, routed in the browser by `app.js`, which puts the screen's element
in `<main>`. See [routing.md](routing.md).

### Let components derive what they can

A lane counts the cards slotted into it on `slotchange`; the board sums its lanes. Nothing
passes a count to anything. Adding a card updates both numbers with no bookkeeping at the call
site, and there is no way for a count to drift from what is on screen.

This is worth reaching for whenever a component *could* work something out from what it was
given. It removes the update you would otherwise have to remember.

## Conventions worth keeping

**State is attributes, not classes** — `done`, `dragging`. CSS selects on them with
`:host([done])`, they show up in the inspector, and toggling one never touches the children.

**Never move the dragged card mid-drag.** A card that is detached while it is being dragged ends
the drag. The drop slot is what moves instead: it has to sit between cards, which are light-DOM
children, so it is a light-DOM child of the lane too — the one child a lane adds itself
(`showDropSlot` / `hideDropSlot`), styled with `::slotted(.drop-slot)`, and left out of the
count because it is not a `tv-card`. The board decides where it goes and only moves the real card
once the drop is over.

**Give a component the behaviour that is genuinely its own.** A lane owns its composer, so
opening one is not a board-wide re-render and the input keeps its focus for free. The board owns
dragging between lanes, because no single lane can. When something is hard to place, that is
usually a sign it belongs one level up.

**Re-render narrowly.** Each render swaps only the cards inside a lane, leaving the lane's own
state — an open composer, its focus — untouched.

## Styles: shared first, then the component's own

Styling comes from three places:

- **`app.css` holds the tokens**: every colour, tint, shadow and radius, as custom properties on
  `:root`. They reach into every shadow root because custom properties inherit. A component
  never writes a colour of its own; if it needs one that is not there, add a token.
- **`components/shared.css` holds what components share**: the reset (`box-sizing`, `[hidden]`,
  `font: inherit`, the focus outline), buttons, text fields, labels and the lane dot.
  `attachTemplate()` adopts it into every shadow root, so a component's markup just uses the
  classes:

  | Class | For |
  |---|---|
  | `btn primary` / `secondary` / `danger` | A form's main action, its Cancel (a link works too), a destructive action |
  | `btn danger-subtle` | A destructive action at the foot of a screen or panel, with a trash glyph before its text ("Delete project", "Delete task") |
  | `btn neutral` / `btn outline` | An action that is neither a form's main one nor its Cancel ("Pause agents", "Disable all") / one in the accent that hands something to the agents or brings it back ("Schedule for AI", "Re-enable all") |
  | `btn compact` | Added to the above inside a card or a heading (an agent's "Edit", a lane's "Clear"); every other button with a label is 32px high |
  | `btn quiet` | A full-width "+ Add …" row |
  | `btn ghost` / `btn icon` | A bare glyph in a row (handle, remove) / a glyph with a hover square (a panel's ✕) |
  | `link` | A link in running text, such as "← Back to board" |
  | `field`, `field-error` | A text input or textarea, and the message under one; `aria-invalid="true"` marks it |
  | `label` | The small uppercase heading over a field or section |
  | `dot` | A lane's colour, set as `--dot` |

- **The component's own `.html`** holds only what is particular to it: layout, sizes, and any
  tweak to a shared class (`.add-lane` adds a dashed border to `btn quiet`). A screen in
  `<main>` that changes its layout at a width does it with a container query on its host
  (`container-type: inline-size`), not a media query, since the agent chat can take part of the
  window beside it.

`shared.css` is all inside `@layer shared`, and a component's own `<style>` is not, so the
component always wins, whatever the specificity — without the layer, the adopted sheet would
come *after* the component's `<style>` and override it. A rule in `app.css` still cannot reach
inside a component. To style a part of a child component, the child exposes it with `part`
(`tv-menu::part(chip)`, `tv-text-box::part(field)`).

When two components draw the same thing, it goes into `shared.css` if it is only looks, and
into a component of its own if it has behaviour too (`tv-menu`, `tv-text-box`). A button is
only looks, which is why it is a class and not a `tv-button`: a submit button inside another
element's shadow root would no longer submit the form around it.

## Adding a component

1. `tv-thing.html` with a `<style>` block and the shadow tree, using the classes in
   `shared.css` wherever they fit; `tv-thing.js` with the class.
2. `await loadTemplate("tv-thing.html")` at module top level, `attachTemplate(this, template)`
   in the constructor, `customElements.define` at the bottom, and an `import` in `app.js` — or
   in the component that uses it, if only one does.
3. Attributes in, `composed` events out. Head comment naming the events it raises, as the
   existing components do.
4. Reach for `slotchange` before adding a field that would need keeping in sync.

## Gotchas

**Event targets are retargeted.** A listener above a shadow boundary sees the host, not the
inner element — which is why the board can delegate with `event.target.closest("tv-lane")` even
when the pointer is over a lane's heading. Drag events are `composed`, so this works for them
too.

**The board paints after `load`.** A component's top-level `await` for its template means
`customElements.define` runs after the load event. Headless screenshot tools capture at `load`
and will show a blank or half-drawn page — that is the tool, not a bug. To check a render, wait
for something the app draws before capturing: the `taskavista-browser-check` skill has a script
that does this.

**Templates fetch serially.** One module's top-level `await` blocks the next module's
evaluation, so the templates arrive one after another rather than together. Negligible
locally; if it ever matters, export a readiness promise per component and `await Promise.all`
in `app.js` so the fetches all start at once.
