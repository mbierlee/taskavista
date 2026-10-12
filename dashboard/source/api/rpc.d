module api.rpc;

import vibe.data.json : Json;
import vibe.web.rest;
import vibe.data.serialization : optional;
import vibe.http.common : HTTPMethod, HTTPStatusException, enforceHTTP;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
import vibe.http.status : HTTPStatus;

import std.algorithm : canFind, filter, findSplit, map;
import std.array : array;
import std.range : enumerate;
import std.string : strip;
import std.typecons : Nullable;
import std.uuid : UUID;

import agent : AgentChat;
import changes : Change, ChangeFeed;
import api.checks : enforceNamed, enforceSlug, enforceValid;
import model : Lane, Project, TaskAddRule;
import repository : AgentRepository, LaneRepository, PositionConflict, ProjectRepository, TaskRepository;

/// The outcome of a move: the destination lane's order afterwards, which is
/// all a caller that already holds the tasks lacks.
struct MoveTaskResult
{
    UUID laneId;
    UUID[] taskIds;
}

/// A lane as the project settings screen drafts it. Its place in the list it
/// is sent in is its position, so it carries none of its own.
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

/// The agent's answer to a chat message, and the session the chat is in.
struct SendChatMessageResult
{
    string reply;
    string sessionId;
}

/// Operations that are not reading or writing one resource. Every call is a
/// POST, and its arguments are the fields of the JSON body, named as the
/// parameters are. Arguments and results are ids and the values the call
/// needs, never whole resources: those are the REST API's to serve.
@path("/api/rpc/v1")
interface RpcApi
{
    /// `beforeTaskId` null puts the task at the bottom of the lane.
    @method(HTTPMethod.POST) @path("moveTask")
    MoveTaskResult moveTask(UUID taskId, UUID laneId,
        Nullable!UUID beforeTaskId = Nullable!UUID.init) @safe;

    /// Creates the project with these lanes, in this order, or nothing at all.
    /// A project managed by AI starts with its agents running.
    @method(HTTPMethod.POST) @path("createProject")
    CreateProjectResult createProject(string name, TaskAddRule taskAddRule = TaskAddRule.firstLane,
        bool managedByAi = false, LaneDraft[] lanes = null) @safe;

    /// Gives the project this name, rule, AI setting and exactly these lanes,
    /// in this order, or changes nothing. A lane of the project left out is
    /// deleted. Turning the AI setting off pauses the project's agents, and
    /// turning it on starts them.
    @method(HTTPMethod.POST) @path("saveProjectSettings")
    SaveProjectSettingsResult saveProjectSettings(UUID projectId, string name, TaskAddRule taskAddRule,
        bool managedByAi, LaneDraft[] lanes) @safe;

    /// Pauses the project's AI agents, or resumes them, and changes nothing
    /// else about the project. Only a project managed by AI can be resumed.
    @method(HTTPMethod.POST) @path("setAiPaused")
    SetAiPausedResult setAiPaused(UUID projectId, bool paused) @safe;

    /// Sends a chat message to an agent and answers with its reply, once the
    /// agent has given one. `sessionId` null starts a chat, in the project
    /// `projectId`, or in none when that is null; otherwise the message goes
    /// in that chat, and `projectId` is not read.
    @method(HTTPMethod.POST) @path("sendChatMessage")
    SendChatMessageResult sendChatMessage(UUID agentId, string message,
        Nullable!UUID projectId = Nullable!UUID.init, Nullable!string sessionId = Nullable!string.init) @safe;
}

/// Serves the RPC calls out of the repositories.
class RpcService : RpcApi
{
    private ProjectRepository projects;
    private LaneRepository lanes;
    private TaskRepository tasks;
    private AgentRepository agents;
    private AgentChat chat;
    private ChangeFeed changes;

    this(ProjectRepository projects, LaneRepository lanes, TaskRepository tasks, AgentRepository agents,
        AgentChat chat, ChangeFeed changes)
    {
        this.projects = projects;
        this.lanes = lanes;
        this.tasks = tasks;
        this.agents = agents;
        this.chat = chat;
        this.changes = changes;
    }

    override MoveTaskResult moveTask(UUID taskId, UUID laneId, Nullable!UUID beforeTaskId) @trusted
    {
        auto stored = tasks.find(taskId);
        enforceHTTP(!stored.isNull, HTTPStatus.notFound, "No task has that id.");

        auto project = tasks.projectOfLane(laneId);
        enforceHTTP(!project.isNull, HTTPStatus.notFound, "No lane has that id.");
        enforceHTTP(project.get == tasks.projectOfLane(stored.get.laneId).get,
            HTTPStatus.badRequest, "A task can only move to a lane of its own project.");

        auto before = UUID.init;
        if (!beforeTaskId.isNull)
        {
            before = beforeTaskId.get;
            enforceHTTP(before != taskId, HTTPStatus.badRequest, "A task cannot move before itself.");

            auto neighbour = tasks.find(before);
            enforceHTTP(!neighbour.isNull, HTTPStatus.notFound, "No task has the beforeTaskId sent.");
            enforceHTTP(neighbour.get.laneId == laneId, HTTPStatus.badRequest,
                "The beforeTaskId task is not in that lane.");
        }

        try
        {
            tasks.move(taskId, laneId, before);
        }
        catch (PositionConflict conflict)
        {
            // The beforeTaskId task left the lane after the check above.
            throw new HTTPStatusException(HTTPStatus.badRequest, conflict.msg);
        }
        changes.task(Change.moved, taskId, project.get, stored.get.laneId, laneId);

        return MoveTaskResult(laneId, tasks.ofLane(laneId).map!(task => task.id).array);
    }

