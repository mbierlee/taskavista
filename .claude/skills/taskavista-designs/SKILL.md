---
name: taskavista-designs
description: Pull the Taskavista UI mockups down from their claude.ai design canvas so a screen can be built or revised in the dashboard. Use when asked to build, finish, or change a Taskavista screen (board, search, project settings, new project, task details, Taskavista settings, agent chat — or the dropped avatar menu and account settings), when someone refers to "the mockups" or "the designs", or when the styling of an existing screen needs checking against its source design.
---

# Pulling the Taskavista designs from their canvas

The mockups are **not in this repo**. They live on a canvas, a claude.ai artifact of the Design
type, and are read with the `Artifact` tool. This skill is the retrieval path plus the traps that
cost time the first time round.

## The canvas

| | |
|---|---|
| URL | https://claude.ai/artifact/RaTEKKcKCc4CLHjvQ8NfKy |
| Type | Design (canvas), owned by the user, private |

(The old Claude Design project and its `DesignSync` tool are retired; the designs were moved to
this canvas.)

## How to fetch

1. **List the files**: `Artifact(action: "list", scope: "files", url: "<the canvas>")`.
2. **Read them**, several in one call: `Artifact(action: "read", url: "<the canvas>",
   paths: ["project/canvas.json", "project/mockups/…"])`. Small files come back inline, so there
   is no need to Read the saved copy; the copies land in the scratchpad, never in the repo.

No sign-in step is needed. **This skill only reads the canvas — never publish to it** unless the
user asks for a design change.

## What is on the canvas

File names, artboard titles, and screen numbers get edited, so this skill does not record them.
**Take them from the file listing and `project/canvas.json` every time**, and refer to screens by
what they are (board, search, project settings, …), not by a remembered number.

- **`project/canvas.json`** is the index. Its `boards` map each artboard file to a `title` that
  says which screen and which state it shows (e.g. "Task details — agent working on it"), and a
  `page`. Read it first and pick files by title.
- **One `.dc.html` per artboard**, one screen state each, under `project/`. The canvas has three
  pages:
  - **Mockups** (`project/mockups/`, plus `project/Main.dc.html`, the board) — the **visual
    source of truth**. Dark scheme, Figtree, 1000px wide.
  - **Wireframes** (`project/wireframes/`) — the earlier light, hand-drawn sketch pass (Patrick
    Hand / Caveat), one per mockup with the same number. Use it for **structure and intent**,
    never for colour or type — it is a different, superseded visual language.
  - **Brand** (`project/brand/`) — the style tile ("Type & color", naming the typeface and
    palette outright) and the wordmark.

If a file belongs to none of these, or you cannot tell which is which, ask the user rather than
guess. Everything outside `project/` (`index.html`, `SKILL.md`, `artifact-type/…`) is the canvas
editor itself — never fetch it.

**When the two disagree, the mockups win on looks and the wireframes win on behaviour.**
The wireframes carry annotations the mockups drop — e.g. on search, that picking a result opens
that task's project board with the card highlighted, and on project settings, that any lane
with Agents ticked makes the project AI-managed, and on task details, that Delete task asks for
confirmation first. They are the Caveat-script lines inside the frame, usually at its foot. Read
the annotations on the wireframe of whatever screen you are building.

## Reading an artboard file

Each `.dc.html` is one self-contained page holding one screen. The screen is the `<div>` inside
`<x-dc>`, and its markup uses **inline styles only**, so the exact values are right there.

**Trap: the rest of the file is canvas furniture, not app styles.** The `<helmet>` block (font
links for several unused families, `body{margin:0}`, the `a` colours), the `support.js` script,
and the `<script type="text/x-dc">` block with its `$preview` size belong to the canvas, not to
Taskavista. The `@keyframes` in the helmet are the exception: they are the motion the screens
use (`tvBorderWave` for a working card's border, `tvPulse` for the agents strip's dot). Take
only the screen's inline styles and those keyframes.

A few artboards are interactive (`is_interactive` in the index): their `<sc-if>` branches and
`{{…}}` holes show the states the screen moves between, such as the agents strip's
Pause / Resume.

## Mapping a design into the app

