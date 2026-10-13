module api.rest;

import vibe.web.rest;
import vibe.http.common : HTTPMethod, HTTPStatusException, enforceHTTP;
import vibe.http.status : HTTPStatus;

import std.format : format;
import std.uuid : UUID;

import agent : TaskScheduler;
import changes : Change, ChangeFeed;
import api.checks : enforceNamed, enforceSlug, enforceValid;
import model : Agent, Default, Lane, Model, Project, Runtime, Task, TaskNote;
import repository : AgentRepository, DefaultRepository, LaneRepository, PositionConflict, ProjectRepository, RuntimeRepository,
    TaskRepository;

/// The projects REST API.
@path("/api/rest/v1")
interface ProjectApi
{
    @method(HTTPMethod.GET) @path("projects")
    Project[] listProjects() @safe;

    @method(HTTPMethod.GET) @path("projects/:id")
    Project readProject(UUID _id) @safe;

    @method(HTTPMethod.POST) @path("projects")
    Project createProject(@viaBody() Project project) @safe;

    @method(HTTPMethod.PUT) @path("projects/:id")
    Project replaceProject(UUID _id, @viaBody() Project project) @safe;

    @method(HTTPMethod.DELETE) @path("projects/:id")
    void deleteProject(UUID _id) @safe;
}

/// Serves the projects API out of the repository.
class ProjectService : ProjectApi
{
    private ProjectRepository repository;
    private ChangeFeed changes;

    this(ProjectRepository repository, ChangeFeed changes)
    {
        this.repository = repository;
        this.changes = changes;
    }

    override Project[] listProjects() @trusted
    {
        return repository.all();
    }

    override Project readProject(UUID _id) @trusted
    {
        auto project = repository.find(_id);
        enforceHTTP(!project.isNull, HTTPStatus.notFound, "No project has that id.");

        return project.get;
    }

    override Project createProject(Project project) @trusted
    {
        project.enforceNamed();
        project.enforceSlug(repository);

        auto created = repository.add(project);
        changes.project(Change.created, created.id);

        return created;
    }

    override Project replaceProject(UUID _id, Project project) @trusted
    {
        project.enforceNamed();
        // The path is what says which project this is; an id in the body is ignored.
        project.id = _id;
        project.enforceSlug(repository);
        enforceHTTP(repository.update(project), HTTPStatus.notFound, "No project has that id.");
        changes.project(Change.changed, _id);

        return project;
    }

    override void deleteProject(UUID _id) @trusted
    {
        enforceHTTP(repository.remove(_id), HTTPStatus.notFound, "No project has that id.");
        changes.project(Change.deleted, _id);
    }
}

/// The lanes REST API. A project's lanes are listed and created under the
/// project; a single lane is addressed by its own id.
@path("/api/rest/v1")
interface LaneApi
{
    @method(HTTPMethod.GET) @path("projects/:projectId/lanes")
    Lane[] listLanes(UUID _projectId) @safe;

    @method(HTTPMethod.GET) @path("lanes/:id")
    Lane readLane(UUID _id) @safe;

    @method(HTTPMethod.POST) @path("projects/:projectId/lanes")
    Lane createLane(UUID _projectId, @viaBody() Lane lane) @safe;

    @method(HTTPMethod.PUT) @path("lanes/:id")
    Lane replaceLane(UUID _id, @viaBody() Lane lane) @safe;

    @method(HTTPMethod.DELETE) @path("lanes/:id")
    void deleteLane(UUID _id) @safe;
}

/// Serves the lanes API out of the repository.
class LaneService : LaneApi
{
    private LaneRepository repository;
    private ChangeFeed changes;

    this(LaneRepository repository, ChangeFeed changes)
    {
        this.repository = repository;
        this.changes = changes;
    }

    override Lane[] listLanes(UUID _projectId) @trusted
    {
        enforceHTTP(repository.projectExists(_projectId), HTTPStatus.notFound, "No project has that id.");

        return repository.ofProject(_projectId);
    }

