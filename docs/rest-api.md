# The REST API, from the inside

What a caller needs (each endpoint's body, responses, statuses and examples) is in
`dashboard/public/rest-openapi.yaml`, which agents using Taskavista fetch from the server. This
document is for whoever builds Taskavista. It covers why the resources behave as they do, and
the parts of how the server answers that a caller cannot see. Keep both in step: a rule a caller
can observe goes in the spec, and the reason for it goes here. The RPC API has its own
counterpart, `docs/rpc-api.md`.

The endpoints are the `…Api` interfaces in `dashboard/source/api/rest.d`, mounted in `app.d`.
How to add one is in the `taskavista-rest-api` skill, and how to document it is in
`taskavista-rest-api-docs`.

## Positions have gaps on purpose

Lanes and tasks may have gaps between their positions (`1, 2, 5`). This makes reordering
cheap: a lane can be moved into a free position between two others with a single `PUT`, without
renumbering its neighbours. The price is that positions are unique, so swapping two lanes takes
three `PUT`s. Moving a task is easier through the RPC call `moveTask`, which makes room itself.

## Slugs

A project's slug lets a client name the project in a URL without showing its id: the web UI's
routes are `/projects/:slug`. A slug may hold letters of any script, so in a URL it is
percent-encoded (`café-ü` is `caf%C3%A9-%C3%BC`). How the UI does that is in `docs/routing.md`.
No endpoint takes a slug in its path. A project is found by its slug in the list.

A name must have at least one letter or digit so that a slug can always be made from it, even
when the request sends a slug of its own. The server never makes a slug unique by adding a
number: a taken slug is a 409, and the person picks another name.

## An agent's parallel-task limit cannot be left out

`maxParallelTasks` is the one optional-looking agent field a body must carry. `null` means no
limit, and vibe reads a `null` for an `@optional` field as if the field were left out, keeping
the field's default. As an optional field, the limit could never be lifted. So the field is not
optional, and a `PUT` cannot reset it to the default by accident either.

## Messages fit to show

The 409s for a taken name and the 400s for an agent are worded so that a client can show them
as they are to the person who typed the name or filled in the agent. That is why a clash over a slug
derived from the name is put in terms of the name ("A project called … already exists. Pick
another name.").

## Error messages, in both APIs

Every failure of either API is `{"statusMessage": "…"}`, with a message written for whoever
called, not in vibe's or D's terms. The pieces shared by both APIs are in
`dashboard/source/api/errors.d`, and `app.d` mounts them:

- **`renderApiError`** is the `errorHandler` of every REST interface and of `RpcApi`. When vibe
  cannot read a body, a path id or an argument, its message is written in vibe's and D's terms:
  the JSON parser's "(0): Error: …", a "non-optional `body_` parameter", `int_`, a field's D
  class and serialization policy, the UUID parser's own wording. The handler rewrites each of
  these as, for example, "The field name is missing.", "“nope” is not a UUID." or "A value is a
  number where a string is expected." All of them are client errors, so a debug build answers
  them with 400 too. Any other exception is answered as vibe's default would answer it,
  including the debug-build 500 with a stack trace (see the `taskavista-rest-api` skill).
- **`renderApiError` also answers a clash with another request made at the same time** that the
  database refused and no service turned into an error of its own: a deadlock is a 503 (see
  below), a unique value another request took first a 409, and a row another request deleted a
  404. The services answer the clashes they know of themselves, such as a taken slug, so these
  are a safety net. Every 503 carries `Retry-After: 1`, since the request is all but sure to go
  through when sent again.
- **`answerNoSuchEndpoint`** is registered after the REST interfaces and catches what none of
  them took: an unknown path, a trailing slash, or an unsupported method. It answers with a JSON
  404, such as "There is no PATCH /api/rest/v1/projects/…". The RPC API has its own, described in
  `docs/rpc-api.md`.

The rewrites match vibe's message formats as text. A malformed UUID in an RPC argument is the
only one recognised by its exception type. In a REST path the same failure reaches the handler
as vibe's own exception, so it is matched by its text too. A vibe upgrade can change those
formats, and then the raw message passes through unchanged. After upgrading, rerun the
bad-weather probes against both APIs: a body that is not JSON, a wrong type, a missing field or
argument, an unknown enum value, a malformed id in the path and in the body, and an unknown path.

vibe does not say which field a type mismatch is in, so neither does the message.

## 503: send it again

A write that clashes with another made at the same time is answered with a 503 and
`Retry-After: 1` in two cases, in both APIs: when the database broke a deadlock by aborting it,
and when `rescheduleTask` found the task moving to other lanes every time it looked (see
`docs/server-layers.md` for the locking behind both). Neither is the caller's mistake, and the same
request sent again is all but sure to succeed, which is what a 503 with `Retry-After` says to a
client or an agent that retries. A deadlock is also logged as an error, since it means some
transaction took its locks out of order.
