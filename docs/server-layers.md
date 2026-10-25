# The server's layers

The dashboard server is split into three layers: controllers, services and repositories. A
request goes down through them in that order and never skips one: a controller calls a service,
and only a service calls a repository.

```
HTTP request
    │
 controller   api/rest.d, api/rpc.d     reads the request, answers in HTTP
    │
 service      service.d                 the rules: checks, multi-step writes, events
    │
 repository   repository/package.d      the interfaces
              repository/postgres.d     hand-written SQL against postgres
```

Each layer only knows the one below it, and only through what it needs. That keeps the rules
in one place, the services, whichever way a write arrives: the REST API, the RPC API, or, later,
an agent. A rule kept in a controller would hold for one API and not the other.

For how to add a resource across the layers, step by step, see the `taskavista-rest-api` skill.
For why the APIs are shaped as they are, see [rest-api.md](rest-api.md) and
[rpc-api.md](rpc-api.md).

## Controllers

`ProjectController`, `LaneController`, `TaskController`, `RuntimeController`, `AgentController`
and `DefaultController` in `api/rest.d`, and `RpcController` in `api/rpc.d`. A controller
implements its API interface, which vibe generates the routes from, and does three things:

- **It checks what is about the request itself**, and nothing about the data. That is a nil id in
  the path, a body of JSON `null` (`enforceBody`), or an RPC lane draft that carries an id where it
  must not. Each of these is answered with an HTTP error straight away.
- **It fits the request to the service**: it takes a resource's id from the path rather than the
  body, clears an id the body carries on a create, and turns the RPC's lane drafts into lanes.
- **It answers a service's failure in HTTP**, through `toHTTPError` in `api/errors.d`, which picks
  the status and message by the error's class. The overloads live there rather than in one API
  module, so that REST and RPC answer the same failure the same way.

A controller decides what runs in the background, as the code style asks.

A controller never calls a repository, and never publishes an event.

## Services

`ProjectService`, `LaneService`, `TaskService`, `AgentService`, `RuntimeService` and
`DefaultService`, all in `service.d`. A service holds the rules of its resource:

- **The checks on what may be written**: the schema's check constraints (`checkName`,
  `checkLane`, `checkTask`, `checkAgent`), the unique and foreign keys (`checkSlug`, the agent's
  runtime and model), and the rules of the board, such as a task never leaving its project. They
  run first, before anything is written, so that a bad write is an error rather than a failed
  insert.
- **Writes of more than one step**, as one method. `TaskService.move` checks the lane and the
  task to go above, moves the task and handles the race where that task leaves the lane;
  `ProjectService.save(ProjectWithLanes)` works out which lanes to delete. A controller or RPC
  call makes one service call, not the steps.
- **Reporting a write**: once a write has succeeded, the service publishes it through
  `IEventPublisher`, so that open web UIs show it (see [event-stream.md](event-stream.md)). A
  failed write reports nothing.

### Transactions and locks

A check and the write that relies on it are two statements, and another request, or an agent,
can write between them. Where that would leave the data other than asked for, the service runs
both in one transaction it opens through `ITransactional` (in `repository/package.d`), with the
rows its checks rely on locked, so that a write to them waits until it is done:

```d
return transactionally(transactions, {
    if (!projects.lock(lane.projectId))
    {
        return laneFailure!Lane(new ProjectNotFoundError);
    }
    // the checks and the write, as they would be without the transaction
});
```

- **`transactionally`** (in `service.d`) commits when the result the block returns is a success,
  and rolls back when it is a failure or the block throws. So a failure found after a write still
  undoes it.
- **A repository write that is a transaction of its own** (`addWithLanes`, the task writes, the
  agent with its labels) becomes part of the open one, and commits or rolls back with it.
- **Locks are taken in the order project, lane, task, agent.** Two transactions that keep to it
  never wait on each other in a circle: one just waits at the first lock they share. Every write
  to a project's lanes locks the project first, which is what keeps a project's lanes, which
  of them take new tasks, and their order still while a task is added or the project is saved. A
  deadlock means some transaction broke the order; postgres aborts it, the repository throws
  `Deadlock`, and the API answers 503 (see [rest-api.md](rest-api.md)) and logs it.
