---
name: taskavista-rest-api
description: Add or change CRUD REST endpoints in the Taskavista dashboard. Use when asked to expose a table over HTTP, add or alter an /api/ endpoint, build a repository or service class for a resource, wire the web UI to real server data instead of the literal in app.js, or when a new table needs a D counterpart. Covers the four-part layout across the model, repository and rest modules, the Poodinis registration, and the vibe.web.rest traps that do not announce themselves.
---

# Adding CRUD REST endpoints to Taskavista

The projects resource is the **canonical implementation**: `Project` in
`dashboard/source/model.d`, `ProjectRepository` in `repository.d`, and `ProjectApi` and
`ProjectService` in `api/rest.d`. Everything below is derived from making it work. Read it before
writing a new one, and copy its shape rather than inventing a second style.

Schema changes are a different job — see the `taskavista-database` skill. This skill assumes the
table already exists.

**Documenting the endpoint is part of adding it.** `dashboard/public/rest-openapi.yaml`, an
OpenAPI spec, is the reference for what the server exposes; the `taskavista-rest-api-docs` skill says how to update it. Do it in the same
pass, not afterwards.

## The shape: four parts, split by layer

A resource has four parts, and they are split by layer rather than by resource: every PODO is
in `model.d`, every repository in `repository.d`, every REST interface and service in `api/rest.d`.
Within each module, a resource's parts sit together, in the order projects, lanes, tasks.

| Part | Role | Module | For projects |
|---|---|---|---|
| PODO | one row of the table, plus any enum and its converter | `model.d` | `Project`, `TaskAddRule`, `toTaskAddRule` |
| Repository | hand-written SQL against the pool, plus the private row converter | `repository.d` | `ProjectRepository`, `toProject` |
| REST interface | the wire contract vibe generates routes from, plus any body type of its own | `api/rest.d` | `ProjectApi` |
| Service | implements the interface over the repository, with the private checks only it needs | `api/rest.d` | `ProjectService`, `placeAtEndWhenUnplaced` |
| Checks | the `enforce…` validation of a resource's fields, which the RPC calls apply too | `api/checks.d` | `enforceNamed`, `enforceSlug`, `enforceValid` |

The dependencies run one way: `api/rest.d` and `api/rpc.d` import `api/checks.d`,
`repository.d` and `model.d`, but never each other; `api/checks.d` imports `repository.d` and
`model.d`; `repository.d` imports `model.d`; and `model.d` imports neither. A check that both
APIs need goes in `api/checks.d`, never in one API module for the other to import.

