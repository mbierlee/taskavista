---
name: taskavista-database
description: Make schema or data changes to Taskavista's postgres database. Use when asked to add, drop, or alter a table, column, constraint, index or type, when the seed/sample rows need changing, when something needs querying or checking in the database, or when a change to dashboard/sql/init.sql or mock-data.sql is involved. Also covers how to reach the database at all, since there is no local psql.
---

# Changing the Taskavista database

## The database

| | |
|---|---|
| Container | `taskavista-postgres` (postgres 18, from `docker/docker-compose.yml`) |
| Database | `taskavista-dev`, from `dashboard/config-dev.json` — read it from there. **Never `taskavista`**: that is the installed (production) database, which `config-default.json` and the server on port 8090 use; touch it only when the user asks |
| User / password | `taskavista` / `taskavista` |
| Port | 5432 (pgadmin on http://localhost:5050) |
| Schema | the default `public` — put everything there unless told otherwise |

## Reaching it

**There is no psql client on this machine.** Everything goes through the container, into the
development database, whose name is read from `dashboard/config-dev.json` (run from the repo
root; shell variables do not survive between commands, so read it in each one). There is
usually no `dashboard/config.json`:

```bash
docker exec -i taskavista-postgres psql -U taskavista -d "$(jq -r .database.name dashboard/config-dev.json)" -v ON_ERROR_STOP=1 -c '\d projects'
docker exec -i taskavista-postgres psql -U taskavista -d "$(jq -r .database.name dashboard/config-dev.json)" -v ON_ERROR_STOP=1 < dashboard/sql/init.sql
```

To drop and recreate the database, connect to `-d postgres` instead, since postgres will not drop
the database you are connected to.

Use `-i` and redirect a file in rather than pasting SQL into `-c`; `-v ON_ERROR_STOP=1` so a
failed statement does not scroll past unnoticed. Check the container is up first
(`docker ps`) — if it is not, `docker/run.sh -d`.

## Where the SQL lives

- **`dashboard/sql/init.sql`** — the **whole** initial DDL, one file. The user's explicit call:
  **not** numbered migration files. While the schema is still "initial", a change means
  **editing this file**, not appending `002_…sql`. It sits in `dashboard/` because the
  dashboard applies it itself, see below.
- **`mock-data.sql`** (repo root) — sample rows, deliberately kept out of the DDL so the
  schema can be created empty. Written to be re-runnable: it seeds an empty table and does
  nothing otherwise.

**`init.sql` runs on start-up, but only into a database that is completely empty.**
`source/schema.d` applies it when postgres holds no schema of its own and an untouched
`public` — which is what a fresh volume comes up as, since nothing is mounted
into the image's `/docker-entrypoint-initdb.d`. A database that already has the table is left
alone, so **editing `init.sql` changes nothing by itself**: a changed schema still has to be
applied by hand. `mock-data.sql` is never run by the application. Do not claim a change is
live until you have actually run it against the container.

## Making a change

1. Edit `dashboard/sql/init.sql` so it describes the schema you want *from scratch*.
2. Drop the objects you are replacing, by name:
   `... -c 'drop table if exists projects cascade;'`
3. Re-apply `init.sql`, then `mock-data.sql` if the data is wanted back.
4. Verify with `\d <table>` and a `select`, and paste the real output.

**Reseeding hands out new ids.** `mock-data.sql` inserts with `gen_random_uuid()`, so the mock
rows come back with different ids every time the table is recreated. `dashboard/public/rest-openapi.yaml`
quotes mock-row ids in its `GET` examples, and they go stale the moment you reseed. That is fine: the
ids there are illustrations, and stale ones are not a reason to touch the spec. Do not recapture
them, or offer to, after a reseed.

Recreating rather than `ALTER`-ing is the point: it proves `init.sql` alone produces the
schema, instead of leaving the live database in a state no file can reproduce. This is only
safe because the database holds nothing but sample rows — **the moment it holds anything real,
stop and ask** rather than dropping.

**Trap:** a schema-wide reset (`drop schema public cascade`) is refused by the permission
classifier as destructive. Drop the specific tables instead; if a full reset is genuinely
needed, ask the user to run it.

## Writing the DDL

- **No design-mock-up references and no business-logic prose in the SQL.** The schema outlives
  the mock-ups and is read by people who have never seen them. Comment only what SQL cannot
  say; column names and check constraints carry the rest. Design rationale belongs in the
  reply, not the file.
- **No `created_at` / `updated_at` unless asked.** The user removed them from the schema at
  large and asked for them back on `tasks` only; do not add housekeeping timestamps to other
  tables unprompted. `tasks.updated_at` is set by the repository's own `update` statements, not a
  trigger, so a write to a task's row has to set it too — except the position shift that makes
  room for a moved task, which deliberately leaves the neighbours' timestamps alone.
- Existing conventions to match: lowercase SQL, tabs, `uuid primary key default gen_random_uuid()`
  (`gen_random_uuid` is built into postgres 13+, no extension needed), and a `text` column with
  a `check (… in (…))` for enumerated values rather than a native enum type — easier to change
  while this is a prototype.
- Where a field comes from the UI designs, get the field list from the `taskavista-designs`
  skill — but keep that derivation *out* of the file.

## The application side

`dashboard/` talks to postgres through **`vibe-d-postgresql`** (pinned `~>3.2.0` in `dub.json`).
There is no ORM and no migration runner: `source/model.d` holds the `Project` class and the other models, one per table with a field for every column,
`source/repository/package.d` the repository interfaces and `source/repository/postgres.d` the
postgres repositories that issue hand-written SQL, and `source/app.d` builds
the connection string and the pool.

A schema change therefore touches **three** places — `dashboard/sql/init.sql`, the model in
`source/model.d` (every column gets a field, exposed or not) and the SQL in `source/repository/postgres.d` that read the changed columns — and, when a
column is exposed over HTTP, three more: the view model in `source/viewmodel.d`, its mapping in
`source/service.d` (`toViewModel` / `toModel`), and the schema in `dashboard/public/rest-openapi.yaml`
(the `taskavista-rest-api-docs` skill covers that file). See "Models and view models" in
`docs/server-layers.md`. A renamed or
dropped column still compiles, because the SQL is strings; it fails at runtime on the first
query. Check the repository's statements against the new schema by hand.

Things about the D side worth knowing before you touch it:

- **Connection settings live in the config file** (`config.json` when present, else the one given
  with `--config`, such as `config-dev.json`), under `database` (host, port, name,
  user, password, connectionPoolSize), mirrored by `DatabaseConfig` in `source/app.d`. Every
  field is `@optional` with a default, so an omitted block still starts.
- **The pool connects lazily.** The server starts fine with postgres down and fails on the
  first query instead — so "it starts" is not evidence the database works.
- **Stay on `vibe-d-postgresql ~>3.2.0`.** 3.4.0-alpha.1 pulls a dpq2 that needs libpq 17's
  `PQcancel*` API; Ubuntu 24.04 ships libpq 16 and the link fails on undefined symbols.
  Building at all needs `libpq-dev` installed — that supplies the `libpq.so` the linker wants,
  but still no `psql` binary.
- **Enumerated `text` columns get an enum plus a converter**, as `AgentStatus` /
  `toAgentStatus` do. `std.conv.to` matches enum *member names*, not their values, so
  `to_be_scheduled` will not convert on its own. Add the same pairing for new enumerated columns.

Verify a change against the real database rather than trusting a compile. For a table that
has endpoints, the quickest way is to build, start the server and `curl` `/api/rest/v1/<resource>`; the
`taskavista-rest-api` skill has the commands. For a table with no endpoints yet, a throwaway dub
package that symlinks `source/model.d` and `source/repository/` and exercises the repository is enough.