    override Lane readLane(UUID _id) @trusted
    {
        auto lane = repository.find(_id);
        enforceHTTP(!lane.isNull, HTTPStatus.notFound, "No lane has that id.");

        return lane.get;
    }

    override Lane createLane(UUID _projectId, Lane lane) @trusted
    {
        lane.enforceValid();
        enforceHTTP(repository.projectExists(_projectId), HTTPStatus.notFound, "No project has that id.");
        // The path is what says which project the lane goes in.
        lane.projectId = _projectId;
        lane.placeAtEndWhenUnplaced(repository);
        lane.enforcePositionFree(repository);

        auto created = repository.add(lane);
        changes.lane(Change.created, created.id, _projectId);

        return created;
    }

    override Lane replaceLane(UUID _id, Lane lane) @trusted
    {
        lane.enforceValid();

        auto stored = repository.find(_id);
        enforceHTTP(!stored.isNull, HTTPStatus.notFound, "No lane has that id.");
        // The path is what says which lane this is, and it stays in its project;
        // an id or projectId in the body is ignored.
        lane.id = _id;
        lane.projectId = stored.get.projectId;
        lane.placeAtEndWhenUnplaced(repository);
        lane.enforcePositionFree(repository);
        enforceHTTP(repository.update(lane), HTTPStatus.notFound, "No lane has that id.");
        changes.lane(Change.changed, _id, lane.projectId);

        return lane;
    }

    override void deleteLane(UUID _id) @trusted
    {
        // Looked up first, since the lane is gone afterwards.
        auto lane = repository.find(_id);
        enforceHTTP(!lane.isNull, HTTPStatus.notFound, "No lane has that id.");
        enforceHTTP(repository.remove(_id), HTTPStatus.notFound, "No lane has that id.");
        changes.lane(Change.deleted, _id, lane.get.projectId);
    }
}

/// The lane itself is left out of the count, so that a replace does not
/// place it after its own old position.
private void placeAtEndWhenUnplaced(Lane lane, LaneRepository repository)
{
    if (lane.position.isNull)
    {
        lane.position = repository.nextPosition(lane.projectId, lane.id);
    }
}

/// Applies the unique (project_id, position) constraint early, so that a clash
/// comes back as a 409. The lane's own id is left out, so a replace may keep
/// its position.
private void enforcePositionFree(Lane lane, LaneRepository repository)
{
    enforceHTTP(!repository.positionTaken(lane.projectId, lane.position.get, lane.id),
        HTTPStatus.conflict, format("Another lane of the project is already at position %s.", lane.position.get));
}

/// The tasks REST API. A lane's tasks are listed and created under the lane,
/// and a whole board's can be listed under the project; a single task is
/// addressed by its own id, and so are its notes.
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
    Task createTask(UUID _laneId, @viaBody() Task task) @safe;

    @method(HTTPMethod.PUT) @path("tasks/:id")
    Task replaceTask(UUID _id, @viaBody() Task task) @safe;

    @method(HTTPMethod.DELETE) @path("tasks/:id")
    void deleteTask(UUID _id) @safe;
}

/// Serves the tasks API out of the repository.
class TaskService : TaskApi
{
    private TaskRepository repository;
    private ProjectRepository projects;
    private TaskScheduler scheduler;
    private ChangeFeed changes;

    this(TaskRepository repository, ProjectRepository projects, TaskScheduler scheduler, ChangeFeed changes)
    {
        this.repository = repository;
        this.projects = projects;
        this.scheduler = scheduler;
        this.changes = changes;
    }

    override Task[] listProjectTasks(UUID _projectId) @trusted
    {
        enforceHTTP(repository.projectExists(_projectId), HTTPStatus.notFound, "No project has that id.");

        return repository.ofProject(_projectId);
    }

