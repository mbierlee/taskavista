---
name: taskavista-rest-api
description: Add or change CRUD REST endpoints in the Taskavista dashboard. Use when asked to expose a table over HTTP, add or alter an /api/ endpoint, build a repository, service or controller class for a resource, wire the web UI to real server data instead of the literal in app.js, or when a new table needs a D counterpart. Covers the layered layout across the model, repository, service and rest modules, the Poodinis registration, and the vibe.web.rest traps that do not announce themselves.
---

# Adding CRUD REST endpoints to Taskavista

The projects resource is the **canonical implementation**: `Project` in
`dashboard/source/model.d`, `IProjectRepository` in `repository/package.d` and
`PostgresProjectRepository` in `repository/postgres.d`, `ProjectService` in `service.d`, and
`ProjectApi` and `ProjectController` in `api/rest.d`. Everything below is derived from making it
work. Read it before writing a new one, and copy its shape rather than inventing a second style.

**The API modules never call a repository.** Every REST controller and `RpcController` go
through the services, and a controller or RPC call never gains a repository call. (The agent layer,
`TaskScheduler` and `TaskExecutor`, still uses the repositories directly.)

Schema changes are a different job — see the `taskavista-database` skill. This skill assumes the
table already exists.

**Documenting the endpoint is part of adding it.** `dashboard/public/rest-openapi.yaml`, an
OpenAPI spec, is the reference for what the server exposes; the `taskavista-rest-api-docs` skill says how to update it. Do it in the same
pass, not afterwards.

## The shape: parts split by layer

Why the server is layered as it is, and what belongs in each layer, is in
`docs/server-layers.md`; this section is the where.

A resource's parts are split by layer rather than by resource: every PODO is in `model.d`,
every repository interface in `repository/package.d` and its postgres implementation in
`repository/postgres.d`, every service in `service.d`, and every REST interface and controller
in `api/rest.d`. Within each module, a resource's parts sit together, in the order projects,
lanes, tasks.

| Part | Role | Module | For projects |
|---|---|---|---|
| PODO | one row of the table, plus any enum and its converter | `model.d` | `Project`, `TaskAddRule`, `toTaskAddRule` |
| Service model | several PODOs written or read together | `servicemodel.d` | `ProjectWithLanes` |
| Repository interface | what can be read and written, documented in Ddoc; everything but `app.d` knows only this | `repository/package.d` | `IProjectRepository` |
| Postgres repository | hand-written SQL against the pool, plus the private row converter | `repository/postgres.d` | `PostgresProjectRepository`, `toProject` |
| Service | the rules a write must keep, such as the slug check, over the repository interfaces; reports failures as error classes, never as HTTP, and successful writes to the event stream | `service.d` | `ProjectService`, `IProjectError`, `NameTakenError` |
| REST interface | the wire contract vibe generates routes from, plus any body type of its own | `api/rest.d` | `ProjectApi` |
| Controller | implements the interface over the service, and turns its errors into HTTP ones | `api/rest.d` | `ProjectController` |
| Error answers | the status and message for each error class, shared by the REST and RPC controllers | `api/errors.d` | `toHTTPError` |
| Field checks | the schema's check constraints, checked before a write, each failure an error class | `service.d` | `checkName`, `checkLane`, `checkSlug` |

Every check of what may be written lives in the service, so that each way of writing, REST, RPC
or an agent, gets the same answer. A controller checks only what is about the request itself,
such as a nil path id, a body of JSON null (`enforceBody`), or an RPC lane draft that carries an
id where it must not.
`Result` and `OperationResult`, in `result.d`, are what a service method returns.

