---
name: taskavista-designs
description: Pull the Taskavista UI mockups down from Claude Design so a screen can be built or revised in the dashboard. Use when asked to build, finish, or change a Taskavista screen (board, search, avatar menu, project settings, new project, account settings), when someone refers to "the mockups" or "the designs", or when the styling of an existing screen needs checking against its source design.
---

# Pulling the Taskavista designs from Claude Design

The mockups are **not in this repo**. They live in a Claude Design project and are fetched with
the `DesignSync` tool. This skill is the retrieval path plus the traps that cost time the first
time round.

## The project

| | |
|---|---|
| Project ID | `a9f6efe6-4ce3-4154-8c46-de32ecdd4aa3` |
| URL | https://claude.ai/design/p/a9f6efe6-4ce3-4154-8c46-de32ecdd4aa3 |
| Type | `PROJECT_TYPE_PROJECT` (a regular design project) |

## How to fetch

1. **Load the tool** if it isn't in the tool list: `ToolSearch(query: "select:DesignSync")`.
2. **Authorize.** Every call fails without it. The error tells the user to run `/design-login`
   once from an **interactive** Claude Code session; a non-interactive session cannot run it.
   Relay that message and wait — do not work around it.
3. **Go straight to the UUID.** Do not call `list_projects` first: it is filtered to
   *design-system* projects, and this is a regular project, so it returns `[]`. That empty list
   means nothing is wrong.
4. `DesignSync(method: "list_files", projectId: "a9f6efe6-…")`
5. `DesignSync(method: "get_file", projectId: "a9f6efe6-…", path: "<file>")`

`get_project`, `list_files`, and `get_file` all work on this project when the UUID is passed
explicitly. `get_file` caps at 256 KiB; the canvases have so far been well under it.

## What is in the project

File names, canvas titles, and screen ids get edited in Claude Design, so this skill does not
record them. **Take them from `list_files` and the fetched canvases every time**, and refer to
screens by what they are (board, search, project settings, …), not by a remembered id.

The design content is the `.dc.html` canvases. Tell them apart by **content, not by name**:

- **The mockups** — the **visual source of truth**. Dark scheme, Figtree, and the first frame is
  a style tile naming the palette outright.
- **The wireframes** — the earlier light, hand-drawn sketch pass (Patrick Hand / Caveat). Use it
  for **structure and intent**, never for colour or type — it is a different, superseded visual
  language.

If the listing shows a canvas that is neither, or you cannot tell which is which, ask the user
rather than guess. Everything that is not a `.dc.html` (the canvas runtime `support.js`, the
`.thumbnail` preview) is platform furniture — never fetch it.

**When the two disagree, the mockups win on looks and the wireframes win on behaviour.**
The wireframes carry annotations the mockups drop — e.g. on search, that picking a result opens
that task's project board with the card highlighted, and on project settings, that the first
lane in the list is where new tasks land. Read the annotations on the wireframe of whatever
screen you are building.

## Reading a canvas file

Each `.dc.html` is one self-contained page. Every screen is a `<div class="dv-opt" id="…">`
whose `id` is the screen number, with a human label in the sibling `.dv-olabel`. Find a screen
by its label; the ids are renumbered as the canvas is reworked. Screen markup
uses **inline styles only**, so the exact values are right there.

**Trap: `dv-*` classes are canvas furniture, not app styles.** `.dv-turn`, `.dv-card`,
`.dv-opt`, `.dv-oid`, and everything in the `<helmet>` block belong to the Claude Design canvas
chrome — the card frame, the id badges, the page background. They are not part of Taskavista.
Copying them produces a design that looks subtly wrong. Take only what is inside a screen's
inline styles.

## Mapping a design into the app

The dashboard is a **D + vibe.d** server that serves `dashboard/public/` as static files. There
is deliberately **no JS build step and no node toolchain**, and no framework: the screen is
assembled from native web components in `dashboard/public/components/`, one `tv-thing.js` /
`tv-thing.html` pair per element, with `app.js` holding the data and nothing else. **Read
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
| In progress | — | `#E8B154` |
| Done | — | `#5FD6AB` |

`app.css` also carries the finer-grained ones — `--surface-input`, `--border-soft`,
`--border-card`, `--border-dashed`, `--text-2`, `--lane-label`, `--muted-2`, and the radii
`--r-ctl` / `--r-card`. Check the file for the current list before adding a token.

Typeface is **Figtree** (400/500/600, SIL OFL), loaded from Google Fonts in `app.css`.
Lane colours live in the seed data in `app.js`, not in CSS. The wider lane palette is the one
offered on the project settings mockup — take it from there.

## Current build state

Built: the **board**, the **project switcher**, **project settings**, **new project** (the
settings component in its `new` mode), the **agents strip** over the board of an AI-managed project, the **Taskavista settings**
screen with its list of AI agents and the **add and edit agent** dialog and its **quick-create an agent** tile, which has an agent draft one and opens it in the add dialog with its failure shown inside the tile, and the **task details** panel, its description editable in place (the
mockups have no editing state, so it borrows the lane composer's focus ring) and its "Delete task" button, and the **agent chat** panel with its
tabs, agent picker and the topbar's chat button and unread badge, as UI only: no agent answers yet, and the
mockups' "is working…" line is not drawn — see the component table in `docs/webcomponents.md` for
the current elements.

Not built: search. The search field in `tv-topbar` is rendered per the mockup but inert, with a
`title` tooltip saying it is not built yet. **When you build it, wire it up and drop its
tooltip.**

**Deliberately dropped — do not build from the mockups:** avatar menu and account
settings. Taskavista is a single-user app with no login for now, so there is no
identity to show and nothing to sign out of. The avatar was removed from the header on
2026-09-09. The mockups still show it; **the mockups are
out of date on this point and the code is correct.** Revisit only if multi-user lands.
(The avatar's `--accent-ink` token has since come back, as the text on accent buttons.)


## Do not run `/design-sync`

It pushes a *component library* up to Claude Design. It is the opposite direction and this repo
has no component library to push. Fetching designs is the `DesignSync` tool used directly, as
above.

## Verifying a screen

`cd dashboard && dub build && ./taskavista-dashboard`, then screenshot the screen at the
mockup's width and Read both images side by side. Follow the `taskavista-browser-check` skill.
A plain "screenshot at load" comes out incomplete, because the components define themselves
after the `load` event, so wait for the screen to render first. Say what you compared. A
screenshot shows layout and colour but not hover states or motion, so leave those to the user.
