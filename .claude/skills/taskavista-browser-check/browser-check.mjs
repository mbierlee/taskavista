#!/usr/bin/env node
// Drive Microsoft Edge (Chromium) over the DevTools protocol to check a page.
// No dependencies: Node 22's built-in WebSocket and fetch are enough.
//
//   node browser-check.mjs [options] URL [steps...]
//
// Options (before or after the URL):
//   --headful          open a real window on $DISPLAY instead of running headless
//   --size WxH         viewport size, default 1400x900
//   --timeout MS       how long --wait polls before failing, default 10000
//   --keep             headful only: leave the window open when the steps finish
//
// Steps, run in the order given:
//   --wait JS          poll until the expression is truthy (fails the run on timeout)
//   --eval JS          evaluate and print the result as JSON (promises are awaited)
//   --click SEL        trusted mouse click at the centre of the element
//   --type TEXT        insert text into whatever has focus
//   --key KEY          press a key: Enter, Escape, Tab, Backspace, ArrowDown, ...
//   --sleep MS         wait a fixed time
//   --shot FILE        screenshot of the viewport, as PNG
//   --fullshot FILE    screenshot of the whole page, as PNG
//   --goto URL         navigate the same tab somewhere else
//
// Inside --wait / --eval, `deep(sel)` and `deepAll(sel)` find elements through open
// shadow roots, and SEL for --click uses deep() too. Console messages and uncaught
// exceptions from the page are printed as they happen, prefixed with "console." or
// "EXCEPTION". The exit code is 1 if a step failed or the page threw.

import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const argv = process.argv.slice(2);
let headful = false;
let keep = false;
let width = 1400;
let height = 900;
let timeout = 10000;
let url = null;
const steps = [];

for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--headful") {
    headful = true;
  } else if (a === "--keep") {
    keep = true;
  } else if (a === "--size") {
    [width, height] = argv[++i].split("x").map(Number);
  } else if (a === "--timeout") {
    timeout = Number(argv[++i]);
  } else if (a.startsWith("--")) {
    steps.push([a.slice(2), argv[++i]]);
  } else {
    url = a;
  }
}
if (!url) {
  console.error("usage: node browser-check.mjs [--headful] URL [--wait JS] [--eval JS] [--shot FILE] ...");
  process.exit(2);
}

const HELPERS = `
  const deepAll = (sel, root = document) => {
    const out = [...root.querySelectorAll(sel)];
    for (const el of root.querySelectorAll("*")) {
      if (el.shadowRoot) { out.push(...deepAll(sel, el.shadowRoot)); }
    }
    return out;
  };
  const deep = (sel) => deepAll(sel)[0] ?? null;
`;

