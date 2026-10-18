module api.rpc;

import vibe.data.json : Json;
import vibe.web.rest;
import vibe.data.serialization : optional;
import vibe.http.common : HTTPMethod, HTTPStatusException, enforceHTTP;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
import vibe.http.status : HTTPStatus;

import std.algorithm : filter, findSplit, map;
import std.array : array;
import std.range : enumerate;
import std.string : strip;
import std.typecons : Nullable;
import std.uuid : UUID;

import agent : AgentChat, AgentDrafter;
import api.errors : toHTTPError;
import model : Lane, Project, TaskAddRule;
import service : AgentService, ProjectService, TaskService;
import servicemodel : ProjectWithLanes;

/**
 * The outcome of a move: the destination lane's order afterwards, which is
 * all a caller that already holds the tasks lacks.
 */
struct MoveTaskResult
{
    UUID laneId;
    UUID[] taskIds;
}

/**
 * A lane as the project settings screen drafts it. Its place in the list it
 * is sent in is its position, so it carries none of its own.
 */
struct LaneDraft
{
    /// Null for a lane the draft adds.
    @optional Nullable!UUID id;
    string name;
    string color;
    @optional bool marksDone;
}

/// The slug the server made for a new project from its name.
struct CreateProjectResult
{
    string slug;
}

/// The project's slug after the save, which a rename changes.
struct SaveProjectSettingsResult
{
    string slug;
}

/// Whether the project's agents are paused now.
struct SetAiPausedResult
{
    bool aiPaused;
}

/// Nothing, since a rescheduled task has nothing new to show until the task scheduler takes it up.
struct RescheduleTaskResult
{
}

/// The agent's answer to a chat message, and the session the chat is in.
struct SendChatMessageResult
{
    string reply;
    string sessionId;
}

/**
 * Operations that are not reading or writing one resource. Every call is a
 * POST, and its arguments are the fields of the JSON body, named as the
 * parameters are. Arguments and results are ids and the values the call
 * needs, never whole resources: those are the REST API's to serve.
 */
@path("/api/rpc/v1")
interface RpcApi
{
    /// `beforeTaskId` null puts the task at the bottom of the lane.
    @method(HTTPMethod.POST) @path("moveTask")
    MoveTaskResult moveTask(UUID taskId, UUID laneId,
        Nullable!UUID beforeTaskId = Nullable!UUID.init) @safe;

    /**
     * Hands a task back to the task scheduler, which takes it up as it does a new task. A
     * last resort for a task no agent is working on.
     */
    @method(HTTPMethod.POST) @path("rescheduleTask")
    RescheduleTaskResult rescheduleTask(UUID taskId) @safe;

    /**
     * Creates the project with these lanes, in this order, or nothing at all.
     * A project managed by AI starts with its agents running.
     */
    @method(HTTPMethod.POST) @path("createProject")
    CreateProjectResult createProject(string name, string description = null,
        TaskAddRule taskAddRule = TaskAddRule.firstLane, bool managedByAi = false,
        LaneDraft[] lanes = null) @safe;

    /**
     * Gives the project this name, description, rule, AI setting and exactly
     * these lanes, in this order, or changes nothing. A lane of the project
     * left out is deleted. Turning the AI setting off pauses the project's
     * agents, and turning it on starts them.
     */
    @method(HTTPMethod.POST) @path("saveProjectSettings")
    SaveProjectSettingsResult saveProjectSettings(UUID projectId, string name, string description,
        TaskAddRule taskAddRule, bool managedByAi, LaneDraft[] lanes) @safe;

    /**
     * Pauses the project's AI agents, or resumes them, and changes nothing
     * else about the project. Only a project managed by AI can be resumed.
     */
    @method(HTTPMethod.POST) @path("setAiPaused")
    SetAiPausedResult setAiPaused(UUID projectId, bool paused) @safe;

    /**
     * Sends a chat message to an agent and answers with its reply, once the
     * agent has given one. `sessionId` null starts a chat, in the project
     * `projectId`, or in none when that is null; otherwise the message goes
     * in that chat, and `projectId` is the project it started in, whose
     * working directory the agent keeps.
     */
    @method(HTTPMethod.POST) @path("sendChatMessage")
    SendChatMessageResult sendChatMessage(UUID agentId, string message,
        Nullable!UUID projectId = Nullable!UUID.init, Nullable!string sessionId = Nullable!string
            .init) @safe;

    /**
     * Has an agent draft a new agent from what the person wrote it should do,
     * without creating it. Answers with the agent's fields, for the new agent
     * dialog to show, or with only an `error` when no agent could draft one.
     */
    @method(HTTPMethod.POST) @path("draftAgent")
    Json draftAgent(string description) @safe;
}

/// Serves the RPC calls out of the services.
class RpcController : RpcApi
{
    private ProjectService projects;
    private TaskService tasks;
    private AgentService agents;
    private AgentChat chat;
    private AgentDrafter drafter;

    this(ProjectService projects, TaskService tasks, AgentService agents, AgentChat chat, AgentDrafter drafter)
    {
        this.projects = projects;
        this.tasks = tasks;
        this.agents = agents;
        this.chat = chat;
        this.drafter = drafter;
    }

    override MoveTaskResult moveTask(UUID taskId, UUID laneId, Nullable!UUID beforeTaskId) @trusted
    {
        auto moved = tasks.move(taskId, laneId, beforeTaskId);
        if (moved.isFailure)
        {
            throw toHTTPError(moved.error, null);
        }

        return MoveTaskResult(laneId, moved.value.map!(task => task.id).array);
    }