- **Nothing in a transaction starts a task of its own** (`runTask`). The open transaction is kept
  per vibe.d task, so work in another task would quietly run outside it, and could wait forever
  on its locks.
- **What is to happen only for a write that stands** goes through `ITransactional.afterCommit`:
  renaming a working directory, checking a project's index page, and every event, since
  `IEventPublisher` is a `CommittedEventPublisher` that holds each one back until the commit.
  Outside a transaction, `afterCommit` runs its delegate right away.
- **A clash no lock can prevent**, such as two new projects with one slug, is answered after the
  fact: the repository turns the database's refusal into `UniqueViolation` or
  `ForeignKeyViolation`, and the service catches it outside the transaction and answers as its
  check would have. One it does not catch is a 409 or 404 from `renderApiError`.

A service knows nothing of HTTP. Its methods return a `Result!(T, IXError)`, or an
`OperationResult!IXError` when there is no value, both from `result.d`, rather than throwing for
an outcome that is expected. A read that cannot fail, such as `getAll`, returns its value as is.

### Errors

Each kind of failure is a class of its own, implementing the error interface of every service
that can report it: `TaskNotFoundError : ITaskError`, or
`ProjectNotFoundError : IProjectError, ILaneError, ITaskError` for a failure several services
share. A class carries fields only for what the controller cannot know itself, such as
`NameTakenError.ownerName`, the name of the project that already has the slug. A service method's
`Returns:` lists the error classes it can fail with.

A class, rather than an enum member, is what lets an error carry data. The price is that nothing
checks that `toHTTPError` answers every class, so one without a branch there is answered with a
500.

Each service has a pair of private helpers, such as `taskSuccess` and `taskFailure`, which make
a result of the service's error interface. `failure(new TaskNotFoundError)` on its own would make a
result of the error's own class, which does not convert to the interface the method returns.

### Models and view models