The dashboard is a **D + vibe.d** server that serves `dashboard/public/` as static files. There
is deliberately **no JS build step and no node toolchain**, and no framework: the screen is
assembled from native web components in `dashboard/public/components/`, one `tv-thing.js` /
`tv-thing.html` pair per element, and `app.js` holding the data, writing the store and routing
the URLs, but drawing nothing itself. **Read
`docs/webcomponents.md` before adding or changing a screen** — it has the conventions (attributes
down, `composed` events up, styles scoped inside each component) and the steps for adding an
element. A new screen is new components, not a new page of plain HTML/CSS/JS. Do not introduce a
bundler or framework without asking.

Tokens from the style tile already live at the top of `dashboard/public/app.css` as custom
properties, and they reach into every component's shadow root because custom properties
inherit. **Reuse them; do not paste raw hex into new rules.** The main ones:

| Role | Token | Value |
|---|---|---|
| App background | `--bg` | `#16181C` |
| Header, panels, done cards | `--surface-1` | `#1C1F24` |
| Cards, inputs | `--surface-2` | `#22262C` |
| Borders | `--border` | `#333842` |
| Primary text | `--text` | `#F2F4F6` |
| Secondary text | `--muted` | `#8A929E` |
| App accent · To do | `--accent` | `#8FA6FF` |
| In progress lane | — (data) | `#E8B154` |
| Done lane | — (data) | `#5FD6AB` |

`app.css` also carries the finer-grained ones — `--surface-input`, `--border-soft`,
`--border-card`, `--border-dashed`, `--text-2`, `--lane-label`, `--muted-2`, and the radii
`--r-ctl` / `--r-card`. Check the file for the current list before adding a token.

Typeface is **Figtree** (400/500/600, SIL OFL), loaded from Google Fonts in `app.css`.
Lane colours are not tokens but data, stored with each lane in the database. The colours a lane
can be given are `standardColors` in `tv-project-settings.js`, taken from the project settings
mockup, and a new project's starting lanes are in `app.js`.

## Current build state

Built: the **board**, the **project switcher**, **project settings** with its "Advanced" working directory, **new project** (the
settings component in its `new` mode), the **first run** screen (`tv-project-prompt`), which has an agent (Generic, or else a
task scheduler) draft a project to open on the new project screen (the mockups have no generating or failed state, so it
borrows the quick-create tile's) and is also the **quick-create project** screen the project switcher opens, the **agents strip** over the board of an AI-managed project, the **Taskavista settings**
screen with its list of AI agents, the **add and edit agent** dialog, and the **quick-create an
agent** tile, which has an agent draft one to open in the add dialog and shows a failure inside
the tile, the **working agent** indicator on a card (the moving border and the "AI" chip naming the agent, shown for the task scheduler too), the **task details** panel, its description editable in place (the mockups have no
editing state, so it borrows the lane composer's focus ring), its "Agent" section, its "Delete task" button and the "Schedule for AI" button beside it, and
the **agent chat** panel with its tabs, agent picker, and the topbar's chat button and unread
badge. Chats are answered by the agents; the mockups' "is working…" line is drawn as
"*agent* is answering" with animated dots. See the component table in `docs/webcomponents.md`
for the current elements.

Each agent card's **Disable** / **Enable**, the "Disabled · n" list with its **Re-enable all**,
and the heading's **Disable all** are built, as is the "Disabled" badge on a disabled agent in the
agent chat's "New chat" picker, where it can still be picked. The mockups show "Disable all" only with agents to
disable; with none enabled, it is drawn disabled, as a button with nothing to do is elsewhere.

Not built: search. The search field in `tv-topbar` is rendered per the mockup but inert, with a
`title` tooltip saying it is not built yet. **When you build it, wire it up and drop its
tooltip.**

**Deliberately dropped — do not build from the mockups:** avatar menu and account
settings. Taskavista is a single-user app with no login for now, so there is no
identity to show and nothing to sign out of. The avatar was removed from the header on
2026-09-09. The mockups still show it; **the mockups are
out of date on this point and the code is correct.** Revisit only if multi-user lands.
(The avatar's `--accent-ink` token has since come back, as the text on accent buttons.)


## Verifying a screen

`cd dashboard && dub build && ./taskavista-dashboard`, then screenshot the screen at the
mockup's width and Read both images side by side. Follow the `taskavista-browser-check` skill.
A plain "screenshot at load" comes out incomplete, because the components define themselves
after the `load` event, so wait for the screen to render first. Say what you compared. A
screenshot shows layout and colour but not hover states or motion, so leave those to the user.