    override Task[] listLaneTasks(UUID _laneId) @trusted
    {
        enforceHTTP(!repository.projectOfLane(_laneId).isNull, HTTPStatus.notFound, "No lane has that id.");

        return repository.ofLane(_laneId);
    }

    override Task readTask(UUID _id) @trusted
    {
        auto task = repository.find(_id);
        enforceHTTP(!task.isNull, HTTPStatus.notFound, "No task has that id.");

        return task.get;
    }

    override TaskNote[] listTaskNotes(UUID _id) @trusted
    {
        enforceHTTP(!repository.find(_id).isNull, HTTPStatus.notFound, "No task has that id.");

        return repository.notes(_id);
    }

    override Task createTask(UUID _laneId, Task task) @trusted
    {
        task.enforceValid();
        auto projectId = repository.projectOfLane(_laneId);
        enforceHTTP(!projectId.isNull, HTTPStatus.notFound, "No lane has that id.");
        enforceHTTP(repository.acceptsNewTasks(_laneId), HTTPStatus.conflict,
            "The project only takes new tasks in its first lane.");
        // The path is what says which lane the task goes in.
        task.laneId = _laneId;

        auto created = answerConflict(repository.add(task));
        changes.task(Change.created, created.id, projectId.get, UUID.init, _laneId);
        if (projects.find(projectId.get).get.managedByAi)
        {
            scheduler.schedule(created.id);
        }

        return created;
    }

    override Task replaceTask(UUID _id, Task task) @trusted
    {
        task.enforceValid();

        auto stored = repository.find(_id);
        enforceHTTP(!stored.isNull, HTTPStatus.notFound, "No task has that id.");
        // The path is what says which task this is; an id in the body is ignored.
        task.id = _id;

        if (task.laneId == UUID.init)
        {
            task.laneId = stored.get.laneId;
        }
        else if (task.laneId != stored.get.laneId)
        {
            // A task may move to another lane, but not out of its project.
            auto project = repository.projectOfLane(task.laneId);
            enforceHTTP(!project.isNull, HTTPStatus.notFound, "No lane has that id.");
            enforceHTTP(project.get == repository.projectOfLane(stored.get.laneId).get,
                HTTPStatus.badRequest, "A task can only move to a lane of its own project.");
        }

        enforceHTTP(answerConflict(repository.update(task)), HTTPStatus.notFound, "No task has that id.");
        changes.task(Change.changed, _id, repository.projectOfLane(task.laneId).get, stored.get.laneId, task.laneId);

        return task;
    }

    override void deleteTask(UUID _id) @trusted
    {
        // Looked up first, since the task and the way to its project are gone afterwards.
        auto task = repository.find(_id);
        enforceHTTP(!task.isNull, HTTPStatus.notFound, "No task has that id.");
        auto projectId = repository.projectOfLane(task.get.laneId);
        enforceHTTP(repository.remove(_id), HTTPStatus.notFound, "No task has that id.");
        changes.task(Change.deleted, _id, projectId.get, task.get.laneId, UUID.init);
    }
}

/// Answers a task's place in its lane being taken with a 409. The repository
/// checks it, since only there is the lane locked against other writes.
private T answerConflict(T)(lazy T write)
{
    try
    {
        return write;
    }
    catch (PositionConflict conflict)
    {
        throw new HTTPStatusException(HTTPStatus.conflict, conflict.msg);
    }
}

/// The runtimes and models REST API. Both are fixed data, installed with the
/// schema, so they can only be read.
@path("/api/rest/v1")
interface RuntimeApi
{
    @method(HTTPMethod.GET) @path("runtimes")
    Runtime[] listRuntimes() @safe;

    @method(HTTPMethod.GET) @path("models")
    Model[] listModels() @safe;
}

/// Serves the runtimes and models API out of the repository.
class RuntimeService : RuntimeApi
{
    private RuntimeRepository repository;

    this(RuntimeRepository repository)
    {
        this.repository = repository;
    }

    override Runtime[] listRuntimes() @trusted
    {
        return repository.all();
    }

