module api.rest;

import vibe.web.rest;
import vibe.http.common : HTTPMethod, enforceHTTP;
import vibe.http.status : HTTPStatus;

import std.uuid : UUID;

import model : Agent, Default, Lane, Model, Project, Runtime, Task, TaskNote;
import api.errors : toHTTPError;
import service : AgentService, DefaultService, LaneService, ProjectService, RuntimeService, TaskService;

/// The projects REST API.
@path("/api/rest/v1")
interface ProjectApi
{
    @method(HTTPMethod.GET) @path("projects")
    Project[] listProjects() @safe;

    @method(HTTPMethod.GET) @path("projects/:id")
    Project readProject(UUID _id) @safe;

    @method(HTTPMethod.POST) @path("projects")
    Project createProject(@viaBody() Project project)@safe;

    @method(HTTPMethod.PUT) @path("projects/:id")
    Project replaceProject(UUID _id, @viaBody() Project project)@safe;

    @method(HTTPMethod.DELETE) @path("projects/:id")
    void deleteProject(UUID _id) @safe;
}

/// Serves the projects API out of the service.
class ProjectController : ProjectApi
{
    private ProjectService service;

    this(ProjectService service)
    {
        this.service = service;
    }

    override Project[] listProjects() @trusted
    {
        return service.getAll();
    }

    override Project readProject(UUID _id) @trusted
    {
        auto project = service.get(_id);
        enforceHTTP(project.isSuccessful, HTTPStatus.notFound, "No project has that id.");

        return project.value;
    }

    override Project createProject(Project project) @trusted
    {
        enforceBody(project);
        // A client cannot pick the id; one in the body is ignored, or the save would be an update.
        project.id = UUID.init;

        auto created = service.save(project);
        if (created.isFailure)
        {
            throw toHTTPError(created.error, project);
        }

        return created.value;
    }

    override Project replaceProject(UUID _id, Project project) @trusted
    {
        // The service would read the nil UUID as a new project to create.
        enforceHTTP(_id != UUID.init, HTTPStatus.notFound, "A project id is required.");
        enforceBody(project);
        // The path is what says which project this is; an id in the body is ignored.
        project.id = _id;
        auto replaced = service.save(project);
        if (replaced.isFailure)
        {
            throw toHTTPError(replaced.error, project);
        }

        return replaced.value;
    }

    override void deleteProject(UUID _id) @trusted
    {
        enforceHTTP(service.remove(_id).isSuccessful, HTTPStatus.notFound, "No project has that id.");
    }
}

/**
 * Answers a body of JSON null, which reads as a null object, with a 400 before anything uses it.
 */
private void enforceBody(T)(T received)
{
    enforceHTTP(received !is null, HTTPStatus.badRequest, "The body is not a JSON object.");
}

/**
 * The lanes REST API. A project's lanes are listed and created under the
 * project; a single lane is addressed by its own id.
 */
@path("/api/rest/v1")
interface LaneApi
{
    @method(HTTPMethod.GET) @path("projects/:projectId/lanes")
    Lane[] listLanes(UUID _projectId) @safe;

    @method(HTTPMethod.GET) @path("lanes/:id")
    Lane readLane(UUID _id) @safe;

    @method(HTTPMethod.POST) @path("projects/:projectId/lanes")
    Lane createLane(UUID _projectId, @viaBody() Lane lane)@safe;

    @method(HTTPMethod.PUT) @path("lanes/:id")
    Lane replaceLane(UUID _id, @viaBody() Lane lane)@safe;

    @method(HTTPMethod.DELETE) @path("lanes/:id")
    void deleteLane(UUID _id) @safe;
}

/// Serves the lanes API out of the service.
class LaneController : LaneApi
{
    private LaneService service;

    this(LaneService service)
    {
        this.service = service;
    }

    override Lane[] listLanes(UUID _projectId) @trusted
    {
        auto lanes = service.getOfProject(_projectId);
        if (lanes.isFailure)
        {
            throw toHTTPError(lanes.error, null);
        }

        return lanes.value;
    }

