# The RPC API, from the inside

What a caller needs (each call's arguments, results, statuses and examples) is in
`dashboard/public/rpc-openapi.yaml`, which agents using Taskavista fetch from the server. This
document is for whoever builds Taskavista. It covers why the calls are shaped as they are, and the
parts of how they work that a caller cannot see. Keep both in step: a rule a caller can observe
goes in the spec, and the reason for it goes here.

The calls are `RpcApi` in `dashboard/source/api/rpc.d`, served by `RpcController` and mounted at
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
- **`setAgentEnabled`** likewise returns only `enabled`, the agent's state after the call. It is
  a call of its own rather than a field of the agent's `PUT` so that saving the agent dialog,
  which sends the whole agent, can never undo a disable made meanwhile.
- **`setAllAgentsEnabled`** returns the ids of the agents it changed, leaving out those that
  were so already, since those are the only ones whose state it changed.

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

## Rescheduling a task

`rescheduleTask` is a last resort for a task no agent is working on, meant for the agents in a
chat: a person who finds a task stuck asks the agent to get it picked up. It is also how a task
added while its project was not managed by AI, which has no agent status and so stays out of the
agents' hands (its `handedToAgents` is `false`), is handed to them: the task details panel's
"Schedule for AI" button calls it. It sets the task's
`agent_status` back to `to_be_scheduled` and clears its agent, and the `TaskScheduler` loop in `agent.d`
takes it up on its next round as it does a new task. Clearing the agent is needed, as the loop
only takes up tasks with none.

It refuses what the loop would never take up, so that a 200 means the task will be scheduled: a
task of a project not managed by AI (whose tasks have no agent status at all), and one in a done
lane. It also refuses a task being scheduled or worked on, so that it does not undo the
scheduler's or the agent's work as it lands; the update is conditional on the status, so this
holds even when the two meet. A paused
project is not refused, since resuming it is all the task then waits for.

A task is also handed back without the call when it is moved to another lane, by `moveTask` or a
`PUT`, while its agent status is terminal: one that nothing changes until something hands the task
back: `declined` or `done` by the scheduler, and `failed` by the `TaskExecutor`. A move is how a person says a task is to be worked on
again, and its new lane may be what makes it fit an agent. The same rules apply, except that a
move that breaks one is not refused, it just does not reschedule. The terminal statuses are
listed in `terminalAgentStatuses` in `model.d`, the one place to add another.

The result is an empty object: what the call changed is not served by the API, and what comes of
it shows up later, in the task's notes. The call adds a note of its own, "Handed back to the task
scheduler", so that a person reading the notes can tell why the task was scheduled twice.

## Clearing a lane

`clearLane` is the board's "Clear" on a done lane, which gets rid of the finished tasks in one
statement rather than a `DELETE` per task. The server does not limit it to done lanes: that the
button shows only there is the UI's choice, and a person may as well ask an agent to empty any
lane. Its result is an empty object, since the caller knows the lane is now empty. It reports a
single `lane-cleared` rather than an event per task (see `docs/event-stream.md`).

## Agent chats

`sendChatMessage` starts a session on the agent's runtime (`AgentChat` in `agent.d`). Its system
prompt is two prompts, each filled in by `PromptParser`, joined by `AgentPrompt`:
`dashboard/prompts/system/agent.txt`, which every interaction with an agent starts with and which tells
the agent its own name, id and labels and gives it the API help in `dashboard/public/agent-help.txt`,
then `dashboard/prompts/system/new-agent-chat.txt`, which tells it a person has opened a chat, the
project the person is in, with its description when it has one, and how to write its replies. Every message, the first included, is passed on unchanged. Any failure
there, including an unknown runtime or a `sessionId` the runtime does not have, is a 502: only
the runtime knows which sessions exist, so the server cannot check one beforehand.

A chat runs in a scratch space of its own, named after its session, since Claude Code resumes a
session only from the directory it ran in, so it is kept for as long as the chat can be continued.
`endChat`, which the UI calls when a chat's tab is closed, stops an answer still being given and
removes that scratch space; deleting an agent does the same for all its chats. The scratch space of
a chat whose page was closed without ending it is left in the temp directory for the OS to clear,
and Claude Code's own record of the session for Claude Code to prune.

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

## Drafting a project

`draftProject` is the project prompt's "Set up project" (`tv-project-prompt`, shown at first run and from the project switcher's "Quick-create project"). It works as `draftAgent` does, with
`dashboard/prompts/quick-create-project.txt` (`ProjectDrafter` in `agent.d`): it creates nothing,
and the UI opens the draft on the new project screen, so the person reviews it before the ordinary
`createProject`. Its fields are what `createProject` takes, its lanes without ids.

The agents are asked as for `draftAgent`: the one named Generic, then each task scheduler, each
one that fails or does not answer with a draft logged and passed over for the next. When none
can, the answer is an `error`, and the person can set the project up by hand instead. The answer
is cleaned as an agent draft is: a lane without a name is dropped, a
colour that is not one of the standard lane colours (`laneColors` in `agent.d`, which mirrors
`standardColors` in `tv-project-settings.js` and is all the prompt lets the agent choose from) is
replaced by one of them, since the agent's own colours are not kept to a readable range as the
colour picker's are, and a rule the schema does not know becomes `first_lane`. A draft with no lanes
is not a draft. The name is not checked, since the new project screen checks it as it is shown.

## Error messages

Every failure is `{"statusMessage": "…"}`, with a message written for whoever called. The error
handler that rewrites vibe's messages about bodies and arguments is shared with the REST API
and described in `docs/rest-api.md`, and so are the 503s for a request that clashed with another
made at the same time. Two more pieces in `rpc.d`, mounted around `RpcApi` in
`app.d`, are the RPC API's own:

- **`enforceJsonObjectBody`** is a route on `POST /api/rpc/v1/*` registered before the calls.
  An RPC call reads its arguments from the fields of the body, and vibe parses that body before
  its error handling starts. So a body that is not JSON would be a 500 with a stack trace, and
  JSON that is not an object a plain-text 400. The filter answers both with a 400 and leaves a
  good body for the call, which the router reaches next. A REST body is read whole, inside
  vibe's error handling, so the REST API needs no such filter.
- **`answerNoSuchCall`** is registered after the calls and catches what none of them took: an
  unknown call, or a method other than `POST`. It answers with a JSON 404.