An operation that is not reading or writing one resource — moving a task, which renumbers its
neighbours, is the example — is not a REST endpoint but a call in `RpcApi`, in `api/rpc.d`,
mounted at `/api/rpc/v1`, and documented in `dashboard/public/rpc-openapi.yaml`. Every call is
`@method(HTTPMethod.POST) @path("<callName>")`, takes its arguments as plain parameters (vibe
reads a POST's parameters from the JSON body fields of the same name, so no `@viaBody` and no
body class), makes an argument optional by giving it a default value, and returns a result
struct, so success is a 200 with a body. **Keep a call lean**: arguments are ids and the values
the call needs, and the result is only what the call changed that the caller cannot already know
(`moveTask` returns the lane's task ids in their new order, not the tasks). Never take or return
whole resources — complete resources are what the REST API is for. Before adding a field to a
result, check that the UI actually reads it. `RpcService`
takes the repositories it needs through its constructor, like a REST service. The reasons behind each call's shape are in `docs/rpc-api.md`, and those behind the
resources in `docs/rest-api.md`; keep them in step when an endpoint or call changes.

Pure functions that do not belong to one layer — the checks that mirror the schema's check
constraints (`isSlug`, `isHexColor`), `slugify`, and the like — go in `helpers.d`, with their
unit tests. `helpers.d` imports none of the other modules.

There is **no ORM and no migration runner**. SQL is written out by hand in the repository.

## Steps

1. **PODO.** A `class` (not a struct — vibe needs to `new` it, and Poodinis resolves classes).
   Public fields matching the columns, camelCased. A default constructor plus convenience ones,
   all `@safe`.
2. **Repository.** Constructor takes `PostgresClient`. One method per operation, using
   `QueryParams` + `execParams`. Leave these `@system` — do not chase `@safe` down here.
3. **REST interface.** `@path("/api/rest/v1")` on the interface, explicit `@method` and `@path` on every
   method, every method `@safe`. Spelling out `@method` and `@path` keeps vibe from inferring
   them from the method name (`getProjects` → `GET projects`), so renaming a method cannot
   silently move its endpoint — and the names are free to be `listProjects`, `readProject`.
4. **Service.** Constructor takes the repository. Every override `@trusted`. A method that
   writes reports the write to the `ChangeFeed` (`dashboard/source/changes.d`) once it has
   succeeded, with the ids it concerns, so that an open web UI shows it: take the feed in the
   constructor and call, say, `changes.task(Change.created, created.id, projectId)`. A new kind
   of resource gets a method of its own on the feed, and a case in `applyChange` in `app.js`.
   See `docs/change-feed.md`.
5. **Register in `dashboard/source/app.d`**, inside `DashboardContext.registerDependencies`:

   ```d
   container.register!LaneRepository;
   container.register!(LaneApi, LaneService);
   ```

   then mount it in `main`, **before** the static catch-all:

   ```d
   router.registerRestInterface(container.resolve!LaneApi);
   router.get("*", serveStaticFiles("public/"));
   ```

   Poodinis injects the repository into the service, and the pool into the repository, through
   their constructors. Nothing needs `@Inject`.

6. **Document it in `dashboard/public/rest-openapi.yaml`** before calling the work done — a new
   tag, paths and schema, with real captured responses as examples. Follow the `taskavista-rest-api-docs` skill. An endpoint
   that ships undocumented is not finished.

## Method conventions

Repository method names and return types, as `ProjectRepository` has them:

| Operation | Signature | SQL |
|---|---|---|
| list | `T[] all()` | `select … order by <natural key>` |
| read | `Nullable!T find(UUID id)` | `select … where id = $1` |
| create | `T add(T item)` | `insert … returning id`, then assign `item.id` |
| update | `bool update(T item)` | `update … where id = $1 returning id` |
| delete | `bool remove(UUID id)` | `delete … where id = $1 returning id` |

**Use `returning id` on update and delete.** It is how the repository reports whether a row
actually matched, which is what the service turns into a 404. Do not reach for `cmdTuples`.

Bind every value with `query.argsVariadic(…)`. Never interpolate into `sqlCommand`.

Service methods map misses onto status codes with `enforceHTTP`:

```d
enforceHTTP(repository.remove(_id), HTTPStatus.notFound, "No lane has that id.");
```

## Traps

These all cost time on the projects resource. None of them produce an obvious error message.

- **vibe requires every REST interface method to be `@safe`.** The static assert names the
  method but not the cause. dpq2's `Answer` and `execParams` are `@system`, so `@safe` cannot
  reach the database. **Draw the boundary at the service: interface methods `@safe`, service
  overrides `@trusted`.** `@trusted` satisfies the requirement and is covariant with the
  interface. Marking the repository `@safe` does not work — do not try.
- **PODO constructors must be `@safe`** or deserialization fails inside `@safe` vibe code.
  Attribute inference does not apply to ordinary (non-template) functions, so write it out.
- **Every wire field a client may omit needs `@optional`** (`vibe.data.serialization`). Without
  it a `POST {"name":"x"}` is rejected with *"Missing non-optional field 'id'"*. `id` is always
  optional — the client has none when creating. Fields with defaults should be too. Leave the
  genuinely required ones alone so a missing one is still an error.
- **Mount the interface at `@path("/api/rest/v1")`, with the resource in each method path**
  (`@path("lanes")`, `@path("lanes/:id")`). vibe joins interface and method paths with a slash,
  so `@path("/api/rest/v1/lanes")` + `@path("/")` yields `/api/rest/v1/lanes/` — and plain `/api/rest/v1/lanes` then
  404s, which is the URL the front end will actually request. `@path("")` is rejected outright
  with *"Path is null or empty"*.
- **Path parameters need the underscore.** `:id` in the path, `UUID _id` in the method. This one
  is caught at compile time and says so plainly — *"Path contains ':id', but no parameter '_id'
  defined."* — so it is a trap only if the message is not read.
- **PUT and GET take non-path parameters from the query string, not the body.** A body parameter
  needs `@viaBody()` — with no argument, so the whole body maps to it. Without it, `PUT` silently
  looks in the query string.
- **An enumerated `text` column needs an enum plus a hand-written converter.** `std.conv.to`
  matches enum *member names*, so `to!TaskAddRule("first_lane")` fails on a
  `enum TaskAddRule : string { firstLane = "first_lane" }`. Copy the `toTaskAddRule` loop over
  `EnumMembers`. Going the other way, `cast(string)` is enough. On the wire vibe serializes such
  an enum as its **value** (`"first_lane"`) and validates on the way in, which is what you want.
- **Validate anything the schema's check constraints enforce, before the insert.** Otherwise a
  blank name surfaces as a failed insert (500) instead of a 400. `enforceNamed` in `api/checks.d`
  is the pattern.

## Debug builds report unexpected errors as 500

vibe's default `handleException` answers any exception that is not an `HTTPStatusException`
with **500 and a full stack trace in a debug build**, where a release build gives the status
the route chose. This is deliberate, not a bug.

The error handler both APIs share, `renderApiError` in `api/errors.d`, keeps that, with one
exception. A body, path id or argument that vibe cannot read (a missing field, a wrong type, a
bad enum value, a malformed UUID) is a 400 in both builds, with vibe's wording rewritten for
the caller (see `docs/rest-api.md`). So a 500 for one of those in a debug build is a real bug,
usually a vibe message the handler does not recognise yet. For anything else, check with
`dub build -b release` before concluding an error mapping is wrong.

## Verifying

Build, start the server in the background (it does not detach itself), and exercise every
endpoint with `curl`:

```bash
cd dashboard && dub build && ./taskavista-dashboard &
```

```bash
B=http://127.0.0.1:8080/api/rest/v1/lanes
curl -s $B                                     # 200, array
curl -s -X POST $B -H 'Content-Type: application/json' -d '{"name":"probe"}'
curl -s $B/<id>                                # 200
curl -s -X PUT $B/<id> -H 'Content-Type: application/json' -d '{"name":"probe 2"}'
curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/<id>
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/   # static files still 200
```

Check the 404 path (a random UUID), the 400 path (a blank required field), and that the static
catch-all still serves the board.

**Keep the output.** The responses captured here are what `rest-openapi.yaml` wants as examples,
so there is no second round of testing to write the documentation.

**Trap: create your own row to test against, and delete that.** Do not use a UUID from
`mock-data.sql` as a delete target — the seed file only reseeds an empty table, so a
deleted mock row does not come back and has to be reinserted by hand with its original id.

Confirm the table is as you found it when finished:

```bash
docker exec -i taskavista-postgres psql -U taskavista -d "$(jq -r .database.name dashboard/config.json)" -tAc 'select count(*) from lanes;'
```

(`lanes` throughout this section is a stand-in for whatever resource you are adding — there is no
lanes table yet. Substitute the real table name.)

## Formatting

D source is **tab**-indented. The editor has reformatted a D file to spaces at least once
while it was open; if a file comes back mixed, `unexpand -t 4` it and diff with leading
whitespace stripped to prove nothing but indentation moved.
