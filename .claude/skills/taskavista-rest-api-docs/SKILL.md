---
name: taskavista-rest-api-docs
description: Update dashboard/public/rest-openapi.yaml and dashboard/public/rpc-openapi.yaml, the OpenAPI 3.1 specs that are the reference for Taskavista's REST endpoints and RPC calls. Use whenever an /api/rest/ endpoint or /api/rpc/ call is added, removed, renamed, or changes its request body, response shape, status codes or validation — and whenever asked what the API currently offers, since these specs are the answer. Pairs with the taskavista-rest-api skill, which covers writing the endpoints themselves.
---

# Keeping the API specs true

Two OpenAPI 3.1.0 documents are the reference for what the server exposes:

- `dashboard/public/rest-openapi.yaml` — the REST resources under `/api/rest/v1`.
- `dashboard/public/rpc-openapi.yaml` — the RPC calls under `/api/rpc/v1`.

They are the only ones: there is no markdown copy, so nothing else needs to be kept in step.
Being in `public/`, the server serves them at `/rest-openapi.yaml` and `/rpc-openapi.yaml`.
Each stands alone, with its own copies of the shared schemas (`Uuid`, `Color`, `Error`), so a
reader never has to follow a `$ref` into the other file.

Each is written for someone calling the API — an AI agent working on a board, which fetches
the specs from the server, a front-end developer, or `curl` — not for someone maintaining the
server. It documents the API only: not which clients call it, nor what the web
UI does with it. **Leave out anything a caller cannot observe or does not need**: D, vibe and
the source files the routes come from, table and column names, the database, how the server is
built or configured, and the debug-build behaviour. Those belong in the D source and in the
`taskavista-rest-api` skill; observable behaviour belongs here. **Leave out the reasons too**:
why a call returns what it does, why the server picks the slug, what a field lets the UI do.
State the rule a caller relies on, and put the reason in `docs/rest-api.md` or `docs/rpc-api.md`,
which are for whoever builds Taskavista.

**The spec is part of the change, not a follow-up.** An endpoint that ships undocumented is not
finished. Update its spec in the same pass that adds or alters the endpoint or call.

## What the REST spec is made of

In order, and keep the order:

1. **`info.description`** — what the API covers, that it is JSON both ways, the authentication
   situation, where the RPC API is, the missing trailing slash, that `PUT` is a full
   replacement, and the **Errors** section: the `statusMessage` shape and the status table.
2. **`servers`** — only the relative `/api/rest/v1`, which resolves against wherever the spec
   was fetched from.
3. **`tags`** — one per resource, whose description says what the resource *is* and the rules
   that span its endpoints (positions and gaps, `taskAddRule`, done-ness).
4. **`paths`** — grouped by resource, in the order projects, lanes, tasks, runtimes and models,
   agents, defaults. Path-level `parameters` for the ids.
5. **`components`** — `parameters` (the path ids), `schemas` (one per resource, plus the shared
   `Uuid`, `Position`, `Color` and `Error`), and `responses` (the reused failures, such as
   `NotFound`, `MalformedId`, `Deleted`, `ServerError`).

## The RPC spec

`rpc-openapi.yaml` has the same parts in the same order, with these differences:

- **`info.description`** states the rules every call shares — always `POST`, arguments are the
  JSON body's fields, ids and values in and out but never whole resources, success is 200 —
  then the Errors table.
- **`tags`** group the calls by what they act on (Tasks, Projects, Agents).
- **`paths`** has one `post` per call, at `/<call>`, in the order of `RpcApi` in `api/rpc.d`.
  The `operationId` is the call's name. The arguments are an inline body schema whose
  `required` lists the arguments with no default; the result is an inline schema too, unless
  two calls share it (`SlugResult`).
- **`components`** holds only what more than one call uses, or what is worth a name of its own
  (`NewLane`, `SavedLane`).

A call's `description` carries what the arguments alone do not say: what happens together or
not at all, what is deleted, what the result leaves out and where to read it instead. Why it
leaves it out goes in `docs/rpc-api.md`.

