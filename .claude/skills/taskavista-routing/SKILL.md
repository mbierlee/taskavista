---
name: taskavista-routing
description: Add, change or remove a route (a screen with its own URL) in the Taskavista web UI, and keep docs/routing.md in step with it. Use when a new screen is built (project settings, new project, account settings, search), when a screen needs its own URL or a link to it, when a component needs to navigate somewhere, when a redirect is needed, or when a URL loads the wrong screen or a 404. Covers the routes table in app.js, what a show function must do, route order, the no-dot rule the server imposes, and how to check a route in a browser.
---

# Adding a route to the Taskavista UI

Routing is client-side, with no library: `URLPattern` matches the routes and the Navigation API
intercepts navigations. `docs/routing.md` explains how it fits together, so read it first. This
skill is the procedure for changing what routes there are.

**The doc is part of the change.** `docs/routing.md` ends with a table of every route. Update it
in the same pass as the code.

## Adding a route

Everything is in the "routing" section of `dashboard/public/app.js`.

1. **Build the screen's element first**, following `docs/webcomponents.md`, and `import` it at
   the top of `app.js`. Create its instance once, at module level beside `mainEl`
   (`const settingsEl = document.createElement("tv-project-settings");`), not inside `show`.
   Then navigating away and back keeps the screen's state, the way the board keeps its lanes.

2. **Write the `show` function.** It receives the pattern's named groups and an `AbortSignal`:

   ```js
   /* What this screen is, and what the route does beyond showing it. */
   async function showAccount(params, signal) {
     mainEl.replaceChildren(accountEl);

     await projectsLoaded;
     if (signal.aborted) {
       return;
     }

     // ...whatever needs the data
   }
   ```

   A route under `/projects/:slug` hands the whole job to `showForProject`. It selects the
   project, shows the screen, and shows the not-found screen instead if there is no such
   project:

   ```js
   function showProjectSettings({ slug }, signal) {
     return showForProject(decodeParam(slug), settingsEl, signal);
   }
   ```

   - Put the element in `<main>` with `replaceChildren`, and do it before any `await`, so the
     screen changes straight away.
   - The groups are still percent-encoded: decode them with `decodeParam`, which leaves malformed
     encoding alone instead of throwing.
   - After every `await`, return if `signal.aborted`. The user may have navigated on, and a late
     `replaceChildren` or `redirect` would undo that.
   - Use `redirect(path)` to send the user elsewhere. It replaces the history entry, so back
     doesn't bounce into the redirect again.
   - A route that names no project leaves `currentProjectSlug` alone.
   - When a parameter names something that doesn't exist, show the not-found screen with
     `showNotFound({ path: location.pathname })`. Don't redirect somewhere else: the URL is wrong,
     and the user should see that.
   - Store writes happen here, in `app.js`, as always.

3. **Add the entry to `routes`:**

   ```js
   { pattern: new URLPattern({ pathname: "/projects/:slug/settings" }), show: showProjectSettings },
   ```

   **Order matters**, because the first match wins. The not-found screen isn't in the list:
   `matchRoute` falls back to it after every entry has missed, so nothing needs to go after it. A fixed path has to come before a pattern
   that would also match it: `/projects/new` goes above `/projects/:slug`, or "new" is taken as a
   project slug — and a project whose slug really is `new` becomes unreachable, so add such
   words to `reservedSlugs` in `api/checks.d` (`new` is there already) when adding a fixed path there.

4. **Give it a path helper** if other code will link to it, as `projectPath(id)` does, and
   `encodeURIComponent` each parameter in it.

5. **Link to it.** Use a plain `<a href="/projects/…/settings">` in a component; the navigate
   listener catches it, even inside a shadow root. Use an absolute href, because the page is
   served at every depth. A component must not call `navigation.navigate()` itself: it raises a
   `composed` event and `app.js` navigates, as with `project-select`.

6. **Add a row to the table in `docs/routing.md`:** the route, the screen, and any redirect it
   does.

## Rules a route has to follow

- **No dot in the last segment.** The server serves the page only for paths without a file
  extension (`serveUiRoutes` in `app.d`), so `/export/board.csv` would get a 404 on reload. Keep
  dots out of route paths and out of parameter values in that position. `isPagePath` in `app.js`
  mirrors this rule, so a change to one needs the same change to the other.
- **Nothing under `/api/`.** The server keeps that prefix for REST endpoints and never serves the
  page there.
- **No trailing slash.** `/projects/42/` doesn't match `/projects/:slug` and gets the not-found
  screen.
  Write links without the trailing slash.
- **Query strings aren't passed to `show`.** `matchRoute` hands over only the path groups. A
  route that needs `?q=` (search) should extend `matchRoute` and the navigate listener to pass
  `new URL(url).searchParams` along too, and every route should get the same signature.
- **No server change is needed.** A new route works on reload as long as it follows the rules
  above. Changing `app.d` means `dub build` and a restart.

## Removing or renaming a route

Remove the entry and its `show` function, and its import and element if nothing else uses them.
Search for links to it (`grep -rn '"/old-path' dashboard/public/`) and delete its row in
`docs/routing.md`. For a rename, keep the old URL working with a route whose `show` calls
`redirect()` to the new one, since people may have bookmarked it.

This redirect is only owed to URLs that a released version served. A URL that was added and
then changed within the same version needs no redirect, because nobody outside development has
had it. Taskavista has no versions yet, so it is all one version for now: rename or move a route
freely, and delete the old one without a redirect.

## Checking a route

Drive a browser and ask the page for its state, using the `taskavista-browser-check` skill
(its `browser-check.mjs` with `--wait` / `--eval` / `--goto`). Wait for the specific screen
element, not just `main > *`, because `index.html` already puts a `tv-board` there before the
router runs. For each URL check that:

- opening it directly lands on the right screen:
  `location.pathname`, and `[...document.querySelector("main").children].map(e => e.localName)`;
- a link or `navigation.navigate()` to it stays in the same document. Set `window.__marker = 1`
  first and check that it survives;
- `history.back()` returns to the previous screen;
- a path that isn't a route shows `tv-not-found` and keeps its URL;
- a bad parameter, such as an unknown project slug, shows `tv-not-found` and keeps its URL;
- a redirect, such as the one from `/`, replaced the entry in `navigation.entries()` rather than
  adding one.

Run `cd dashboard && dub run` for the server, and make sure the database is up
(`docker/run.sh -d`) if the route depends on projects.
