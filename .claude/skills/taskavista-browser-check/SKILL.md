---
name: taskavista-browser-check
description: Verify a web UI change in a real browser on this machine, headless or headful — load a page, wait until it has actually rendered, read its state, click and type, capture console errors, and take screenshots to look at. Use whenever a change to the Taskavista UI (or any local web page) should be checked in a browser, when asked to screenshot a screen, compare it against a mockup, confirm a route, reproduce a UI bug, or check that nothing throws in the console. Covers which browsers and drivers are installed, a ready-made zero-dependency script, the Firefox/WebDriver alternative, and the traps (blank screenshots, snap sandboxing, shadow DOM selectors) that otherwise get rediscovered every time.
---

# Checking the UI in a browser

Everything below was tested on this machine. Use it instead of probing for tools: there is
**no Playwright, Puppeteer, Selenium or Chrome/Chromium**, and nothing needs installing.

| What | Where | Used for |
|---|---|---|
| Microsoft Edge 137 (Chromium) | `microsoft-edge` → `/opt/microsoft/msedge` | **The default.** Driven over the DevTools protocol by `browser-check.mjs` |
| Firefox 156 (snap) | `/usr/bin/firefox` | A second engine, one-shot screenshots |
| geckodriver 0.37 (snap) | `/snap/bin/geckodriver` | Driving Firefox over WebDriver with `curl` |
| Node 22 | `~/.nvm/...` | Has `WebSocket` and `fetch` built in, which is all the script needs |
| X11 display | `DISPLAY=:1` | Headful windows appear on the user's screen |

## Default: `browser-check.mjs`

The script beside this file launches Edge with a throwaway profile, runs a list of steps in
order, prints what happened, and exits 1 if a step failed or the page threw. About 3 seconds
a run. In the examples, `$SCRATCH` stands for your scratchpad directory.

```sh
node .claude/skills/taskavista-browser-check/browser-check.mjs http://localhost:8080/ \
  --wait 'deepAll("button.add").length === 4' \
  --eval 'location.pathname' \
  --click 'button.add' --type 'Write the report' --key Enter \
  --eval 'deep("tv-text-box.compose").value' \
  --shot "$SCRATCH/board.png"
```

| Step | Does |
|---|---|
| `--wait JS` | Polls the expression every 50ms until truthy; fails after `--timeout` (10s) |
| `--eval JS` | Prints the result as JSON. Promises are awaited, so `fetch(...).then(r => r.status)` works |
| `--click SEL` | Scrolls to the element and sends a **trusted** mouse click at its centre |
| `--type TEXT` / `--key KEY` | Inserts text into the focused element / presses `Enter`, `Escape`, `Tab`, `ArrowDown`… |
| `--shot FILE` / `--fullshot FILE` | PNG of the viewport / the whole page |
| `--goto URL` / `--sleep MS` | Navigate the same tab / wait a fixed time |

Options: `--headful` (a real window), `--size 1280x800` (default 1400x900), `--timeout MS`,
`--keep` (headful only: leave the window open for the user to look at; the pid is printed).

In `--wait` and `--eval`, **`deep(sel)` and `deepAll(sel)` search through open shadow roots**;
`--click` uses `deep`. Page `console.*` output is printed as `console.<level>: ...`, uncaught
exceptions as `EXCEPTION: ...`. An exception fails the run, so a clean exit also means the
page did not throw.

**Look at the screenshot.** Save it in the scratchpad and open it with the Read tool, which
shows images. A screenshot you did not look at verifies nothing.

## Headless or headful

Default to **headless**. It is invisible, fast, and gives identical pixels.

Use `--headful` only when the user asks to watch, or when something only happens in a real
window (focus/blur across windows, the OS file picker, native drag and drop). The window opens
on the user's desktop and takes focus for a moment, so say you're doing it. With `--keep` it
stays open until someone closes it.

A capture of the whole X display (`import -window root out.png`, ImageMagick) also works, but
it records everything on the user's screen. Don't do it unless they ask.

## Traps

- **Wait for something the app does, not for load.** Every tool that captures "when the page
  has loaded" races the app. Taskavista's components define themselves after `load` (top-level
  `await` for their templates) and the board's lanes arrive after an `/api/` fetch. Edge's
  one-shot `--screenshot` caught the topbar and heading but no lanes. `--virtual-time-budget=5000`
  fixed that run, but only a `--wait` on a real condition is reliable.
- **Don't wait on what the static HTML already has.** `index.html` ships a `<tv-board>` inside
  `<main>`, so `--wait 'document.querySelector("main > *")'` passes before the router runs,
  even on a 404 URL. Wait for the specific element: `main > tv-not-found`, or lanes in the board.
- **Selectors don't cross shadow boundaries.** `deepAll("tv-lane button.add")` finds nothing,
  because the button is in the lane's shadow root, where `tv-lane` is not an ancestor. Use
  `deepAll("button.add")`, or step in yourself:
  `document.querySelector("tv-lane").shadowRoot.querySelector("button.add")`.
- **Attributes are strings.** The project switcher sets `aria-current="false"` on the items that
  aren't current, and `"false"` is truthy, so `getAttribute("aria-current") ? ...` marks every
  item current. Compare with `=== "true"`, or use `hasAttribute` for boolean attributes such as
  `done` or `hidden`.