## Adding a resource

Copy the Projects tag, paths and schema wholesale and work through them. Every part carries
weight:

- **`operationId` is the D method name** in the REST interface (`listProjects`,
  `replaceLane`), so a reader can find the code from the spec.
- **A schema per resource, used for both request and response bodies.** Mark server-assigned
  fields, and fields the server ignores in a body, `readOnly: true` (`id`, `projectId`,
  `aiPaused`). List the fields a body must carry in `required`, and give an optional field its
  `default`.
- **Every field gets a `description`** that says what it is, and anything a type cannot say:
  how it is defaulted or derived, what is refused, how it is normalized (a colour comes
  back lowercased, a label is lowercased).
- **Nullable is `type: [integer, "null"]`**, the 3.1 way, never `nullable: true`.
- **Each operation has a `summary`**, and a `description` for anything a caller would not guess.
- **List every status the endpoint can return**, each with a description of when, not only in
  the Errors table. Reuse a `components/responses` entry when its description fits the endpoint
  exactly; write the response inline when the reasons are specific to it.
- **Give each request and response an `example`** (or `examples`, when there are several
  different cases, such as each 409).

## Examples must be real

Every example in the spec was copied from an actual response. Do not hand-write them, and do not
adjust a UUID to look tidier — a reader who sends the request should see what the spec says.
Lists may be shortened to a few items.

Capture them against the running server:

```bash
cd dashboard && dub build && ./taskavista-dashboard   # detached, then curl it
```

**Probe the failures hard.** The local database is for development, and bad-weather testing is
wanted: send malformed ids, missing fields, clashes and nonsense to every call you document, and
do not hold back for fear of breaking rows — the database can be recreated from scratch. A probe
that succeeds when it should have failed is a bug found, not an accident.

**Write examples against rows you created**, so a reader's mock data is not what the example
deletes or renames. A mock row that a test breaks does not come back on its own — `mock-data.sql`
only reseeds an empty table — so when the sample data has drifted too far, recreate the database
(see the `taskavista-database` skill).

The mock rows are safe to quote in `GET` examples, but their ids are only stable for as long as
the current database volume lives: `mock-data.sql` inserts with `gen_random_uuid()`, so
recreating the table (the `taskavista-database` skill's normal procedure) gives them new ids and
the ids in the examples stop matching. Leave them: the ids are illustrations, and stale ones are
no reason to edit the spec. Capture fresh responses when an example is being written or changed
for another reason, such as a new field or a changed response shape.

## Things that are easy to get wrong

- **`PUT` is a replacement, not a patch.** Any optional field left out of the body reverts to its
  default instead of keeping its stored value. Keep saying this on each `PUT` — it surprises
  people.
- **Document the release-build statuses.** A debug build (`dub run`) can answer an unexpected
  exception with 500 and a stack trace where a release build gives another status (see the
  `taskavista-rest-api` skill). The spec states the release status, and says nothing about
  debug builds.
- **Status codes are per endpoint.** `PUT` returning 404 rather than creating anything is worth
  stating on the `PUT`, not only in the table.
- **Quote YAML strings that need it**: colours (`"#8fa6ff"` — an unquoted `#` starts a comment),
  timestamps, status codes as keys (`"404"`), and any message containing `: ` or a quote.

## Check the specs

Each has to parse, and every `$ref` has to resolve:

```bash
for f in rest rpc; do python3 -I -c "
import yaml, sys
d = yaml.safe_load(open(sys.argv[1]))
def refs(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == '\$ref':
                x = d
                for s in v[2:].split('/'): x = x[s]
            else: refs(v)
    elif isinstance(o, list):
        for v in o: refs(v)
refs(d); print(sys.argv[1], d['openapi'], len(d['paths']), 'paths, refs ok')
" dashboard/public/$f-openapi.yaml; done
```

Then send each request the spec describes to a running server and confirm the response and
status match what is written. A spec that was true two endpoints ago is worse than no spec — it
gets believed.
