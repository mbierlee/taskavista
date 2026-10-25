# Taskavista

An agentic task board, where the tasks are worked on by AI agents.

Version 0.1.0 (WIP)  
Copyright 2026 Mike Bierlee  
Licensed under the terms of the MIT license - See [LICENSE.txt](LICENSE.txt)

## Building and running

You need:

- a [PostgreSQL](https://www.postgresql.org/) database, either your own or the one in `docker/`
- a D compiler ([DMD](https://dlang.org/download.html) or LDC) and [dub](https://code.dlang.org/)
- [Claude Code](https://claude.com/claude-code) (`claude` on the `PATH`), for the agents

With a local PostgreSQL, create an empty database and a user for it, and point the dashboard at
them in its config (see below). With [Docker](https://www.docker.com/), start PostgreSQL 18
(port 5432) and pgAdmin (http://localhost:5050) in the background instead:

```sh
docker/run.sh -d
```

Then build and start the dashboard:

```sh
cd dashboard
dub run
```

and open http://localhost:8080. On its first start against an empty database, the dashboard
creates the schema from `dashboard/sql/init.sql`. Build without running with `dub build`;
the binary goes into `dashboard/bin/debug/`, or into `dashboard/bin/release/` with
`dub build --build=release`.

The dashboard reads its settings from `dashboard/config.json` if it exists, and otherwise uses
built-in defaults that match the Docker database: database `taskavista-dev` on
`localhost:5432`, with user and password `taskavista`. Database settings go under `database` in
the config file; see `dashboard/config-dev.json` for its fields. To use another config file, pass it with
`--config`, such as the bundled development one:

```sh
dub run -- --config=config-dev.json
```