    override RescheduleTaskResult rescheduleTask(UUID taskId) @trusted
    {
        auto rescheduled = tasks.reschedule(taskId);
        if (rescheduled.isFailure)
        {
            throw toHTTPError(rescheduled.error, null);
        }

        return RescheduleTaskResult();
    }

    override CreateProjectResult createProject(string name, string description,
        TaskAddRule taskAddRule, bool managedByAi, LaneDraft[] lanes) @trusted
    {
        enforceHTTP(lanes.filter!(lane => !lane.id.isNull).empty, HTTPStatus.badRequest,
            "A new project's lanes have no ids yet.");

        auto project = new Project(name, null, description, taskAddRule, managedByAi);
        auto created = projects.save(new ProjectWithLanes(project, toLanes(lanes)));
        if (created.isFailure)
        {
            throw toHTTPError(created.error, project);
        }

        return CreateProjectResult(project.slug);
    }

    override SaveProjectSettingsResult saveProjectSettings(UUID projectId, string name,
        string description, TaskAddRule taskAddRule, bool managedByAi, LaneDraft[] lanes) @trusted
    {
        auto stored = projects.get(projectId);
        if (stored.isFailure)
        {
            throw toHTTPError(stored.error, null);
        }

        // The drafts, not the lanes, say which lanes are new: a lane made from a draft without an
        // id has the nil UUID, which the service reads as new, so a client may not send it.
        enforceHTTP(lanes.filter!(lane => !lane.id.isNull && lane.id.get == UUID.init).empty,
            HTTPStatus.notFound, "No lane has one of the lane ids sent.");

        // The slug is made again only on a rename, so a save that leaves the
        // name alone never moves the project to a new URL.
        const renamed = name != stored.value.name;
        auto project = new Project(projectId, name, renamed ? null : stored.value.slug, description,
            taskAddRule, managedByAi);
        auto saved = projects.save(new ProjectWithLanes(project, toLanes(lanes)));
        if (saved.isFailure)
        {
            throw toHTTPError(saved.error, project);
        }

        return SaveProjectSettingsResult(project.slug);
    }

    override SetAiPausedResult setAiPaused(UUID projectId, bool paused) @trusted
    {
        auto set = projects.setAiPaused(projectId, paused);
        if (set.isFailure)
        {
            throw toHTTPError(set.error, null);
        }

        return SetAiPausedResult(paused);
    }

    override SendChatMessageResult sendChatMessage(UUID agentId, string message,
        Nullable!UUID projectId, Nullable!string sessionId) @trusted
    {
        enforceHTTP(message.strip.length > 0, HTTPStatus.badRequest, "A message cannot be blank.");

        auto agent = agents.get(agentId);
        if (agent.isFailure)
        {
            throw toHTTPError(agent.error, null);
        }

        // A chat whose project has since been deleted goes on without it.
        Nullable!Project project;
        if (!projectId.isNull)
        {
            auto found = projects.get(projectId.get);
            if (found.isFailure && sessionId.isNull)
            {
                throw toHTTPError(found.error, null);
            }

            if (!found.isFailure)
            {
                project = found.value;
            }
        }

        // What is left is the agent failing to answer. A session the agent does
        // not have is among it, since only its runtime knows what sessions it has.
        try
        {
            string session = sessionId.isNull ? null : sessionId.get;
            auto reply = chat.send(agent.value, project, message, session);

            return SendChatMessageResult(reply, session);
        }
        catch (Exception exception)
        {
            throw new HTTPStatusException(HTTPStatus.badGateway,
                "The agent could not answer: " ~ exception.msg);
        }
    }

    override Json draftAgent(string description) @trusted
    {
        enforceHTTP(description.strip.length > 0, HTTPStatus.badRequest, "A description cannot be blank.");

        return drafter.draft(description);
    }
}

/**
 * The drafts as lanes, each at the position of its place in the list. The service checks them as
 * it checks any lane.
 */
private Lane[] toLanes(LaneDraft[] drafts)
{
    Lane[] lanes;
    foreach (index, draft; drafts.enumerate)
    {
        lanes ~= new Lane(draft.id.isNull ? UUID.init : draft.id.get, UUID.init, draft.name,
            cast(int) index, draft.color, draft.marksDone);
    }

    return lanes;
}

/**
 * Refuses a call whose body is not a JSON object, before vibe reads it.
 *
 * vibe parses the body ahead of its error handling, so a body that is not JSON
 * would otherwise be a 500 with a stack trace, and one that is JSON but not an
 * object a plain-text 400. Answering here gives both the `statusMessage` every
 * other failure has. A body that passes is left for the call, which vibe then
 * reaches as the next matching route.
 */
void enforceJsonObjectBody(HTTPServerRequest request, HTTPServerResponse response) @safe
{
    string message;
    try
    {
        const json = request.json;
        if (json.type == Json.Type.undefined)
        {
            message = "The request body must be a JSON object, sent with the Content-Type application/json.";
        }
        else if (json.type != Json.Type.object)
        {
            message = "The request body must be a JSON object.";
        }
    }
    catch (Exception exception)
    {
        message = "The request body is not valid JSON.";
    }

    if (message !is null)
    {
        response.writeJsonBody(["statusMessage": message], HTTPStatus.badRequest);
    }
}

/**
 * Answers a request under `/api/rpc/v1` that no call took, with a 404 that has
 * a `statusMessage` like every other failure, rather than vibe's plain-text page.
 */
void answerNoSuchCall(HTTPServerRequest request, HTTPServerResponse response) @safe
{
    const message = request.method == HTTPMethod.POST
        ? "There is no call " ~ request.requestPath.toString.findSplit(
            "/api/rpc/v1/")[2] ~ "." : "Every call is a POST.";
    response.writeJsonBody(["statusMessage": message], HTTPStatus.notFound);
}