- **A step that "works" can still change nothing.** The composer example above types a task and
  presses Enter, but no `tv-card` appears, because `app.js` does not handle `task-add` yet. Read
  back the state you expected, and check the code before calling a missing result a bug.
- **The Firefox snap cannot see `/tmp`**, and the scratchpad is under `/tmp`. Firefox fails
  with "Could not find profile folder", or writes a screenshot nobody can find. Give Firefox
  paths under `~/snap/firefox/common/` and copy results out. WebDriver screenshots come back as
  base64 over HTTP, so they are not affected.
- **geckodriver rejects curl's default content type** ("Invalid Content-Type"). Always pass
  `-H 'Content-Type: application/json'`.
- **Firefox's `-width`/`-height` set the outer window.** A 1400x900 window gave a 1348x763
  viewport headful and 1400x814 headless. Edge through the script sets the viewport exactly.
- **Dropping a card writes to the database.** Moving a card on the board saves it through
  the `moveTask` RPC (`POST /api/rpc/v1/moveTask`), which also renumbers the tasks it lands above. A test that drags
  cards around leaves the sample tasks in new lanes and positions. That is fine: the mock data
  is there to be tested on, so there is no need to put it back. Native
  drag and drop cannot be driven headless with `--click`, but dispatching `DragEvent`s built
  with `new DataTransfer()` at the card and lane (`dragstart`, `dragover` with a `clientY`,
  `drop`, `dragend`) exercises the board's handlers.

## Firefox, when a second engine matters

For a rendering or API difference between engines. Over WebDriver with curl:

```sh
geckodriver --port 4444 >"$SCRATCH/gd.log" 2>&1 & GD=$!; sleep 1
W=http://localhost:4444; J=(-s -H 'Content-Type: application/json')
SID=$(curl "${J[@]}" $W/session -d '{"capabilities":{"alwaysMatch":{"moz:firefoxOptions":{"args":["-headless","-width=1400","-height=900"]}}}}' | jq -r .value.sessionId)
curl "${J[@]}" $W/session/$SID/url -d '{"url":"http://localhost:8080/"}' >/dev/null
# execute/async: the last argument is the callback. Poll until rendered, then report.
curl "${J[@]}" $W/session/$SID/execute/async -d '{"script":"const done = arguments[arguments.length - 1]; const t0 = Date.now(); (function poll() { const n = document.querySelectorAll(\"tv-lane\").length; if (n || Date.now() - t0 > 8000) { done({ path: location.pathname, lanes: n }); } else { setTimeout(poll, 50); } })()","args":[]}' | jq -c .value
curl "${J[@]}" $W/session/$SID/screenshot | jq -r .value | base64 -d >"$SCRATCH/firefox.png"
curl "${J[@]}" -X DELETE $W/session/$SID >/dev/null; kill $GD
```

Drop `-headless` for a visible window. `execute/sync` takes a `"script"` with a `return`. The
session starts in about 2 seconds, and deleting it closes Firefox.

Quickest of all, with no waiting (so only for pages that are static by `load`):
`firefox --headless --no-remote --window-size=1400,900 --screenshot ~/snap/firefox/common/x.png URL`.
The Edge equivalent is
`microsoft-edge --headless --disable-gpu --user-data-dir="$SCRATCH/edge" --window-size=1400,900 --virtual-time-budget=5000 --screenshot="$SCRATCH/x.png" URL`.
Swap `--screenshot=...` for `--dump-dom` to print the DOM after the scripts have run.

## Taskavista specifics

- The server must be up. `curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/` should
  print 200. If it was already up, it belongs to the user: use it and leave it running.
- **If you start the server, you shut it down.** When the check is finished, whether it passed
  or failed, stop everything you started, and nothing you didn't. Start the built binary
  directly and keep its pid. Don't use `dub run`, which leaves a `dub` parent between you and
  the server:

  ```sh
  (cd dashboard && dub build -q)
  (cd dashboard && exec ./taskavista-dashboard >"$SCRATCH/dashboard.log" 2>&1) &
  echo $! >"$SCRATCH/dashboard.pid"
  for i in $(seq 50); do curl -s -o /dev/null http://localhost:8080/ && break; sleep 0.2; done

  # ... the checks ...

  kill "$(cat "$SCRATCH/dashboard.pid")" && rm "$SCRATCH/dashboard.pid"
  ```

  If the start and the checks happen in separate Bash calls, start the server with the Bash
  tool's `run_in_background`, so it outlives the call. Afterwards, `ss -ltn | grep :8080` should
  print nothing.
- Screens that list projects also need the database. If `docker compose -f docker/docker-compose.yml ps`
  shows it isn't running and you start it with `docker/run.sh -d`, stop it the same way when you
  are done: `docker compose -f docker/docker-compose.yml stop`. Use `stop`, not `down`, which
  also removes the containers.
- `/` redirects to the first project's board, e.g. `/projects/q3-finance`. For a route, check
  `location.pathname` and `document.querySelector("main").firstElementChild.localName`. The
  `taskavista-routing` skill lists the rest of a route check.
- Rendered-board condition: `deepAll("button.add").length === <lane count>`, or
  `document.querySelectorAll("tv-lane").length > 0` if you only need the data to be in.
- To compare with a mockup, screenshot at the mockup's width with `--size` and Read both images.
  The `taskavista-designs` skill fetches the mockups.