    override Lane readLane(UUID _id) @trusted
    {
        auto lane = service.get(_id);
        if (lane.isFailure)
        {
            throw toHTTPError(lane.error, null);
        }

        return lane.value;
    }

    override Lane createLane(UUID _projectId, Lane lane) @trusted
    {
        enforceBody(lane);
        // The path is what says which project the lane goes in. A client cannot pick the id; one
        // in the body is ignored, or the save would be an update.
        lane.id = UUID.init;
        lane.projectId = _projectId;

        auto created = service.save(lane);
        if (created.isFailure)
        {
            throw toHTTPError(created.error, lane);
        }

        return created.value;
    }

    override Lane replaceLane(UUID _id, Lane lane) @trusted
    {
        // The service would read the nil UUID as a new lane to create.
        enforceHTTP(_id != UUID.init, HTTPStatus.notFound, "A lane id is required.");
        enforceBody(lane);
        // The path is what says which lane this is, and the service keeps it in its project; an
        // id or projectId in the body is ignored.
        lane.id = _id;

        auto replaced = service.save(lane);
        if (replaced.isFailure)
        {
            throw toHTTPError(replaced.error, lane);
        }

        return replaced.value;
    }

    override void deleteLane(UUID _id) @trusted
    {
        auto removed = service.remove(_id);
        if (removed.isFailure)
        {
            throw toHTTPError(removed.error, null);
        }
    }
}

/**
 * The tasks REST API. A lane's tasks are listed and created under the lane,
 * and a whole board's can be listed under the project; a single task is
 * addressed by its own id, and so are its notes.
 */
@path("/api/rest/v1")
interface TaskApi
{
    @method(HTTPMethod.GET) @path("projects/:projectId/tasks")
    Task[] listProjectTasks(UUID _projectId) @safe;

    @method(HTTPMethod.GET) @path("lanes/:laneId/tasks")
    Task[] listLaneTasks(UUID _laneId) @safe;

    @method(HTTPMethod.GET) @path("tasks/:id")
    Task readTask(UUID _id) @safe;

    @method(HTTPMethod.GET) @path("tasks/:id/notes")
    TaskNote[] listTaskNotes(UUID _id) @safe;

    @method(HTTPMethod.POST) @path("lanes/:laneId/tasks")
    Task createTask(UUID _laneId, @viaBody() Task task)@safe;

    @method(HTTPMethod.PUT) @path("tasks/:id")
    Task replaceTask(UUID _id, @viaBody() Task task)@safe;

    @method(HTTPMethod.DELETE) @path("tasks/:id")
    void deleteTask(UUID _id) @safe;
}

/// Serves the tasks API out of the service.
class TaskController : TaskApi
{
    private TaskService service;

    this(TaskService service)
    {
        this.service = service;
    }

    override Task[] listProjectTasks(UUID _projectId) @trusted
    {
        auto tasks = service.getOfProject(_projectId);
        if (tasks.isFailure)
        {
            throw toHTTPError(tasks.error, null);
        }

        return tasks.value;
    }

    override Task[] listLaneTasks(UUID _laneId) @trusted
    {
        auto tasks = service.getOfLane(_laneId);
        if (tasks.isFailure)
        {
            throw toHTTPError(tasks.error, null);
        }

        return tasks.value;
    }

    override Task readTask(UUID _id) @trusted
    {
        auto task = service.get(_id);
        if (task.isFailure)
        {
            throw toHTTPError(task.error, null);
        }

        return task.value;
    }

    override TaskNote[] listTaskNotes(UUID _id) @trusted
    {
        auto notes = service.getNotes(_id);
        if (notes.isFailure)
        {
            throw toHTTPError(notes.error, null);
        }

        return notes.value;
    }

    override Task createTask(UUID _laneId, Task task) @trusted
    {
        enforceBody(task);
        // The path is what says which lane the task goes in. A client cannot pick the id; one in
        // the body is ignored, or the save would be an update.
        task.id = UUID.init;
        task.laneId = _laneId;

        auto created = service.save(task);
        if (created.isFailure)
        {
            throw toHTTPError(created.error, task);
        }

        return created.value;
    }

