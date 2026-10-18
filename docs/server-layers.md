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

### Service models

A service may read or write several resources together. The types for that are in
`servicemodel.d`, such as `ProjectWithLanes`, which `ProjectService.save` writes in one
transaction.

## Repositories

Each resource has an interface in `repository/package.d`, such as `IProjectRepository`, with a
method per operation and the doc comments, and an implementation in `repository/postgres.d`,
`PostgresProjectRepository`, with the SQL. Nothing but `app.d` names a postgres class: it
registers each under its interface, and everything else asks for the interface. An exception a
caller is meant to catch, such as `PositionConflict`, is part of the interface and lives in
`package.d`.

A repository reports a miss as an empty `Nullable` or `false`, never as an error of its own; the
service turns that into the error class. See the `taskavista-database` skill for the SQL side.

## Wiring

`DashboardContext` in `app.d` registers every repository under its interface, every service, and
every controller under its API. Poodinis builds each one with what its constructor asks for. The
one shared instance is `EventStream`, registered under both `IEventPublisher`, which the services
publish to, and `IEventStream`, which also serves the WebSockets, so that what is published
reaches the sockets.

## Testing

The services are unit-tested in `service.d` against mocks of the interfaces they take: the
repositories and `IEventPublisher`. A mock repository keeps its
rows in a `MockDatabase` in memory, and `MockEventPublisher` keeps the events it was told about,
so that a test can check both what was written and what was reported.

## What is not layered yet

`TaskScheduler` and `TaskExecutor` in `agent.d` read and write the repositories and publish
events themselves, rather than going through the services.