The dependencies run one way: `api/rest.d` and `api/rpc.d` import `api/errors.d`, `service.d`
and `model.d`, never each other and never a repository; `api/errors.d` imports `service.d` and
`model.d`; `service.d` imports the repository interfaces,
`result.d`, `servicemodel.d`, `helpers.d` and `model.d`; `repository/postgres.d` imports the
interfaces and `model.d`; and `model.d` imports none of them. Only `app.d` imports
`repository.postgres`, to register each implementation under its interface. A check that both
APIs need goes in the service, and an error answer both need in `api/errors.d`, never in one API
module for the other to import.

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
result, check that the UI actually reads it. `RpcController` takes the services it needs
through its constructor, like a REST controller, and a call that is several steps, such as
`moveTask`, is one service method (`TaskService.move`), not steps in the call. The reasons behind each call's shape are in `docs/rpc-api.md`, and those behind the
resources in `docs/rest-api.md`; keep them in step when an endpoint or call changes.

Pure functions that do not belong to one layer — the checks that mirror the schema's check
constraints (`isSlug`, `isHexColor`), `slugify`, and the like — go in `helpers.d`, with their
unit tests. `helpers.d` imports none of the other modules.

There is **no ORM and no migration runner**. SQL is written out by hand in the repository.

## Steps

1. **PODO.** A `class` (not a struct — vibe needs to `new` it, and Poodinis resolves classes).
   Public fields matching the columns, camelCased. A default constructor plus convenience ones,
   all `@safe`.
2. **Repository.** An interface `ILaneRepository` in `repository/package.d`, one method per
   operation, each with its Ddoc comment there; and its implementation
   `PostgresLaneRepository : ILaneRepository` in `repository/postgres.d`, whose methods carry no
   doc comments of their own. The implementation's constructor takes `PostgresConnections`,
   never the pool itself (see `docs/server-layers.md`), and its methods run their
   `QueryParams` + `execParams` in `connections.use`, or in `connections.transaction` for a write
   of several statements. Leave these `@system` — do not chase `@safe` down here. An exception a caller is meant to catch, such as `PositionConflict`, is part of the
   interface and goes in `package.d`.
3. **Service.** A class in `service.d` whose constructor takes the repository interfaces it
   needs. Its methods return a `Result!(T, ILaneError)`, or an `OperationResult!ILaneError` when
   there is no value, rather than throwing. Each kind of failure is a class implementing the
   resource's error interface (`TaskNotFoundError : ITaskError`), with fields only for what the
   controller cannot know itself, such as `NameTakenError.ownerName`. A kind of failure several
   services report is one class implementing each of their interfaces
   (`ProjectNotFoundError : IProjectError, ILaneError, ITaskError`), not a class per service. A
   service knows nothing of HTTP, and leaves running in the background to its caller (see
   `docs/code-style.md`). Document in each method's `Returns:` which error classes it can fail with.

   A method that writes reports the write to the `IEventPublisher` (`dashboard/source/eventing.d`)
   once it has succeeded, with the ids it concerns, so that an open web UI shows it whoever made
   the write: take the stream in the constructor and call, say,
   `events.project(Event.created, project.id)`. A failed write reports nothing. A new kind of
   resource gets a method of its own on `IEventPublisher`, and a case in `applyChange` in `app.js`.
   See `docs/event-stream.md`.
4. **REST interface.** `@path("/api/rest/v1")` on the interface, explicit `@method` and `@path` on every
   method, every method `@safe`. Spelling out `@method` and `@path` keeps vibe from inferring
   them from the method name (`getProjects` → `GET projects`), so renaming a method cannot
   silently move its endpoint — and the names are free to be `listProjects`, `readProject`.
5. **Controller.** Constructor takes the service. Every override `@trusted`. A failed result
   goes through the resource's `toHTTPError`, which picks the status and message by the error's
   class; give every error class a branch there, as nothing checks that one is missing, and an
   error without one comes back as a 500. The `toHTTPError` overloads are in `api/errors.d`, so
   that the RPC answers a service's errors as REST does. A controller reports no events; the
   service does.
