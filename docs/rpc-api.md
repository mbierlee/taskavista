# The RPC API, from the inside

What a caller needs (each call's arguments, results, statuses and examples) is in
`dashboard/public/rpc-openapi.yaml`, which agents using Taskavista fetch from the server. This
document is for whoever builds Taskavista. It covers why the calls are shaped as they are, and the
parts of how they work that a caller cannot see. Keep both in step: a rule a caller can observe
goes in the spec, and the reason for it goes here.

The calls are `RpcApi` in `dashboard/source/api/rpc.d`, served by `RpcService` and mounted at
`/api/rpc/v1` in `app.d`. How to add one is in the `taskavista-rest-api` skill, and how to
document it is in `taskavista-rest-api-docs`.

## What makes something a call

An operation that reads or writes one resource is a REST endpoint. One that does more, such as
renumbering a task's neighbours, saving a project together with its lanes, or talking to an agent,
is a call. Calls exist so that a multi-row change happens in one request and one transaction,
instead of a client doing a series of REST requests and leaving a half-done board if one fails.

## Lean in, lean out

Arguments are ids and the few values the call needs. A result is only what the call changed that
the caller cannot already know, such as ids, an order or a slug. A call never takes or returns
whole resources. Fetching those is the REST API's job, and keeping it there means one shape per
resource, documented once. Before adding a field to a result, check that a client actually reads
it.

That rule decides each result:

- **`moveTask`** returns the destination lane's task ids in their new order, not the tasks. The
  caller sent the move, so it knows which task went where. A client that needs the stored
  positions reads the lane's tasks from the REST API.
- **`createProject`** returns the slug, not the id or the project. The slug is all the UI needs
  to navigate to the new board, and a client that wants the id can find it in the REST list.
- **`saveProjectSettings`** returns the slug because a rename changes it, so the UI has to move
  to the new URL.
- **`setAiPaused`** returns `aiPaused`, the project's state after the call, and nothing else
  about the project.

## Slugs are the server's

Neither project call takes a slug: the server makes one from the name, as the REST API does when
none is sent. A slug is only made again on a
rename, so saving without changing the name never moves a project to a new URL, even when its
current slug was not made from its name.

Because the client never chooses the slug, a 409 clash is worded in terms of the name ("A
project called … already exists"), in a message fit to show to whoever typed the name.

## Lanes sent to both project calls

`createProject` accepts a lane with `id: null`, although a new project's lanes cannot have ids.
That lets the settings screen send the same lane drafts (`LaneDraft` in `rpc.d`) in both its
new-project and edit modes. An actual id is still refused.

## Positions after a move

`moveTask` renumbers only the destination lane's tasks from `beforeTaskId` down, and leaves the
moved task's old place as a gap. Gaps are allowed throughout (see the REST spec), so filling them
would rewrite rows without changing the order. A caller should rely on the order, never on
consecutive positions.

## Agent chats

`sendChatMessage` starts a session on the agent's runtime (`AgentChat` in `agent.d`). Its system
prompt is two prompts, each filled in by `PromptParser`, joined by `AgentPrompt`:
`dashboard/prompts/system/agent.txt`, which every interaction with an agent starts with and which tells
the agent its own name, id and labels and gives it the API help in `dashboard/public/agent-help.txt`,
then `dashboard/prompts/system/new-agent-chat.txt`, which tells it a person has opened a chat, the
project the person is in, with its description when it has one, and how to write its replies. Every message, the first included, is passed on unchanged. Any failure
there, including an unknown runtime or a `sessionId` the runtime does not have, is a 502: only
the runtime knows which sessions exist, so the server cannot check one beforehand.

## Drafting an agent

`draftAgent` is the settings screen's "Quick-create an agent". It runs
`dashboard/prompts/quick-create-agent.txt` as a one-off prompt (`AgentDrafter` in `agent.d`), with
`agent.txt` as the system prompt as for any interaction, and creates nothing: the UI opens the
draft in the new agent dialog, so the person reviews it before the ordinary REST create.

It is the one call that returns something shaped like a resource, since the draft is not stored
anywhere for a client to fetch, and its fields are what `POST /api/rest/v1/agents` takes.

Any agent can draft one, as the prompt is written for whoever runs it, so the call asks the agent
named Generic, found by name as the chat's picker finds it, and then each task scheduler, since one
is meant to exist. An agent that fails or answers with something that is not a draft is logged
and passed over for the next. The answer is cleaned rather than trusted: the object is taken from
between the first `{` and the last `}`, since agents tend to wrap it in a code fence, a runtime,
model and effort level that do not go together become the defaults, and labels are lowercased
and deduplicated. The name is not checked, since the dialog's save will refuse a taken one.

When there is no draft, the answer is a 200 with only an `error`, the same shape the prompt asks
an agent to give for a description too vague to work from. That makes "no agent could" and "the
description says too little" one case for the UI, which shows the message, rather than a status
for one and a body for the other.

## Error messages

Every failure is `{"statusMessage": "…"}`, with a message written for whoever called. The error
handler that rewrites vibe's messages about bodies and arguments is shared with the REST API
and described in `docs/rest-api.md`. Two more pieces in `rpc.d`, mounted around `RpcApi` in
`app.d`, are the RPC API's own:

- **`enforceJsonObjectBody`** is a route on `POST /api/rpc/v1/*` registered before the calls.
  An RPC call reads its arguments from the fields of the body, and vibe parses that body before
  its error handling starts. So a body that is not JSON would be a 500 with a stack trace, and
  JSON that is not an object a plain-text 400. The filter answers both with a 400 and leaves a
  good body for the call, which the router reaches next. A REST body is read whole, inside
  vibe's error handling, so the REST API needs no such filter.
- **`answerNoSuchCall`** is registered after the calls and catches what none of them took: an
  unknown call, or a method other than `POST`. It answers with a JSON 404.