    override Model[] listModels() @trusted
    {
        return repository.models();
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
    Agent createAgent(@viaBody() Agent agent) @safe;

    @method(HTTPMethod.PUT) @path("agents/:id")
    Agent replaceAgent(UUID _id, @viaBody() Agent agent) @safe;

    @method(HTTPMethod.DELETE) @path("agents/:id")
    void deleteAgent(UUID _id) @safe;
}

/// Serves the agents API out of the repository, checking an agent's runtime
/// and model against the runtimes'.
class AgentService : AgentApi
{
    private AgentRepository repository;
    private RuntimeRepository runtimes;
    private ChangeFeed changes;

    this(AgentRepository repository, RuntimeRepository runtimes, ChangeFeed changes)
    {
        this.repository = repository;
        this.runtimes = runtimes;
        this.changes = changes;
    }

    override Agent[] listAgents() @trusted
    {
        return repository.all();
    }

    override Agent readAgent(UUID _id) @trusted
    {
        auto agent = repository.find(_id);
        enforceHTTP(!agent.isNull, HTTPStatus.notFound, "No agent has that id.");

        return agent.get;
    }

    override Agent createAgent(Agent agent) @trusted
    {
        agent.enforceValid();
        agent.enforceModelOffered(runtimes);
        agent.enforceNameFree(repository);

        auto created = repository.add(agent);
        changes.agent(Change.created, created.id);

        return created;
    }

    override Agent replaceAgent(UUID _id, Agent agent) @trusted
    {
        agent.enforceValid();
        // The path is what says which agent this is; an id in the body is ignored.
        agent.id = _id;
        agent.enforceModelOffered(runtimes);
        agent.enforceNameFree(repository);
        enforceHTTP(repository.update(agent), HTTPStatus.notFound, "No agent has that id.");
        changes.agent(Change.changed, _id);

        return agent;
    }

    override void deleteAgent(UUID _id) @trusted
    {
        enforceHTTP(repository.remove(_id), HTTPStatus.notFound, "No agent has that id.");
        changes.agent(Change.deleted, _id);
    }
}

/// Applies the agents' foreign keys early, so that an unknown runtime, a
/// model its runtime does not offer, or an effort level the model does not
/// take, comes back as a 400 rather than as a failed write.
private void enforceModelOffered(Agent agent, RuntimeRepository runtimes)
{
    const runtime = runtimes.name(agent.runtime);
    enforceHTTP(!runtime.isNull, HTTPStatus.badRequest, format("There is no runtime '%s'.", agent.runtime));
    enforceHTTP(runtimes.offers(agent.runtime, agent.model), HTTPStatus.badRequest,
        format("%s offers no model '%s'.", runtime.get, agent.model));
    enforceHTTP(runtimes.takes(agent.model, agent.effort), HTTPStatus.badRequest,
        format("The model '%s' takes no effort level '%s'.", agent.model, agent.effort));
}

/// Applies the unique name constraint early, so that a clash comes back as a
/// 409. The agent's own id is left out, so a replace may keep its name.
private void enforceNameFree(Agent agent, AgentRepository repository)
{
    enforceHTTP(!repository.nameTaken(agent.name, agent.id), HTTPStatus.conflict,
        format("An agent called “%s” already exists. Pick another name.", agent.name));
}

/// The defaults REST API: the value each app-wide setting starts from, such
/// as the runtime, model and effort level a new agent is offered. Read-only, since nothing
/// changes a default yet.
@path("/api/rest/v1")
interface DefaultApi
{
    @method(HTTPMethod.GET) @path("defaults")
    Default[] listDefaults() @safe;
}

/// Serves the defaults API out of the repository.
class DefaultService : DefaultApi
{
    private DefaultRepository repository;

    this(DefaultRepository repository)
    {
        this.repository = repository;
    }

    override Default[] listDefaults() @trusted
    {
        return repository.all();
    }
}