A repository reads and writes **models**, in `model.d`: a model is a row of its table, with every
column of it, whether the APIs expose it or not, and nothing else. The controllers send and take
**view models**, in `viewmodel.d`: a view model is a resource as the web UI and the agents need
it, which may leave out a column (`Task.createdAt`), work a field out from several columns
(`TaskViewModel.workingAgentId`, from the task's agent status and agent and the task scheduler),
or from outside the database (`ProjectViewModel.canBeOpened`, from the working directory). The two
do not inherit from each other, and a field both have is declared in both.

The services map between them, so a controller never sees a model and a repository never sees a
view model. Their public methods take and return view models; inside, they work on models. The
mappings are `toViewModel` and `toModel` in `service.d`, or a method of the service when the
mapping needs a repository or the working directories, as `TaskService.views` and
`ProjectService.view` do. `toModel` copies only what a client may set, and a write answers with
the row as stored, mapped back, never with the body it was sent: a field the server sets, such as
`aiPaused` or `handedToAgents`, always shows what is stored.

### Service models

A service may read or write several resources together. The types for that are in
`servicemodel.d`, such as `ProjectWithLanes`, which `ProjectService.save` writes in one
transaction. They are made of view models, since they come from a controller.

## Repositories

Each resource has an interface in `repository/package.d`, such as `IProjectRepository`, with a
method per operation and the doc comments, and an implementation in `repository/postgres.d`,
`PostgresProjectRepository`, with the SQL. Nothing but `app.d` names a postgres class: it
registers each under its interface, and everything else asks for the interface. An exception a
caller is meant to catch, such as `PositionConflict`, is part of the interface and lives in
`package.d`.

A repository reports a miss as an empty `Nullable` or `false`, never as an error of its own; the
service turns that into the error class. The project, lane and task repositories each have a
`lock`, which only means something inside a transaction (see above).

Every postgres repository reaches the database through `PostgresConnections`, never through the
pool: it hands out the open transaction's connection when the task has one, and a pooled one
otherwise, and turns a unique or foreign-key violation or a deadlock into the exceptions
`package.d` names. It alone holds the `PostgresClient`. A repository call that took a pooled
connection while its task held a transaction would wait on that transaction's locks, and postgres,
seeing two sessions, would let it wait forever; with no pool to reach, that cannot be written. See the `taskavista-database` skill for the SQL side.

## Wiring

`DashboardContext` in `app.d` registers every repository under its interface, every service, and
every controller under its API. Poodinis builds each one with what its constructor asks for.
`EventStream` is registered under `IEventStream`, which serves the WebSockets, and
`CommittedEventPublisher`, which hands it each event once the write has committed, under
`IEventPublisher`, which the services publish to. `PostgresConnections` is made by a factory
method, as its connection string is config, and the one instance is registered both as itself,
for the repositories, and as `ITransactional`, for the services.

## Testing

The services are unit-tested in `service.d` against mocks of the interfaces they take: the
repositories, `IEventPublisher` and `ITransactional`, whose mock holds back what is to run after
the commit but undoes no write. A mock repository keeps its
rows in a `MockDatabase` in memory, and `MockEventPublisher` keeps the events it was told about,
so that a test can check both what was written and what was reported.

The locking cannot be unit-tested, since the mocks have no database. It is checked by hand against
postgres: hold the lock a fix relies on in a `psql` session, send the clashing request, and see it
wait and then answer as it should.

### Checking the locks by hand

Against a database of its own, so that no agent gets to work: create one
(`create database "taskavista-race"` through `-d postgres`, see the `taskavista-database`
skill), point a copy of `config-dev.json` at it with another port, start the server so it
applies the schema, then disable the seeded agents (`update agents set enabled = false`). Drop the
database afterwards.

Each check holds the clashing write open in a `psql` session in the background and sends the
request half a second later. The request must take about as long as the session sleeps, then
answer as shown:

| What | Held open in `psql` | Request | Answer |
|---|---|---|---|
| Project settings | `insert into lanes … (project P)`, sleep 3 | `saveProjectSettings` for P, without that lane | 200; P has only the lanes sent |
| Settings, project gone | `delete from projects where id = P`, sleep 3 | `saveProjectSettings` for P | 404 "No project has that id." |
| Lane positions | `select … from projects where id = P for update`, sleep 2 | two lanes created in P at once, no position | both 200, positions one after the other |
| Resuming agents | `update lanes set agents_pick_up = false where project_id = P` (P managed, paused), sleep 3 | `setAiPaused` P false | 409 none of P's lanes is one the agents pick up; P still paused |
| Rescheduling | `update lanes set marks_done = true` (the task's lane), sleep 3 | `rescheduleTask` (task declined, P managed) | 409 "The task is in a done lane, so it is done." |
| Rescheduling, task moved | lock P, sleep 1.5, move the task to a done lane, commit | `rescheduleTask`, sent after 0.3 s | 409 done lane: the lane it moved to was checked |
| New tasks | `update lanes set accepts_new_tasks = false` (P's second lane), sleep 3 | task created in P's second lane | 409 "The lane does not take new tasks." |
| Unique names | `insert into projects (…, slug 'rival2', ai_paused true)`, sleep 3 | `POST /projects` with slug `rival2` | 409 "Another project already has the slug 'rival2'." |
| Unique names | the same with slug `sails` | `createProject` named "Sails!" | 409 "A project called “Sails” already exists. Pick another name." |
| Unique names | `insert into agents (… 'Twin2' …)`, sleep 3 | `POST /agents` named Twin2 | 409 "An agent called “Twin2” already exists. …" |
| Lane gone | `delete from lanes where id = Z`, sleep 3 | `PUT /tasks/{id}` moving the task to Z | 404 "No lane has that id." |
| Deadlock | lock the task, sleep 1, then lock its lane | `rescheduleTask` on it, after 0.2 s | 503 with `Retry-After: 1`; the server logs the deadlock |

Also check that the events still reach a WebSocket on `/api/events/v1`: a lane created and the
agents paused each send one, and a refused `setAiPaused` sends none.

## The agent loops

`TaskScheduler` and `TaskExecutor` in `agent.d` read and write the repositories and publish
events themselves, rather than going through the services. That is by design. Where one of their
sequences checks and then writes, it uses `ITransactional` and the repositories' locks as a
service does, as `TaskScheduler.moveOn` does.
