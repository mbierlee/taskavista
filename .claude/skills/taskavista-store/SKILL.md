---
name: taskavista-store
description: Add, change or remove state in the Taskavista web UI's store (dashboard/public/store.js), and keep docs/store.md in step with it. Use when a component needs data that is shared across the screen or sits inside another component's shadow DOM, when server data loaded by app.js has to reach a component, when a new key or a new watcher is added to the store, when the shape of an existing key changes, or when asked what is in the store. Covers the read/write split, the replace-don't-mutate rule, and the state table in docs/store.md that goes stale if it is not updated.
---

# Adding state to the Taskavista store

`dashboard/public/store.js` is a small Redux-like store: one frozen state object, `update(patch)`
to change it, `watch(select, callback)` to follow part of it. `docs/store.md` explains the design;
read it first. This skill is the procedure for changing what the store holds.

**The doc is part of the change.** `docs/store.md` ends with a table of every key in the state,
its shape, and which components watch it. Nothing checks that table against the code, so it goes
stale silently — and a stale one is worse than none, because it gets believed. Update it in the
same pass as the code, never afterwards.

## First: does it belong in the store?

Use the store for data that is shared across the screen, or that would otherwise have to be
passed through components that have no use for it — typically a component inside another
component's shadow DOM, which the page cannot reach.

Data a parent naturally owns still goes down as attributes or light-DOM children. A lane's
cards are children of the lane, and `slotchange` keeps its count right for free. Do not move
something into the store just because the store exists.

## Adding a key

1. **Declare it in `store.js`**, in the object passed to `new Store(...)`, with its initial value
   and a comment on anything not obvious from the shape — the allowed values of a status field,
   what a null means. Give it a real initial value (an empty list, a `"loading"` status), not
   `undefined`, so a watcher's first callback can render something.
2. **Write it from `app.js`, and only there.** Components never call `store.update`. If a
   component wants the state changed, it raises a `composed` event (see
   `docs/webcomponents.md`) and `app.js` listens for it and does the update.
3. **Build a new object for every change.** The freeze is shallow: pushing onto a nested array or
   assigning to a nested field does not throw, but watchers compare with `Object.is` and will not
   see it.

   ```js
   // Right
   store.update({ projects: { ...store.state.projects, status: "ready" } });

   // Wrong: no error, and nothing re-renders
   store.state.projects.status = "ready";
   ```

4. **Watch it from the component** in `connectedCallback`, and stop in `disconnectedCallback`,
   as `tv-project-switcher.js` does:

   ```js
   connectedCallback() {
     this.#unwatch = store.watch(
       (state) => state.things,
       (things) => {
         this.#things = things;
         this.#render();
       },
     );
   }

   disconnectedCallback() {
     this.#unwatch();
   }
   ```

   Import it as `../store.js` from a component and `./store.js` from `app.js`. A different URL
   for the same file (a query string, an absolute URL from elsewhere) loads a second store with
   its own state.

   Select only what the component uses. A selector that builds a new object or array on every
   call (`(s) => s.things.filter(...)`, `(s) => ({ a: s.a, b: s.b })`) fires the callback on every
   update of any key, because the result is never `Object.is`-equal to the last one. Select a
   stored value and derive from it inside the callback.

5. **Update `docs/store.md`** — add a row to the table under "What is in it": the key, its shape
   with the meaning of each field, and the components that watch it. If the key holds data from
   the server, say which endpoint it comes from, as the `projects` row does.

## Changing or removing a key

The table has to follow every one of these, not only additions:

- **The shape changes** (a field added, renamed, a status value added) → update its Shape cell,
  and every watcher that reads the changed field.
- **A component starts or stops watching a key** → update its "Watched by" cell. This is the one
  most easily missed, because the change is in a component, nowhere near `store.js`.
- **A key is removed** → delete its row, and check nothing still selects it:
  `grep -rn "state\.<key>" dashboard/public/`.

If the change moves data out of attributes or children and into the store, also update the
component's head comment and its row in the element table in `docs/webcomponents.md`.

## Check the table against the code

Before calling it done, compare the table in `docs/store.md` against the code:

```bash
grep -n "^  [a-zA-Z]*:" dashboard/public/store.js        # the keys declared
grep -rn "store.watch" -A1 dashboard/public/             # who watches what, app.js included
```

Every declared key should have a row, every row a declared key, and every "Watched by" entry a
matching `store.watch` call.

## Testing a store change in the browser

To drive the store from a WebDriver or other test script, run the update from inside the page,
for example by appending a `<script type="module">` that imports `/store.js`. An `import()` from
the WebDriver script's own context resolves to a separate copy of the module, so its updates
never reach the page's components, which looks exactly like a broken watcher.
