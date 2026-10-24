# Routing in the dashboard UI

Each screen of the web UI has its own URL, such as `/projects/:slug`, and the routing happens in the
browser. There is no router library: the browser's `URLPattern` matches the routes, and the
Navigation API moves between them without reloading the page.

For how the screens themselves are built, see [webcomponents.md](webcomponents.md).

## The server's part

The server doesn't know the routes. After the static files, `serveUiRoutes` in
`dashboard/source/app.d` answers every other GET with `index.html`, so opening or reloading
`/projects/q3-finance` gets the page, and `app.js` works out the screen from there.

It skips two kinds of path, which get a plain 404 instead:

- anything under `/api/`: a mistyped endpoint shouldn't come back as HTML.

Before both, `/working-dirs/` serves the files in the projects' working directories, such as
the page the topbar's "Open project" opens, so it is not a path a route can have.
- anything whose last segment has a file extension (`/nope.js`): a missing file shouldn't
  either. This means a route must not end in a segment with a dot in it. If this rule changes,
  change `isPagePath` in `app.js` to match.

Because the same page is served at every depth, the asset paths in `index.html` are absolute
(`/app.js`, not `app.js`).

## The browser's part

The routing lives in the "routing" section of `dashboard/public/app.js`:

- **`routes`** is a list of `{ pattern, show }`. `matchRoute(url)` returns the first entry whose
  `URLPattern` matches the path, together with its parameters.
- **A `navigate` listener** intercepts every same-document navigation that has a matching route:
  link clicks (including links inside shadow roots), back and forward, and `navigation.navigate()`
  calls. It hands the route's `show(params, signal)` to `event.intercept()`.
- **The not-found screen:** a path the server would answer with this page, but that no route
  matches, gets `tv-not-found` at its own URL. `isPagePath` mirrors the server's rule for this. The
  server has already answered with a 200, because it can't tell a route from a typo, so the 404
  exists only on screen. Any other path, such as an `/api/` endpoint or a file, isn't intercepted
  and loads from the server like any other link.
- **`show` puts the screen in `<main>`** with `replaceChildren`, and does whatever the route
  implies for the store, for example setting `currentProjectSlug`. It can be async, and should
  check `signal.aborted` after each `await`, because the user may have navigated on in the
  meantime.
- **`showForProject(slug, el, signal)`** is the body of every route under `/projects/:slug`. It
  selects the project and shows `el`, or shows the not-found screen when there is no such
  project. Projects are named in URLs by their `slug` (see the `projects` table), never by their
  id. A slug may hold letters of any script, so `projectPath` and every link
  percent-encode it and the route decodes it with `decodeParam`; it never contains a dot or a
  slash, which the server and the schema both rule out.
- **`switcher: false`** on a route entry hides the topbar's project switcher while that screen
  shows, by setting `no-switcher` on `tv-topbar` before the route's `show` runs, and
  **`settings: true`** marks the topbar's gear as the screen showing, by setting `settings`.
- **`redirect(path)`** navigates with `history: "replace"`, so back skips the URL that was
  redirected away from.
- **The first route:** the `navigate` event doesn't fire for the page load, so on start-up
  `app.js` navigates to the URL it's already at. Every path the page is served at has a route,
  even if it's only the not-found screen.

Components don't navigate. They use a plain `<a href>`, or raise an event that `app.js` turns
into `navigation.navigate()`, as it does for `project-select`.

## Routes

| Route | Screen |
|---|---|
| `/` | Redirects to the last project shown (kept in localStorage), or the first project. With no projects at all it shows `tv-project-prompt`, to describe the first project for an agent to draft, with the topbar's project switcher hidden, and goes to the first project as soon as one is made, wherever it was made |
| `/settings` | `tv-app-settings`, the Taskavista settings, with the AI agents fetched fresh each time. Names no project, so the selection is left as it was. Marks the topbar's gear as current |
| `/projects/new` | `tv-project-settings` as the new project screen, a fresh draft with three starting lanes each time, or the draft an agent suggested on the project prompt, which is kept in the history entry's state (`draft`), so back, forward and a reload show it again; the topbar's project switcher hidden. Creating the project replaces this URL with its board. Comes before `/projects/:slug`, and `new` is a reserved slug on the server |
| `/projects/new/quick` | `tv-project-prompt` without `first-run`, the project switcher's "Quick-create project": the first run's prompt, for describing a project for an agent to draft alongside the others, emptied each time, with the topbar's project switcher hidden and a link back to the board. The draft opens on `/projects/new` as at first run |
| `/projects/:slug` | The board, with that project selected. An unknown slug gets the not-found screen |
| `/projects/:slug/settings` | `tv-project-settings`, with that project selected and its lanes loaded fresh. An unknown slug gets the not-found screen. Saving goes to the project's board; deleting the project redirects to `/` |
| anything else | `tv-not-found`, the 404 screen, for a path with no dot in its last segment and not under `/api/` |

Add a row when a route is added. The `taskavista-routing` skill has the procedure.