const profile = mkdtempSync(join(tmpdir(), "browser-check-"));
const browser = spawn(
  "microsoft-edge",
  [
    ...(headful ? [] : ["--headless=new"]),
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    `--window-size=${width},${height}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-features=msEdgeSidebarV2,msUndersideButton,EdgeCollections",
    "about:blank",
  ],
  { stdio: "ignore" },
);

let failed = false;
function cleanup() {
  if (!(headful && keep)) {
    browser.kill();
    setTimeout(() => rmSync(profile, { recursive: true, force: true }), 500);
  }
}
process.on("exit", () => {
  if (!(headful && keep)) {
    browser.kill();
  }
});

// Chromium writes the port it picked into the profile once it is listening.
async function devtoolsPort() {
  for (let i = 0; i < 100; i++) {
    try {
      return readFileSync(join(profile, "DevToolsActivePort"), "utf8").split("\n")[0];
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  throw new Error("Edge never opened its DevTools port");
}

const port = await devtoolsPort();
const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = targets.find((t) => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r, j) => {
  ws.onopen = r;
  ws.onerror = j;
});

let nextId = 1;
const pending = new Map();
const listeners = [];
ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    const { res, rej } = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) {
      rej(new Error(msg.error.message));
    } else {
      res(msg.result);
    }
  } else if (msg.method) {
    for (const l of listeners) {
      l(msg);
    }
  }
};
const send = (method, params = {}) =>
  new Promise((res, rej) => {
    const id = nextId++;
    pending.set(id, { res, rej });
    ws.send(JSON.stringify({ id, method, params }));
  });

listeners.push(({ method, params }) => {
  if (method === "Runtime.consoleAPICalled") {
    const show = (a) => {
      if ("value" in a) {
        return typeof a.value === "string" ? a.value : JSON.stringify(a.value);
      }
      if (a.preview?.properties) {
        const array = a.preview.subtype === "array";
        const props = a.preview.properties.map((p) => (array ? p.value : `${p.name}: ${p.value}`));
        return array ? `[${props.join(", ")}]` : `{${props.join(", ")}}`;
      }
      return a.description ?? a.type;
    };
    const text = params.args.map(show).join(" ");
    console.log(`console.${params.type}: ${text}`);
  } else if (method === "Runtime.exceptionThrown") {
    const d = params.exceptionDetails;
    console.log(`EXCEPTION: ${d.exception?.description ?? d.text}`);
    failed = true;
  }
});

await send("Runtime.enable");
await send("Page.enable");
await send("Emulation.setDeviceMetricsOverride", {
  width,
  height,
  deviceScaleFactor: 1,
  mobile: false,
});

async function evaluate(expr) {
  const { result, exceptionDetails } = await send("Runtime.evaluate", {
    expression: `(async () => { ${HELPERS}; return await (${expr}); })()`,
    awaitPromise: true,
    returnByValue: true,
  });
  if (exceptionDetails) {
    throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
  }
  return result.value;
}

async function navigate(to) {
  const loaded = new Promise((r) => listeners.push((m) => m.method === "Page.loadEventFired" && r()));
  await send("Page.navigate", { url: to });
  await loaded;
}

const KEYS = {
  Enter: 13,
  Escape: 27,
  Tab: 9,
  Backspace: 8,
  ArrowUp: 38,
  ArrowDown: 40,
  ArrowLeft: 37,
  ArrowRight: 39,
  Delete: 46,
  Space: 32,
};

try {
  await navigate(url);
  for (const [name, arg] of steps) {
    if (name === "wait") {
      const t0 = Date.now();
      let ok = false;
      while (Date.now() - t0 < timeout) {
        ok = await evaluate(arg).catch(() => false);
        if (ok) {
          break;
        }
        await new Promise((r) => setTimeout(r, 50));
      }
      if (!ok) {
        throw new Error(`--wait timed out after ${timeout}ms: ${arg}`);
      }
      console.log(`wait ok (${Date.now() - t0}ms): ${arg}`);
    } else if (name === "eval") {
      console.log(`eval ${arg}\n  => ${JSON.stringify(await evaluate(arg))}`);
    } else if (name === "click") {
      const box = await evaluate(`(() => {
        const el = deep(${JSON.stringify(arg)});
        if (!el) { return null; }
        el.scrollIntoView({ block: "center" });
        const r = el.getBoundingClientRect();
        return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
      })()`);
      if (!box) {
        throw new Error(`--click: nothing matches ${arg}`);
      }
      for (const type of ["mouseMoved", "mousePressed", "mouseReleased"]) {
        await send("Input.dispatchMouseEvent", { type, ...box, button: "left", clickCount: 1 });
      }
      console.log(`clicked ${arg} at ${Math.round(box.x)},${Math.round(box.y)}`);
    } else if (name === "type") {
      await send("Input.insertText", { text: arg });
      console.log(`typed ${JSON.stringify(arg)}`);
    } else if (name === "key") {
      const code = KEYS[arg] ?? arg.toUpperCase().charCodeAt(0);
      const key = arg === "Space" ? " " : arg;
      const text = arg === "Enter" ? "\r" : undefined;
      await send("Input.dispatchKeyEvent", { type: "keyDown", key, windowsVirtualKeyCode: code, text });
      await send("Input.dispatchKeyEvent", { type: "keyUp", key, windowsVirtualKeyCode: code });
      console.log(`pressed ${arg}`);
    } else if (name === "sleep") {
      await new Promise((r) => setTimeout(r, Number(arg)));
    } else if (name === "shot" || name === "fullshot") {
      const { data } = await send("Page.captureScreenshot", {
        format: "png",
        captureBeyondViewport: name === "fullshot",
      });
      writeFileSync(resolve(arg), Buffer.from(data, "base64"));
      console.log(`screenshot ${resolve(arg)}`);
    } else if (name === "goto") {
      await navigate(arg);
      console.log(`navigated to ${arg}`);
    } else {
      throw new Error(`unknown step --${name}`);
    }
  }
} catch (e) {
  console.log(`FAILED: ${e.message}`);
  failed = true;
}

// Let late console output arrive before closing.
await new Promise((r) => setTimeout(r, 200));
ws.close();
cleanup();
process.exitCode = failed ? 1 : 0;
if (headful && keep) {
  console.log(`window left open (pid ${browser.pid}); kill it when done`);
  browser.unref();
}