    override CreateProjectResult createProject(string name, TaskAddRule taskAddRule, bool managedByAi,
        LaneDraft[] lanes) @trusted
    {
        auto project = new Project(name, null, taskAddRule, managedByAi);
        project.enforceNamed();
        enforceHTTP(lanes.filter!(lane => !lane.id.isNull).empty, HTTPStatus.badRequest,
            "A new project's lanes have no ids yet.");
        auto board = toLanes(lanes);
        project.enforceSlug(projects);

        projects.addWithLanes(project, board);
        changes.project(Change.created, project.id);

        return CreateProjectResult(project.slug);
    }

    override SaveProjectSettingsResult saveProjectSettings(UUID projectId, string name,
        TaskAddRule taskAddRule, bool managedByAi, LaneDraft[] lanes) @trusted
    {
        auto stored = projects.find(projectId);
        enforceHTTP(!stored.isNull, HTTPStatus.notFound, "No project has that id.");

        // The slug is made again only on a rename, so a save that leaves the
        // name alone never moves the project to a new URL.
        const renamed = name != stored.get.name;
        auto project = new Project(projectId, name, renamed ? null : stored.get.slug, taskAddRule,
            managedByAi);
        project.enforceNamed();
        project.enforceSlug(projects);

        auto board = toLanes(lanes);
        auto existing = this.lanes.ofProject(projectId).map!(lane => lane.id).array;
        bool[UUID] kept;
        // The drafts, not the lanes, say which lanes are new: a lane made from a
        // draft without an id has the nil UUID, which a client may also send.
        foreach (id; lanes.filter!(lane => !lane.id.isNull).map!(lane => lane.id.get))
        {
            const own = existing.canFind(id);
            enforceHTTP(own || this.lanes.find(id).isNull, HTTPStatus.badRequest,
                "A lane sent belongs to another project.");
            enforceHTTP(own, HTTPStatus.notFound, "No lane has one of the lane ids sent.");
            enforceHTTP(id !in kept, HTTPStatus.badRequest, "A lane is listed twice.");
            kept[id] = true;
        }

        projects.replaceWithLanes(project, board, existing.filter!(id => id !in kept).array);
        changes.project(Change.changed, projectId);

        return SaveProjectSettingsResult(project.slug);
    }

    override SetAiPausedResult setAiPaused(UUID projectId, bool paused) @trusted
    {
        auto project = projects.find(projectId);
        enforceHTTP(!project.isNull, HTTPStatus.notFound, "No project has that id.");
        enforceHTTP(paused || project.get.managedByAi, HTTPStatus.conflict,
            "The project is not managed by AI agents, so its agents cannot be resumed.");
        projects.setAiPaused(projectId, paused);
        changes.project(Change.changed, projectId);

        return SetAiPausedResult(paused);
    }

    override SendChatMessageResult sendChatMessage(UUID agentId, string message,
        Nullable!UUID projectId, Nullable!string sessionId) @trusted
    {
        enforceHTTP(message.strip.length > 0, HTTPStatus.badRequest, "A message cannot be blank.");

        auto agent = agents.find(agentId);
        enforceHTTP(!agent.isNull, HTTPStatus.notFound, "No agent has that id.");

        Nullable!Project project;
        if (sessionId.isNull && !projectId.isNull)
        {
            project = projects.find(projectId.get);
            enforceHTTP(!project.isNull, HTTPStatus.notFound, "No project has that id.");
        }

        // What is left is the agent failing to answer. A session the agent does
        // not have is among it, since only its runtime knows what sessions it has.
        try
        {
            string session = sessionId.isNull ? null : sessionId.get;
            auto reply = chat.send(agent.get, project, message, session);

            return SendChatMessageResult(reply, session);
        }
        catch (Exception exception)
        {
            throw new HTTPStatusException(HTTPStatus.badGateway,
                "The agent could not answer: " ~ exception.msg);
        }
    }
}

/// The drafts as lanes, each at the position of its place in the list, and
/// checked as the lanes REST API checks a lane.
private Lane[] toLanes(LaneDraft[] drafts)
{
    Lane[] lanes;
    foreach (index, draft; drafts.enumerate)
    {
        auto lane = new Lane(draft.id.isNull ? UUID.init : draft.id.get, UUID.init, draft.name,
            cast(int) index, draft.color, draft.marksDone);
        lane.enforceValid();
        lanes ~= lane;
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

/// Answers a request under `/api/rpc/v1` that no call took, with a 404 that has
/// a `statusMessage` like every other failure, rather than vibe's plain-text page.
void answerNoSuchCall(HTTPServerRequest request, HTTPServerResponse response) @safe
{
    const message = request.method == HTTPMethod.POST
        ? "There is no call " ~ request.requestPath.toString.findSplit("/api/rpc/v1/")[2] ~ "."
        : "Every call is a POST.";
    response.writeJsonBody(["statusMessage": message], HTTPStatus.notFound);
}