    override Task replaceTask(UUID _id, Task task) @trusted
    {
        // The service would read the nil UUID as a new task to create.
        enforceHTTP(_id != UUID.init, HTTPStatus.notFound, "A task id is required.");
        enforceBody(task);
        // The path is what says which task this is; an id in the body is ignored.
        task.id = _id;

        auto replaced = service.save(task);
        if (replaced.isFailure)
        {
            throw toHTTPError(replaced.error, task);
        }

        return replaced.value;
    }

    override void deleteTask(UUID _id) @trusted
    {
        auto removed = service.remove(_id);
        if (removed.isFailure)
        {
            throw toHTTPError(removed.error, null);
        }
    }
}

/**
 * The runtimes and models REST API. Both are fixed data, installed with the
 * schema, so they can only be read.
 */
@path("/api/rest/v1")
interface RuntimeApi
{
    @method(HTTPMethod.GET) @path("runtimes")
    Runtime[] listRuntimes() @safe;

    @method(HTTPMethod.GET) @path("models")
    Model[] listModels() @safe;
}

/// Serves the runtimes and models API out of the service.
class RuntimeController : RuntimeApi
{
    private RuntimeService service;

    this(RuntimeService service)
    {
        this.service = service;
    }

    override Runtime[] listRuntimes() @trusted
    {
        return service.getAll();
    }

    override Model[] listModels() @trusted
    {
        return service.getModels();
    }
}

/// The agents REST API.
@path("/api/rest/v1")
interface AgentApi
{
    @method(HTTPMethod.GET) @path("agents")
    Agent[] listAgents() @safe;

    @method(HTTPMethod.GET) @path("agents/:id")
    Agent readAgent(UUID _id) @safe;

    @method(HTTPMethod.POST) @path("agents")
    Agent createAgent(@viaBody() Agent agent)@safe;

    @method(HTTPMethod.PUT) @path("agents/:id")
    Agent replaceAgent(UUID _id, @viaBody() Agent agent)@safe;

    @method(HTTPMethod.DELETE) @path("agents/:id")
    void deleteAgent(UUID _id) @safe;
}

/// Serves the agents API out of the service.
class AgentController : AgentApi
{
    private AgentService service;

    this(AgentService service)
    {
        this.service = service;
    }

    override Agent[] listAgents() @trusted
    {
        return service.getAll();
    }

    override Agent readAgent(UUID _id) @trusted
    {
        auto agent = service.get(_id);
        if (agent.isFailure)
        {
            throw toHTTPError(agent.error, null);
        }

        return agent.value;
    }

    override Agent createAgent(Agent agent) @trusted
    {
        enforceBody(agent);
        // A client cannot pick the id; one in the body is ignored, or the save would be an update.
        agent.id = UUID.init;

        auto created = service.save(agent);
        if (created.isFailure)
        {
            throw toHTTPError(created.error, agent);
        }

        return created.value;
    }

    override Agent replaceAgent(UUID _id, Agent agent) @trusted
    {
        // The service would read the nil UUID as a new agent to create.
        enforceHTTP(_id != UUID.init, HTTPStatus.notFound, "An agent id is required.");
        enforceBody(agent);
        // The path is what says which agent this is; an id in the body is ignored.
        agent.id = _id;

        auto replaced = service.save(agent);
        if (replaced.isFailure)
        {
            throw toHTTPError(replaced.error, agent);
        }

        return replaced.value;
    }

    override void deleteAgent(UUID _id) @trusted
    {
        auto removed = service.remove(_id);
        if (removed.isFailure)
        {
            throw toHTTPError(removed.error, null);
        }
    }
}

/**
 * The defaults REST API: the value each app-wide setting starts from, such
 * as the runtime, model and effort level a new agent is offered. Read-only, since nothing
 * changes a default yet.
 */
@path("/api/rest/v1")
interface DefaultApi
{
    @method(HTTPMethod.GET) @path("defaults")
    Default[] listDefaults() @safe;
}

/// Serves the defaults API out of the service.
class DefaultController : DefaultApi
{
    private DefaultService service;

    this(DefaultService service)
    {
        this.service = service;
    }

    override Default[] listDefaults() @trusted
    {
        return service.getAll();
    }
}