6. **Register in `dashboard/source/app.d`**, inside `DashboardContext.registerDependencies`:

   ```d
   container.register!(ILaneRepository, PostgresLaneRepository);
   container.register!LaneService;
   container.register!(LaneApi, LaneController);
   ```

   then mount it in `main`, **before** the static catch-all:

   ```d
   router.registerRestInterface(container.resolve!LaneApi);
   router.get("*", serveStaticFiles("public/"));
   ```

   Poodinis injects the service into the controller, the repository into the service, and the
   pool into the repository, through their constructors. Nothing needs `@Inject`. Anything that
   takes a repository asks for the interface; registered this way, the postgres class cannot be
   resolved by its own name.

7. **Document it in `dashboard/public/rest-openapi.yaml`** before calling the work done — a new
   tag, paths and schema, with real captured responses as examples. Follow the `taskavista-rest-api-docs` skill. An endpoint
   that ships undocumented is not finished.

## Method conventions

Repository method names and return types, as `IProjectRepository` has them:

| Operation | Signature | SQL |
|---|---|---|
| list | `T[] all()` | `select … order by <natural key>` |
| read | `Nullable!T find(UUID id)` | `select … where id = $1` |
| create | `T add(T item)` | `insert … returning id`, then assign `item.id` |
| update | `bool update(T item)` | `update … where id = $1 returning id` |
| delete | `bool remove(UUID id)` | `delete … where id = $1 returning id` |

**Use `returning id` on update and delete.** It is how the repository reports whether a row
actually matched, which the service turns into a not-found error and the controller into a 404.
Do not reach for `cmdTuples`.

Bind every value with `query.argsVariadic(…)`. Never interpolate into `sqlCommand`.

Service methods, as `ProjectService` has them:

| Operation | Signature |
|---|---|
| list | `T[] getAll()` — nothing to fail, so no `Result` |
| read | `Result!(T, IError) get(UUID id)` |
| create or update | `Result!(T, IError) save(T item)` — creates when `item.id` is `UUID.init`, updates otherwise |
| delete | `OperationResult!IError remove(UUID id)` |

A controller turns a failed result into an HTTP error with `toHTTPError`, and answers what the
request itself gets wrong with `enforceHTTP`:

```d
auto created = service.save(project);
if (created.isFailure)
{
    throw toHTTPError(created.error, project);
}
```

## Traps

These all cost time on the projects resource. None of them produce an obvious error message.

- **vibe requires every REST interface method to be `@safe`.** The static assert names the
  method but not the cause. dpq2's `Answer` and `execParams` are `@system`, so `@safe` cannot
  reach the database. **Draw the boundary at the controller: interface methods `@safe`, controller
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
- **`failure(new SomeError)` makes a result of the error's own class.** `failure` infers its
  error type from the argument, so it gives a `Result!(T, ProjectNotFoundError)`, which does not
  convert to the `Result!(T, IProjectError)` the method returns; and `failure!IProjectError(…)`
  picks the `Result` overload rather than `OperationResult`. Give the service a pair of private
  helpers that take the error as the interface, as `projectFailure` and `projectSuccess` do, and
  use only those.
- **`save` reads the nil UUID as "create".** A `PUT` to `/lanes/00000000-0000-0000-0000-000000000000`
  would create a lane rather than miss. Reject a nil path id in the controller before calling
  `save`, as `replaceProject` does; and on create, clear any id the body carries, or `save` would
  update.
- **Validate anything the schema's check constraints enforce, before the insert.** Otherwise a
  blank name surfaces as a failed insert (500) instead of a 400. `checkName` and `checkLane` in
  `service.d` are the pattern: a private function returning the error, or null when the field is
  fine, called first thing in `save`. A check that applies to the rows of more than one service,
  as a lane's do, is a template on the error interface (`checkLane!ILaneError`), and its error
  classes implement each interface.

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

## Code style

Formatting, braces, imports and doc comments follow `docs/code-style.md`; read it before writing
the D side.
