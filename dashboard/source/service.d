module service;

import std.algorithm : canFind, filter, map;
import std.array : array;
import std.string : strip;
import std.typecons : Nullable, nullable;
import std.uni : toLower;
import std.uuid : UUID;

import agent : IAgentChat;
import eventing : Event, IEventPublisher;
import helpers : hasLetterOrDigit, isHexColor, isSlug, slugify;
import model : Agent, AgentStatus, Default, Lane, Model, Project, Runtime, Task, TaskNote, terminalAgentStatuses;
import repository : ForeignKeyViolation, IAgentRepository, IDefaultRepository, ILaneRepository, IProjectRepository,
    IRuntimeRepository, ITaskRepository, ITransactional, PositionConflict, UniqueViolation;
import result : OperationResult, Result, failure, success;
import servicemodel : ProjectWithLanes;
import workingdir : IndexPages, ProjectWorkingDirs;

/**
 * Slugs the web UI's routes use for screens of their own under /projects/,
 * which a project's URL would collide with.
 */
immutable string[] reservedSlugs = ["new"];

/**
 * The rules a project and its lanes are read and written by. Every write it makes is reported to
 * the event stream once it has succeeded. A project's working directory is made along with it and
 * moves along with its slug.
 */
class ProjectService
{
    private IProjectRepository repository;
    private ILaneRepository lanes;
    private IEventPublisher events;
    private ProjectWorkingDirs workingDirs;
    private ITransactional transactions;

    this(IProjectRepository repository, ILaneRepository lanes, IEventPublisher events,
        ProjectWorkingDirs workingDirs, ITransactional transactions)
    {
        this.repository = repository;
        this.lanes = lanes;
        this.events = events;
        this.workingDirs = workingDirs;
        this.transactions = transactions;
    }

    /**
     * Stores a project.
     *
     * Creates the project when it has no id yet, and updates it otherwise. A project with no
     * slug is given one made from its name, which must have a letter or digit in it.
     *
     * Params:
     *   project = The project to create or update.
     *
     * Returns: The project as stored, or a failure: `ProjectNameMissingError`,
     *   `ProjectNameUnusableError`, `SlugInvalidError`, `SlugReservedError`, `SlugTakenError`,
     *   `NameReservedError`, `NameTakenError` or `ProjectNotFoundError`.
     */
    Result!(Project, IProjectError) save(Project project)
    {
        auto invalid = checkName(project);
        if (invalid !is null)
        {
            return projectFailure!Project(invalid);
        }

        const derived = project.slug.length == 0;
        auto slug = checkSlug(project);
        if (slug.isFailure)
        {
            return projectFailure!Project(slug.error);
        }

        try
        {
            if (project.id == UUID.init)
            {
                repository.add(project);
                workingDirs.createIfRootExists(project.slug);
                events.project(Event.created, project.id);
                return projectSuccess(withCanBeOpened(project));
            }

            // Locked, so that the slug the working directory is renamed from is the one the update
            // replaces, whatever other save comes along meanwhile.
            auto updated = transactionally(transactions, {
                if (!repository.lock(project.id))
                {
                    return projectFailure!Project(new ProjectNotFoundError);
                }

                const oldSlug = repository.find(project.id).get.slug;
                if (!repository.update(project))
                {
                    return projectFailure!Project(new ProjectNotFoundError);
                }

                transactions.afterCommit(() => workingDirs.rename(oldSlug, project.slug));
                events.project(Event.changed, project.id);
                return projectSuccess(project);
            });

            return updated.isSuccessful ? projectSuccess(withCanBeOpened(updated.value)) : updated;
        }
        catch (UniqueViolation violation)
        {
            return projectFailure!Project(slugTaken(project, derived, violation));
        }
    }

    /**
     * Stores a project and its lanes in one transaction.
     *
     * Creates the project and its lanes when the project has no id yet. Otherwise updates it
     * and gives it exactly these lanes: a lane with no id yet is created, and a lane of the
     * project's that is not among them is deleted, tasks and all. A project with no slug is
     * given one made from its name, which must have a letter or digit in it.
     *
     * Params:
     *   projectWithLanes = The project and its lanes, at the positions they carry.
     *
     * Returns: The project and its lanes as stored, or a failure: `ProjectNameMissingError`,
     *   `ProjectNameUnusableError`, `ProjectNotFoundError`, `SlugInvalidError`,
     *   `SlugReservedError`, `SlugTakenError`, `NameReservedError`, `NameTakenError`,
     *   `LaneNameMissingError`, `LanePositionNegativeError`, `LaneColorInvalidError`,
     *   `LaneOfOtherProjectError`, `LaneNotFoundError` or `LaneListedTwiceError`.
     */
    Result!(ProjectWithLanes, IProjectError) save(ProjectWithLanes projectWithLanes)
    {
        auto project = projectWithLanes.project;
        auto invalid = checkName(project);
        if (invalid !is null)
        {
            return projectFailure!ProjectWithLanes(invalid);
        }

        const derived = project.slug.length == 0;
        try
        {
            if (project.id == UUID.init)
            {
                auto invalidLane = checkLanes(projectWithLanes.lanes);
                if (invalidLane !is null)
                {
                    return projectFailure!ProjectWithLanes(invalidLane);
                }

                auto newSlug = checkSlug(project);
                if (newSlug.isFailure)
                {
                    return projectFailure!ProjectWithLanes(newSlug.error);
                }

                repository.addWithLanes(project, projectWithLanes.lanes);
                workingDirs.createIfRootExists(project.slug);
                events.project(Event.created, project.id);
                withCanBeOpened(project);
                return projectSuccess(projectWithLanes);
            }

            auto replaced = transactionally(transactions, () => replace(projectWithLanes));
            if (replaced.isSuccessful)
            {
                withCanBeOpened(project);
            }

            return replaced;
        }
        catch (UniqueViolation violation)
        {
            return projectFailure!ProjectWithLanes(slugTaken(project, derived, violation));
        }
    }

    /**
     * Updates a project and gives it exactly its lanes, for save, in the transaction it opens.
     * The project is locked first, as by every write to a project's lanes, so that the lanes it
     * has stay the ones read here until the write is done.
     */
    private Result!(ProjectWithLanes, IProjectError) replace(ProjectWithLanes projectWithLanes)
    {
        auto project = projectWithLanes.project;
        if (!repository.lock(project.id))
        {
            return projectFailure!ProjectWithLanes(new ProjectNotFoundError);
        }

        const oldSlug = repository.find(project.id).get.slug;

        auto slug = checkSlug(project);
        if (slug.isFailure)
        {
            return projectFailure!ProjectWithLanes(slug.error);
        }

        auto invalidLane = checkLanes(projectWithLanes.lanes);
        if (invalidLane !is null)
        {
            return projectFailure!ProjectWithLanes(invalidLane);
        }

        auto existing = lanes.ofProject(project.id).map!(lane => lane.id).array;
        bool[UUID] kept;
        foreach (id; projectWithLanes.lanes
            .map!(lane => lane.id)
            .filter!(id => id != UUID.init))
        {
            const own = existing.canFind(id);
            if (!own && !lanes.find(id).isNull)
            {
                return projectFailure!ProjectWithLanes(new LaneOfOtherProjectError);
            }

            if (!own)
            {
                return projectFailure!ProjectWithLanes(new LaneNotFoundError);
            }

            if (id in kept)
            {
                return projectFailure!ProjectWithLanes(new LaneListedTwiceError);
            }

            kept[id] = true;
        }

        auto removed = existing.filter!(id => id !in kept).array;
        if (!repository.replaceWithLanes(project, projectWithLanes.lanes, removed))
        {
            return projectFailure!ProjectWithLanes(new ProjectNotFoundError);
        }

        transactions.afterCommit(() => workingDirs.rename(oldSlug, project.slug));
        // One event for the project and its lanes, which the UI reads as "its lanes may have
        // changed too", rather than one per lane.
        events.project(Event.changed, project.id);
        return projectSuccess(projectWithLanes);
    }

    /**
     * Gets a project.
     *
     * Params:
     *   id = The project's id.
     *
     * Returns: The project with that id, or a failure: `ProjectNotFoundError`.
     */
    Result!(Project, IProjectError) get(UUID id)
    {
        auto project = repository.find(id);
        if (project.isNull)
        {
            return projectFailure!Project(new ProjectNotFoundError);
        }

        return projectSuccess(withCanBeOpened(project.get));
    }

    /**
     * Gets every project.
     *
     * Returns: Every project, by name.
     */
    Project[] getAll()
    {
        return repository.all().map!(project => withCanBeOpened(project)).array;
    }

    /**
     * Deletes a project.
     *
     * Params:
     *   id = The project's id.
     *
     * Returns: Success, or a failure: `ProjectNotFoundError`.
     */
    OperationResult!IProjectError remove(UUID id)
    {
        if (!repository.remove(id))
        {
            return projectFailure(new ProjectNotFoundError);
        }

        events.project(Event.deleted, id);
        return projectSuccess();
    }

    /**
     * Pauses a project's AI agents, or resumes them, and changes nothing else about it.
     *
     * Params:
     *   id = The project's id.
     *   paused = Whether its agents are to be paused.
     *
     * Returns: Success, or a failure: `ProjectNotFoundError`, or `ProjectNotManagedByAiError` for
     *   resuming the agents of a project not managed by AI, which has none running.
     */
    OperationResult!IProjectError setAiPaused(UUID id, bool paused)
    {
        // Locked, so that the project is not taken off AI management between the check and the
        // write, which would leave an unmanaged project with its agents running.
        return transactionally(transactions, {
            if (!repository.lock(id))
            {
                return projectFailure(new ProjectNotFoundError);
            }

            if (!paused && !repository.find(id).get.managedByAi)
            {
                return projectFailure(new ProjectNotManagedByAiError);
            }

            if (!repository.setAiPaused(id, paused))
            {
                return projectFailure(new ProjectNotFoundError);
            }

            events.project(Event.changed, id);
            return projectSuccess();
        });
    }

    /// Sets whether the project can be opened, by its working directory having an index.html, and returns it.
    private Project withCanBeOpened(Project project)
    {
        project.canBeOpened = workingDirs.hasIndexPage(project.slug);
        return project;
    }

    /// The first error among the lanes, or null when they are all fine.
    private IProjectError checkLanes(Lane[] lanes)
    {
        foreach (lane; lanes)
        {
            auto invalid = checkLane!IProjectError(lane);
            if (invalid !is null)
            {
                return invalid;
            }
        }

        return null;
    }

    /**
     * Checks the project's slug before it is written, so that a bad one comes back as an
     * error rather than as a failed write. Sets the slug from the name when there is none.
     */
    private OperationResult!IProjectError checkSlug(Project project)
    {
        const derived = project.slug.length == 0;
        if (derived)
        {
            project.slug = slugify(project.name);
        }

        if (!isSlug(project.slug))
        {
            return projectFailure(new SlugInvalidError);
        }

        if (reservedSlugs.canFind(project.slug))
        {
            return derived ? projectFailure(new NameReservedError) : projectFailure(new SlugReservedError);
        }

        const owner = repository.slugOwner(project.slug, project.id);
        if (!owner.isNull)
        {
            return derived ? projectFailure(new NameTakenError(owner.get)) : projectFailure(new SlugTakenError);
        }

        return projectSuccess();
    }

    /**
     * The error for a write the unique slug refused, as checkSlug would have answered had the
     * other project taken the slug before it rather than after. Only to be called once the write's
     * transaction is over, since it reads.
     *
     * Throws: The violation, when it is of another constraint than the slug's.
     */
    private IProjectError slugTaken(Project project, bool derived, UniqueViolation violation)
    {
        if (violation.constraint != "projects_slug_key")
        {
            throw violation;
        }

        if (!derived)
        {
            return new SlugTakenError;
        }

        const owner = repository.slugOwner(project.slug, project.id);
        return new NameTakenError(owner.isNull ? project.name : owner.get);
    }
}

/**
 * The rules lanes are read and written by. Every write it makes is reported to the event stream
 * once it has succeeded.
 */
class LaneService
{
    private ILaneRepository repository;
    private IProjectRepository projects;
    private IEventPublisher events;
    private ITransactional transactions;

    this(ILaneRepository repository, IProjectRepository projects, IEventPublisher events,
        ITransactional transactions)
    {
        this.repository = repository;
        this.projects = projects;
        this.events = events;
        this.transactions = transactions;
    }

    /**
     * Gets a project's lanes.
     *
     * Params:
     *   projectId = The project's id.
     *
     * Returns: Every lane of the project, in board order, or a failure: `ProjectNotFoundError`.
     */
    Result!(Lane[], ILaneError) getOfProject(UUID projectId)
    {
        if (!repository.projectExists(projectId))
        {
            return laneFailure!(Lane[])(new ProjectNotFoundError);
        }

        return laneSuccess(repository.ofProject(projectId));
    }

    /**
     * Gets a lane.
     *
     * Params:
     *   id = The lane's id.
     *
     * Returns: The lane with that id, or a failure: `LaneNotFoundError`.
     */
    Result!(Lane, ILaneError) get(UUID id)
    {
        auto lane = repository.find(id);
        if (lane.isNull)
        {
            return laneFailure!Lane(new LaneNotFoundError);
        }

        return laneSuccess(lane.get);
    }

    /**
     * Stores a lane.
     *
     * Creates the lane, in the project its `projectId` names, when it has no id yet, and updates
     * it otherwise; an update leaves it in the project it is in, whatever `projectId` it carries.
     * A lane with no position is put after the project's last lane.
     *
     * Params:
     *   lane = The lane to create or update.
     *
     * Returns: The lane as stored, or a failure: `LaneNameMissingError`,
     *   `LanePositionNegativeError`, `LaneColorInvalidError`, `ProjectNotFoundError`,
     *   `LaneNotFoundError` or `LanePositionTakenError`.
     */
    Result!(Lane, ILaneError) save(Lane lane)
    {
        auto invalid = checkLane!ILaneError(lane);
        if (invalid !is null)
        {
            return laneFailure!Lane(invalid);
        }

        return transactionally(transactions, () => place(lane));
    }

    /**
     * Creates or updates a lane, for save, in the transaction it opens. The lane's project is
     * locked first, as by every write to a project's lanes, so that lanes written at once are
     * placed one after the other.
     */
    private Result!(Lane, ILaneError) place(Lane lane)
    {
        const creating = lane.id == UUID.init;
        if (creating)
        {
            if (!projects.lock(lane.projectId))
            {
                return laneFailure!Lane(new ProjectNotFoundError);
            }
        }
        else
        {
            auto stored = repository.find(lane.id);
            // A lane whose project is gone is gone with it.
            if (stored.isNull || !projects.lock(stored.get.projectId))
            {
                return laneFailure!Lane(new LaneNotFoundError);
            }

            lane.projectId = stored.get.projectId;
        }

        // The lane itself is left out, so that an update neither places it after its own old
        // position nor finds that position taken.
        if (lane.position.isNull)
        {
            lane.position = repository.nextPosition(lane.projectId, lane.id);
        }

        if (repository.positionTaken(lane.projectId, lane.position.get, lane.id))
        {
            return laneFailure!Lane(new LanePositionTakenError);
        }

        if (creating)
        {
            repository.add(lane);
            events.lane(Event.created, lane.id, lane.projectId);
            return laneSuccess(lane);
        }

        if (!repository.update(lane))
        {
            return laneFailure!Lane(new LaneNotFoundError);
        }

        events.lane(Event.changed, lane.id, lane.projectId);
        return laneSuccess(lane);
    }

    /**
     * Deletes a lane, and the tasks in it.
     *
     * Params:
     *   id = The lane's id.
     *
     * Returns: Success, or a failure: `LaneNotFoundError`.
     */
    OperationResult!ILaneError remove(UUID id)
    {
        // The project is locked, as by every write to a project's lanes.
        return transactionally(transactions, {
            // Looked up first, since the lane is gone afterwards.
            auto lane = repository.find(id);
            if (lane.isNull || !projects.lock(lane.get.projectId) || !repository.remove(id))
            {
                return laneFailure(new LaneNotFoundError);
            }

            events.lane(Event.deleted, id, lane.get.projectId);
            return laneSuccess();
        });
    }
}

/// A task with its lane and its project, read with all three locked (see TaskService.lockTask).
private struct LockedTask
{
    Task task;
    Lane lane;
    Project project;
}

/// How many times TaskService.lockTask looks for the lane of a task that moves meanwhile.
private enum maxLockAttempts = 3;

/**
 * The rules tasks are read and written by. Every write it makes is reported to the event stream
 * once it has succeeded.
 */
class TaskService
{
    private ITaskRepository repository;
    private IProjectRepository projects;
    private ILaneRepository lanes;
    private IEventPublisher events;
    private IndexPages indexPages;
    private ITransactional transactions;

    this(ITaskRepository repository, IProjectRepository projects, ILaneRepository lanes, IEventPublisher events,
        IndexPages indexPages, ITransactional transactions)
    {
        this.repository = repository;
        this.projects = projects;
        this.lanes = lanes;
        this.events = events;
        this.indexPages = indexPages;
        this.transactions = transactions;
    }

    /**
     * Gets a project's tasks.
     *
     * Params:
     *   projectId = The project's id.
     *
     * Returns: Every task of the project, lane by lane in board order, and in lane order within
     *   each lane, or a failure: `ProjectNotFoundError`.
     */
    Result!(Task[], ITaskError) getOfProject(UUID projectId)
    {
        if (!repository.projectExists(projectId))
        {
            return taskFailure!(Task[])(new ProjectNotFoundError);
        }

        return taskSuccess(repository.ofProject(projectId));
    }

    /**
     * Gets a lane's tasks.
     *
     * Params:
     *   laneId = The lane's id.
     *
     * Returns: Every task of the lane, in lane order, or a failure: `LaneNotFoundError`.
     */
    Result!(Task[], ITaskError) getOfLane(UUID laneId)
    {
        if (repository.projectOfLane(laneId).isNull)
        {
            return taskFailure!(Task[])(new LaneNotFoundError);
        }

        return taskSuccess(repository.ofLane(laneId));
    }

    /**
     * Gets a task.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: The task with that id, or a failure: `TaskNotFoundError`.
     */
    Result!(Task, ITaskError) get(UUID id)
    {
        auto task = repository.find(id);
        if (task.isNull)
        {
            return taskFailure!Task(new TaskNotFoundError);
        }

        return taskSuccess(task.get);
    }

    /**
     * Gets a task's notes.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: The task's notes, newest first, or a failure: `TaskNotFoundError`.
     */
    Result!(TaskNote[], ITaskError) getNotes(UUID id)
    {
        if (repository.find(id).isNull)
        {
            return taskFailure!(TaskNote[])(new TaskNotFoundError);
        }

        return taskSuccess(repository.notes(id));
    }

    /**
     * Stores a task.
     *
     * Creates the task, in the lane its `laneId` names, when it has no id yet, and updates it
     * otherwise. An update may move the task to another lane of its project, and leaves it in
     * its lane when it carries no `laneId`. A task with no position goes to the bottom of its
     * lane.
     *
     * Params:
     *   task = The task to create or update.
     *
     * Returns: The task as stored, or a failure: `TaskDescriptionMissingError`,
     *   `TaskPositionNegativeError`, `LaneNotFoundError`, `LaneClosedToNewTasksError`,
     *   `TaskNotFoundError`, `TaskLeavesProjectError` or `TaskPositionTakenError`.
     */
    Result!(Task, ITaskError) save(Task task)
    {
        auto invalid = checkTask(task);
        if (invalid !is null)
        {
            return taskFailure!Task(invalid);
        }

        if (task.id == UUID.init)
        {
            return create(task);
        }

        auto stored = repository.find(task.id);
        if (stored.isNull)
        {
            return taskFailure!Task(new TaskNotFoundError);
        }

        if (task.laneId == UUID.init)
        {
            task.laneId = stored.get.laneId;
        }
        else if (task.laneId != stored.get.laneId)
        {
            auto project = repository.projectOfLane(task.laneId);
            if (project.isNull)
            {
                return taskFailure!Task(new LaneNotFoundError);
            }

            if (project.get != repository.projectOfLane(stored.get.laneId).get)
            {
                return taskFailure!Task(new TaskLeavesProjectError);
            }
        }

        // Taken now, since the stored task may be the very one the update changes.
        const fromLaneId = stored.get.laneId;
        try
        {
            if (!repository.update(task))
            {
                return taskFailure!Task(new TaskNotFoundError);
            }
        }
        catch (PositionConflict)
        {
            return taskFailure!Task(new TaskPositionTakenError);
        }
        catch (ForeignKeyViolation)
        {
            // The lane it moves to was deleted after the check above.
            return taskFailure!Task(new LaneNotFoundError);
        }

        auto projectId = repository.projectOfLane(task.laneId).get;
        events.task(Event.changed, task.id, projectId, fromLaneId, task.laneId);
        if (task.laneId != fromLaneId)
        {
            indexPages.check(projectId);
            rescheduleMoved(task.id);
        }

        return taskSuccess(task);
    }

    /**
     * Creates a task, for save. The lane's project is locked first, so that its add-task rule,
     * its lane order and whether it is managed by AI stay as read here until the task is in: a
     * write to any of them takes the same lock.
     */
    private Result!(Task, ITaskError) create(Task task)
    {
        return transactionally(transactions, {
            auto projectId = repository.projectOfLane(task.laneId);
            // Looked up again once locked, since the lane may have been deleted before the lock.
            if (projectId.isNull || !projects.lock(projectId.get) || repository.projectOfLane(task.laneId).isNull)
            {
                return taskFailure!Task(new LaneNotFoundError);
            }

            if (!repository.acceptsNewTasks(task.laneId))
            {
                return taskFailure!Task(new LaneClosedToNewTasksError);
            }

            // Only a project managed by AI hands its tasks to the agents, and one that is not when
            // the task is added keeps it from them, even should it be managed by AI later.
            auto project = projects.find(projectId.get);
            auto agentStatus = project.get.managedByAi ? AgentStatus.toBeScheduled.nullable
                : Nullable!AgentStatus.init;

            try
            {
                repository.add(task, agentStatus);
            }
            catch (PositionConflict)
            {
                return taskFailure!Task(new TaskPositionTakenError);
            }

            events.task(Event.created, task.id, projectId.get, UUID.init, task.laneId);
            return taskSuccess(task);
        });
    }

    /**
     * Moves a task to a lane of its project, just above another task of that lane or at its
     * bottom, and adds a change of lane to its notes.
     *
     * Params:
     *   id = The task's id.
     *   laneId = The lane it moves to, which may be the lane it is in.
     *   before = The task it goes just above, or null for the bottom of the lane.
     *
     * Returns: The tasks of the lane it moved to, in their new order, or a failure:
     *   `TaskNotFoundError`, `LaneNotFoundError`, `TaskLeavesProjectError`,
     *   `TaskBeforeItselfError`, `BeforeTaskNotFoundError` or `BeforeTaskNotInLaneError`.
     */
    Result!(Task[], ITaskError) move(UUID id, UUID laneId, Nullable!UUID before)
    {
        auto stored = repository.find(id);
        if (stored.isNull)
        {
            return taskFailure!(Task[])(new TaskNotFoundError);
        }

        auto project = repository.projectOfLane(laneId);
        if (project.isNull)
        {
            return taskFailure!(Task[])(new LaneNotFoundError);
        }

        if (project.get != repository.projectOfLane(stored.get.laneId).get)
        {
            return taskFailure!(Task[])(new TaskLeavesProjectError);
        }

        if (!before.isNull)
        {
            if (before.get == id)
            {
                return taskFailure!(Task[])(new TaskBeforeItselfError);
            }

            auto neighbour = repository.find(before.get);
            if (neighbour.isNull)
            {
                return taskFailure!(Task[])(new BeforeTaskNotFoundError);
            }

            if (neighbour.get.laneId != laneId)
            {
                return taskFailure!(Task[])(new BeforeTaskNotInLaneError);
            }
        }

        // Taken now, since the stored task may be the very one the move changes.
        const fromLaneId = stored.get.laneId;
        try
        {
            repository.move(id, laneId, before.isNull ? UUID.init : before.get);
        }
        catch (PositionConflict)
        {
            // The task to go above left the lane after the check above.
            return taskFailure!(Task[])(new BeforeTaskNotInLaneError);
        }

        events.task(Event.moved, id, project.get, fromLaneId, laneId);
        indexPages.check(project.get);
        if (laneId != fromLaneId)
        {
            rescheduleMoved(id);
        }

        return taskSuccess(repository.ofLane(laneId));
    }

    /**
     * Hands a task moved to another lane back to the task scheduler, when nothing is under way
     * for it (its agent status is terminal) and the scheduler would take it up: its project is
     * managed by AI and its new lane is not a done one. A move is how a person says the task is
     * to be worked on again.
     */
    private void rescheduleMoved(UUID id)
    {
        transactions.run({
            // A task gone or moving on is left alone: the move that made it so has its own turn.
            auto locked = lockTask(id);
            if (locked.isFailure)
            {
                return false;
            }

            auto status = repository.agentStatus(id);
            if (status.isNull || !terminalAgentStatuses.canFind(status.get))
            {
                return false;
            }

            auto project = locked.value.project;
            if (!project.managedByAi || locked.value.lane.marksDone)
            {
                return false;
            }

            if (repository.reschedule(id))
            {
                events.note(id, project.id);
            }

            return true;
        });
    }

    /**
     * Locks a task's project, its lane and the task itself, in that order, in the open
     * transaction, and reads all three as they are once locked.
     *
     * The lane is read from the task before it is locked, so the task can move to another lane in
     * between. Then that lane is locked as well, and the task read again, a few times at most;
     * once the task is locked it cannot move again, so one more time is enough. A lane locked
     * after the task breaks the lock order, but only on this rare path, and the deadlock it can
     * cause is answered as any other. The project needs no second look: a lane never changes
     * project.
     *
     * Returns: The task, its lane and its project, or a failure: `TaskNotFoundError`, or
     *   `TaskKeptMovingError` when the task moved every time.
     */
    private Result!(LockedTask, ITaskError) lockTask(UUID id)
    {
        auto task = repository.find(id);
        auto lane = task.isNull ? Nullable!Lane.init : lanes.find(task.get.laneId);
        // A lane, and its tasks, can only be deleted with its project locked, so a task whose
        // lane is still there once the project is locked is still there too, unless deleted itself.
        if (lane.isNull || !projects.lock(lane.get.projectId))
        {
            return taskFailure!LockedTask(new TaskNotFoundError);
        }

        auto laneId = lane.get.id;
        foreach (attempt; 0 .. maxLockAttempts)
        {
            if (!lanes.lock(laneId) || !repository.lock(id))
            {
                return taskFailure!LockedTask(new TaskNotFoundError);
            }

            auto current = repository.find(id).get;
            if (current.laneId == laneId)
            {
                return taskSuccess(LockedTask(current, lanes.find(laneId).get, projects.find(lane.get.projectId).get));
            }

            laneId = current.laneId;
        }

        return taskFailure!LockedTask(new TaskKeptMovingError);
    }

    /**
     * Hands a task back to the task scheduler, which takes it up again as it does any task to be
     * scheduled: it is taken off its agent, and the scheduler chooses an agent and a lane for it
     * once more. A last resort for a task no agent is working on, such as one the scheduler
     * declined. A task of a paused project waits until the project's agents are resumed.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: Success, or a failure: `TaskNotFoundError`, `ProjectNotManagedByAiError` for a
     *   task of a project whose tasks the agents do not work on, `TaskDoneError` for a task in a
     *   done lane, `TaskBeingScheduledError` for one the scheduler is at now, or
     *   `TaskBeingWorkedOnError` for one an agent is working on now.
     */
    OperationResult!ITaskError reschedule(UUID id)
    {
        // Locked, so that the project is not taken off AI management, nor the task put in a done
        // lane, between the checks and the write.
        return transactionally(transactions, {
            auto locked = lockTask(id);
            if (locked.isFailure)
            {
                return taskFailure(locked.error);
            }

            auto project = locked.value.project;
            if (!project.managedByAi)
            {
                return taskFailure(new ProjectNotManagedByAiError);
            }

            if (locked.value.lane.marksDone)
            {
                return taskFailure(new TaskDoneError);
            }

            if (!repository.reschedule(id))
            {
                // With the task locked, only its agent status can stand in the way.
                auto status = repository.agentStatus(id);
                if (!status.isNull && status.get == AgentStatus.executing)
                {
                    return taskFailure(new TaskBeingWorkedOnError);
                }

                return taskFailure(new TaskBeingScheduledError);
            }

            events.note(id, project.id);
            return taskSuccess();
        });
    }

    /**
     * Deletes a task.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: Success, or a failure: `TaskNotFoundError`.
     */
    OperationResult!ITaskError remove(UUID id)
    {
        // Looked up first, since the task and the way to its project are gone afterwards.
        auto task = repository.find(id);
        if (task.isNull)
        {
            return taskFailure(new TaskNotFoundError);
        }

        auto projectId = repository.projectOfLane(task.get.laneId);
        if (!repository.remove(id))
        {
            return taskFailure(new TaskNotFoundError);
        }

        events.task(Event.deleted, id, projectId.get, task.get.laneId, UUID.init);
        return taskSuccess();
    }

    /**
     * Deletes every task of a lane at once, such as the finished tasks of a done lane.
     *
     * Params:
     *   laneId = The lane's id.
     *
     * Returns: Success, or a failure: `LaneNotFoundError`.
     */
    OperationResult!ITaskError clear(UUID laneId)
    {
        auto lane = lanes.find(laneId);
        if (lane.isNull)
        {
            return taskFailure(new LaneNotFoundError);
        }

        repository.removeOfLane(laneId);
        events.lane(Event.cleared, laneId, lane.get.projectId);
        return taskSuccess();
    }
}

/// Reads the runtimes and models, which are fixed data and cannot be written.
class RuntimeService
{
    private IRuntimeRepository repository;

    this(IRuntimeRepository repository)
    {
        this.repository = repository;
    }

    /**
     * Gets every runtime.
     *
     * Returns: Every runtime, by name.
     */
    Runtime[] getAll()
    {
        return repository.all();
    }

    /**
     * Gets every model.
     *
     * Returns: Every model, by runtime and then by name, with the effort levels it takes.
     */
    Model[] getModels()
    {
        return repository.models();
    }
}

/**
 * The rules AI agents are read and written by. Every write it makes is reported to the event
 * stream once it has succeeded.
 */
class AgentService
{
    private IAgentRepository repository;
    private IRuntimeRepository runtimes;
    private IEventPublisher events;
    private IAgentChat chats;

    this(IAgentRepository repository, IRuntimeRepository runtimes, IEventPublisher events, IAgentChat chats)
    {
        this.repository = repository;
        this.runtimes = runtimes;
        this.events = events;
        this.chats = chats;
    }

    /**
     * Gets every agent.
     *
     * Returns: Every agent, the task schedulers first, and by name within each group.
     */
    Agent[] getAll()
    {
        return repository.all();
    }

    /**
     * Gets an agent.
     *
     * Params:
     *   id = The agent's id.
     *
     * Returns: The agent with that id, or a failure: `AgentNotFoundError`.
     */
    Result!(Agent, IAgentError) get(UUID id)
    {
        auto agent = repository.find(id);
        if (agent.isNull)
        {
            return agentFailure!Agent(new AgentNotFoundError);
        }

        return agentSuccess(agent.get);
    }

    /**
     * Stores an agent, and gives it exactly its labels.
     *
     * Creates the agent when it has no id yet, and updates it otherwise.
     *
     * Params:
     *   agent = The agent to create or update.
     *
     * Returns: The agent as stored, or a failure: `AgentNameMissingError`,
     *   `AgentRuntimeMissingError`, `AgentModelMissingError`,
     *   `MaxParallelTasksInvalidError`, `LabelBlankError`,
     *   `LabelRepeatedError`, `RuntimeNotFoundError`, `ModelNotOfferedError`,
     *   `EffortNotTakenError`, `AgentNameTakenError` or `AgentNotFoundError`.
     */
    Result!(Agent, IAgentError) save(Agent agent)
    {
        auto invalid = checkAgent(agent);
        if (invalid !is null)
        {
            return agentFailure!Agent(invalid);
        }

        // The agents' foreign keys and unique name, checked before the write so that a clash
        // comes back as an error rather than as a failed write.
        const runtime = runtimes.name(agent.runtime);
        if (runtime.isNull)
        {
            return agentFailure!Agent(new RuntimeNotFoundError);
        }

        if (!runtimes.offers(agent.runtime, agent.model))
        {
            return agentFailure!Agent(new ModelNotOfferedError(runtime.get));
        }

        if (!runtimes.takes(agent.model, agent.effort))
        {
            return agentFailure!Agent(new EffortNotTakenError);
        }

        if (repository.nameTaken(agent.name, agent.id))
        {
            return agentFailure!Agent(new AgentNameTakenError);
        }

        try
        {
            if (agent.id == UUID.init)
            {
                repository.add(agent);
                events.agent(Event.created, agent.id);
                return agentSuccess(agent);
            }

            if (!repository.update(agent))
            {
                return agentFailure!Agent(new AgentNotFoundError);
            }
        }
        catch (UniqueViolation violation)
        {
            // Another agent took the name after the check above.
            if (violation.constraint != "agents_name_key")
            {
                throw violation;
            }

            return agentFailure!Agent(new AgentNameTakenError);
        }

        events.agent(Event.changed, agent.id);
        return agentSuccess(agent);
    }

    /**
     * Enables or disables an agent, and changes nothing else about it.
     *
     * Params:
     *   id = The agent's id.
     *   enabled = Whether the agent is to be enabled.
     *
     * Returns: Success, or a failure: `AgentNotFoundError`.
     */
    OperationResult!IAgentError setEnabled(UUID id, bool enabled)
    {
        if (!repository.setEnabled(id, enabled))
        {
            return agentFailure(new AgentNotFoundError);
        }

        events.agent(Event.changed, id);
        return agentSuccess();
    }

    /**
     * Enables or disables every agent that is not so already.
     *
     * Params:
     *   enabled = Whether the agents are to be enabled.
     *
     * Returns: The ids of the agents it changed.
     */
    UUID[] setAllEnabled(bool enabled)
    {
        auto changed = repository.setAllEnabled(enabled);
        foreach (id; changed)
        {
            events.agent(Event.changed, id);
        }

        return changed;
    }

    /**
     * Deletes an agent, and ends every chat with it, since a chat with an agent that is gone
     * cannot be continued.
     *
     * Params:
     *   id = The agent's id.
     *
     * Returns: Success, or a failure: `AgentNotFoundError`.
     */
    OperationResult!IAgentError remove(UUID id)
    {
        if (!repository.remove(id))
        {
            return agentFailure(new AgentNotFoundError);
        }

        events.agent(Event.deleted, id);
        chats.endAll(id);
        return agentSuccess();
    }
}

/// Reads the defaults, a value per key, which nothing writes yet.
class DefaultService
{
    private IDefaultRepository repository;

    this(IDefaultRepository repository)
    {
        this.repository = repository;
    }

    /**
     * Gets every default.
     *
     * Returns: Every default, by key.
     */
    Default[] getAll()
    {
        return repository.all();
    }
}

/**
 * Why a ProjectService operation failed.
 *
 * Each kind of failure is a class of its own, so that one that needs to say more, such as
 * which project already has a name, can carry it.
 */
interface IProjectError
{
}

/// No project has the id given.
class ProjectNotFoundError : IProjectError, ILaneError, ITaskError
{
}

/// The project is not managed by AI, so it has no agents to resume or to hand its tasks to.
class ProjectNotManagedByAiError : IProjectError, ITaskError
{
}

/// The project's name is blank.
class ProjectNameMissingError : IProjectError
{
}

/// The project's name has no letter or digit in it, so no slug can be made from it.
class ProjectNameUnusableError : IProjectError
{
}

/// The project's slug is not lowercase words joined by single hyphens.
class SlugInvalidError : IProjectError
{
}

/// The project's slug is one of the reservedSlugs.
class SlugReservedError : IProjectError
{
}

/// Another project already has the project's slug.
class SlugTakenError : IProjectError
{
}

/// The slug made from the project's name, as it had none, is one of the reservedSlugs.
class NameReservedError : IProjectError
{
}

/// Another project already has the slug made from the project's name, as it had none.
class NameTakenError : IProjectError
{
    /// The name of the project that has the slug.
    string ownerName;

    this(string ownerName)
    {
        this.ownerName = ownerName;
    }
}

/// A lane given for a project is another project's.
class LaneOfOtherProjectError : IProjectError
{
}

/// No lane has the id given, such as for one of a project's lanes.
class LaneNotFoundError : IProjectError, ILaneError, ITaskError
{
}

/// A lane is given more than once for the same project.
class LaneListedTwiceError : IProjectError
{
}

/// Why a LaneService operation failed. See IProjectError.
interface ILaneError
{
}

/// Why a TaskService operation failed. See IProjectError.
interface ITaskError
{
}

/// Why an AgentService operation failed. See IProjectError.
interface IAgentError
{
}

/// Another lane of the project is already at the lane's position.
class LanePositionTakenError : ILaneError
{
}

/// A lane's name is blank.
class LaneNameMissingError : IProjectError, ILaneError
{
}

/// A lane's position is below 0.
class LanePositionNegativeError : IProjectError, ILaneError
{
}

/// A lane's colour is not "#" and six hex digits.
class LaneColorInvalidError : IProjectError, ILaneError
{
}

/// A task is to be moved just above itself.
class TaskBeforeItselfError : ITaskError
{
}

/// No task has the id given for the task to move a task just above.
class BeforeTaskNotFoundError : ITaskError
{
}

/// The task to move a task just above is not in the lane it moves to.
class BeforeTaskNotInLaneError : ITaskError
{
}

/// The task's description is blank.
class TaskDescriptionMissingError : ITaskError
{
}

/// The task's position is below 0.
class TaskPositionNegativeError : ITaskError
{
}

/// No task has the id given.
class TaskNotFoundError : ITaskError
{
}

/// The lane does not take new tasks, as its project only takes them in its first lane.
class LaneClosedToNewTasksError : ITaskError
{
}

/// The lane a task is moved to is another project's.
class TaskLeavesProjectError : ITaskError
{
}

/// Another task of the lane is already at the task's position.
class TaskPositionTakenError : ITaskError
{
}

/// The task is in a lane whose tasks count as done.
class TaskDoneError : ITaskError
{
}

/// The task scheduler is choosing an agent for the task now.
class TaskBeingScheduledError : ITaskError
{
}

/// The agent the task is assigned to is working on it now.
class TaskBeingWorkedOnError : ITaskError
{
}

/// The task kept moving to other lanes while it was being locked, so it was left alone.
class TaskKeptMovingError : ITaskError
{
}

/// No agent has the id given.
class AgentNotFoundError : IAgentError
{
}

/// There is no runtime with the agent's runtime id.
class RuntimeNotFoundError : IAgentError
{
}

/// The agent's runtime offers no model with the agent's model id.
class ModelNotOfferedError : IAgentError
{
    /// The name of the agent's runtime.
    string runtimeName;

    this(string runtimeName)
    {
        this.runtimeName = runtimeName;
    }
}

/// The agent's model takes no effort level with the agent's effort id.
class EffortNotTakenError : IAgentError
{
}

/// Another agent already has the agent's name.
class AgentNameTakenError : IAgentError
{
}

/// The agent's name is blank.
class AgentNameMissingError : IAgentError
{
}

/// The agent has no runtime.
class AgentRuntimeMissingError : IAgentError
{
}

/// The agent has no model.
class AgentModelMissingError : IAgentError
{
}

/// The agent's limit on parallel tasks is not above 0.
class MaxParallelTasksInvalidError : IAgentError
{
}

/// One of the agent's labels is blank.
class LabelBlankError : IAgentError
{
}

/// The agent is given the same label more than once.
class LabelRepeatedError : IAgentError
{
    /// The label given more than once, lowercased.
    string label;

    this(string label)
    {
        this.label = label;
    }
}

/**
 * The project name check constraints in sql/init.sql, checked before the write so that a bad
 * name comes back as an error rather than as a failed write. A letter or digit is asked for so
 * that a slug can always be made from the name.
 *
 * Returns: The error, or null when the name is fine.
 */
private IProjectError checkName(Project project)
{
    if (project is null || project.name.strip.length == 0)
    {
        return new ProjectNameMissingError;
    }

    if (!hasLetterOrDigit(project.name))
    {
        return new ProjectNameUnusableError;
    }

    return null;
}

/**
 * The lane check constraints in sql/init.sql, checked before the write so that a bad field
 * comes back as an error rather than as a failed write. The colour is lowercased first, since
 * the column only takes lowercase hex.
 *
 * Params:
 *   E = The error interface of the service checking it; every lane error implements each.
 *   lane = The lane to check.
 *
 * Returns: The error, or null when the lane is fine.
 */
private E checkLane(E)(Lane lane)
{
    if (lane is null || lane.name.strip.length == 0)
    {
        return new LaneNameMissingError;
    }

    if (!lane.position.isNull && lane.position.get < 0)
    {
        return new LanePositionNegativeError;
    }

    lane.color = lane.color.toLower;
    if (!isHexColor(lane.color))
    {
        return new LaneColorInvalidError;
    }

    return null;
}

/**
 * The task check constraints in sql/init.sql, checked before the write so that a bad field
 * comes back as an error rather than as a failed write.
 *
 * Returns: The error, or null when the task is fine.
 */
private ITaskError checkTask(Task task)
{
    if (task is null || task.description.strip.length == 0)
    {
        return new TaskDescriptionMissingError;
    }

    if (!task.position.isNull && task.position.get < 0)
    {
        return new TaskPositionNegativeError;
    }

    return null;
}

/**
 * The agent check constraints in sql/init.sql, checked before the write so that a bad field
 * comes back as an error rather than as a failed write. The labels are lowercased first, since
 * the column only takes lowercase.
 *
 * Returns: The error, or null when the agent is fine.
 */
private IAgentError checkAgent(Agent agent)
{
    if (agent is null || agent.name.strip.length == 0)
    {
        return new AgentNameMissingError;
    }

    if (agent.runtime.strip.length == 0)
    {
        return new AgentRuntimeMissingError;
    }

    if (agent.model.strip.length == 0)
    {
        return new AgentModelMissingError;
    }

    if (!agent.maxParallelTasks.isNull && agent.maxParallelTasks.get <= 0)
    {
        return new MaxParallelTasksInvalidError;
    }

    foreach (ref label; agent.labels)
    {
        label = label.toLower;
    }

    foreach (index, label; agent.labels)
    {
        if (label.strip.length == 0)
        {
            return new LabelBlankError;
        }

        if (agent.labels[0 .. index].canFind(label))
        {
            return new LabelRepeatedError(label);
        }
    }

    return null;
}

/**
 * Runs work in one transaction, which is committed when the result work returns is a success and
 * rolled back when it is a failure.
 *
 * Params:
 *   R = The service's result type, a Result or an OperationResult.
 *   transactions = What runs the transaction.
 *   work = The checks and writes.
 *
 * Returns: The result work returned.
 */
private R transactionally(R)(ITransactional transactions, scope R delegate() work)
{
    R result;
    transactions.run({
        result = work();
        return result.isSuccessful;
    });

    return result;
}

/// A successful result of a ProjectService call, which could have failed with an IProjectError.
private Result!(T, IProjectError) projectSuccess(T)(T value)
{
    return success!IProjectError(value);
}

/// Ditto
private OperationResult!IProjectError projectSuccess()
{
    return success!IProjectError();
}

/**
 * A failed result of a ProjectService call, of IProjectError rather than of the error's own
 * class, which is what failure would make of it.
 */
private Result!(T, IProjectError) projectFailure(T)(IProjectError error)
{
    return failure!T(error);
}

/// Ditto
private OperationResult!IProjectError projectFailure(IProjectError error)
{
    return failure(error);
}

/// A successful result of a LaneService call, which could have failed with an ILaneError.
private Result!(T, ILaneError) laneSuccess(T)(T value)
{
    return success!ILaneError(value);
}

/// Ditto
private OperationResult!ILaneError laneSuccess()
{
    return success!ILaneError();
}

/// A failed result of a LaneService call, of ILaneError (see projectFailure).
private Result!(T, ILaneError) laneFailure(T)(ILaneError error)
{
    return failure!T(error);
}

/// Ditto
private OperationResult!ILaneError laneFailure(ILaneError error)
{
    return failure(error);
}

/// A successful result of a TaskService call, which could have failed with an ITaskError.
private Result!(T, ITaskError) taskSuccess(T)(T value)
{
    return success!ITaskError(value);
}

/// Ditto
private OperationResult!ITaskError taskSuccess()
{
    return success!ITaskError();
}

/// A failed result of a TaskService call, of ITaskError (see projectFailure).
private Result!(T, ITaskError) taskFailure(T)(ITaskError error)
{
    return failure!T(error);
}

/// Ditto
private OperationResult!ITaskError taskFailure(ITaskError error)
{
    return failure(error);
}

/// A successful result of an AgentService call, which could have failed with an IAgentError.
private Result!(T, IAgentError) agentSuccess(T)(T value)
{
    return success!IAgentError(value);
}

/// Ditto
private OperationResult!IAgentError agentSuccess()
{
    return success!IAgentError();
}

/// A failed result of an AgentService call, of IAgentError (see projectFailure).
private Result!(T, IAgentError) agentFailure(T)(IAgentError error)
{
    return failure!T(error);
}

/// Ditto
private OperationResult!IAgentError agentFailure(IAgentError error)
{
    return failure(error);
}

version (unittest)
{
    import std.algorithm : max;
    import std.typecons : nullable;
    import std.uuid : randomUUID;

    import config : Config;
    import model : TaskAddRule;

    /// What an IEventPublisher was told about one resource.
    private struct Published
    {
        Event event;
        /// The id of the resource it concerns.
        UUID id;
    }

    /// An IEventPublisher that keeps the events it is told about, resource by resource.
    private class MockEventPublisher : IEventPublisher
    {
        Published[] projects;
        Published[] lanes;
        Published[] tasks;
        Published[] agents;
        /// The tasks a note was reported on.
        UUID[] notes;

        void task(Event event, UUID taskId, UUID projectId, UUID fromLaneId, UUID toLaneId)
        {
            tasks ~= Published(event, taskId);
        }

        void lane(Event event, UUID laneId, UUID projectId)
        {
            lanes ~= Published(event, laneId);
        }

        void project(Event event, UUID projectId)
        {
            projects ~= Published(event, projectId);
        }

        void note(UUID taskId, UUID projectId)
        {
            notes ~= taskId;
        }

        void agent(Event event, UUID agentId)
        {
            agents ~= Published(event, agentId);
        }
    }

    /**
     * An ITransactional with no database under it: it holds back what is to run after the
     * commit until work is done, and drops it when work asks for a rollback, but undoes no write.
     */
    private class MockTransactional : ITransactional
    {
        private bool open;
        private void delegate()[] pending;

        void run(scope bool delegate() work)
        {
            open = true;
            const commit = work();
            open = false;

            auto ran = pending;
            pending = null;
            if (commit)
            {
                foreach (dg; ran)
                {
                    dg();
                }
            }
        }

        void afterCommit(void delegate() dg)
        {
            if (open)
            {
                pending ~= dg;
                return;
            }

            dg();
        }
    }

    /// The rows the mock repositories share, held in memory.
    private class MockDatabase
    {
        Project[] projects;
        Lane[] lanes;
        Task[] tasks;
        /// The agent status each task was added with, which a Task does not carry.
        Nullable!AgentStatus[UUID] agentStatuses;
        Agent[] agents;
        /// The lanes the last replaceWithLanes was told to delete.
        UUID[] removedLanes;
    }

    /// An IProjectRepository over a MockDatabase.
    private class MockProjectRepository : IProjectRepository
    {
        private MockDatabase database;

        this(MockDatabase database)
        {
            this.database = database;
        }

        Project[] all()
        {
            return database.projects;
        }

        Nullable!Project find(UUID id)
        {
            auto found = database.projects.filter!(project => project.id == id);
            return found.empty ? Nullable!Project.init : found.front.nullable;
        }

        bool lock(UUID id)
        {
            return !find(id).isNull;
        }

        Nullable!string slugOwner(string slug, UUID except)
        {
            auto found = database.projects.filter!(project => project.slug == slug && project.id != except);
            return found.empty ? Nullable!string.init : found.front.name.nullable;
        }

        Project add(Project project)
        {
            project.id = randomUUID;
            database.projects ~= project;
            return project;
        }

        bool update(Project project)
        {
            foreach (ref stored; database.projects)
            {
                if (stored.id == project.id)
                {
                    stored = project;
                    return true;
                }
            }

            return false;
        }

        bool setAiPaused(UUID id, bool paused)
        {
            auto project = find(id);
            if (project.isNull)
            {
                return false;
            }

            project.get.aiPaused = paused;
            return true;
        }

        void addWithLanes(Project project, Lane[] lanes)
        {
            add(project);
            foreach (lane; lanes)
            {
                lane.id = randomUUID;
                lane.projectId = project.id;
                database.lanes ~= lane;
            }
        }

        bool replaceWithLanes(Project project, Lane[] lanes, UUID[] removed)
        {
            if (!update(project))
            {
                return false;
            }

            database.removedLanes = removed;
            database.lanes = database.lanes.filter!(lane => !removed.canFind(lane.id)).array;
            foreach (lane; lanes.filter!(lane => lane.id == UUID.init))
            {
                lane.id = randomUUID;
                lane.projectId = project.id;
                database.lanes ~= lane;
            }

            return true;
        }

        bool remove(UUID id)
        {
            const before = database.projects.length;
            database.projects = database.projects.filter!(project => project.id != id).array;
            return database.projects.length < before;
        }
    }

    /// An ILaneRepository over a MockDatabase, with only what ProjectService reads.
    private class MockLaneRepository : ILaneRepository
    {
        private MockDatabase database;

        this(MockDatabase database)
        {
            this.database = database;
        }

        Lane[] ofProject(UUID projectId)
        {
            return database.lanes.filter!(lane => lane.projectId == projectId).array;
        }

        Nullable!Lane find(UUID id)
        {
            auto found = database.lanes.filter!(lane => lane.id == id);
            return found.empty ? Nullable!Lane.init : found.front.nullable;
        }

        bool lock(UUID id)
        {
            return !find(id).isNull;
        }

        bool projectExists(UUID projectId)
        {
            return database.projects.canFind!(project => project.id == projectId);
        }

        int nextPosition(UUID projectId, UUID except)
        {
            int next = 0;
            foreach (lane; database.lanes.filter!(candidate => candidate.projectId == projectId
                    && candidate.id != except))
            {
                next = max(next, lane.position.get + 1);
            }

            return next;
        }

        bool positionTaken(UUID projectId, int position, UUID except)
        {
            return database.lanes.canFind!(lane => lane.projectId == projectId && lane.position.get == position
                && lane.id != except);
        }

        Lane add(Lane lane)
        {
            lane.id = randomUUID;
            database.lanes ~= lane;
            return lane;
        }

        bool update(Lane lane)
        {
            foreach (ref stored; database.lanes)
            {
                if (stored.id == lane.id)
                {
                    stored = lane;
                    return true;
                }
            }

            return false;
        }

        bool remove(UUID id)
        {
            const before = database.lanes.length;
            database.lanes = database.lanes.filter!(lane => lane.id != id).array;
            database.tasks = database.tasks.filter!(task => task.laneId != id).array;
            return database.lanes.length < before;
        }
    }

    /// An ITaskRepository over a MockDatabase, with only what TaskService reads and writes.
    private class MockTaskRepository : ITaskRepository
    {
        private MockDatabase database;

        this(MockDatabase database)
        {
            this.database = database;
        }

        Task[] ofLane(UUID laneId)
        {
            return database.tasks.filter!(task => task.laneId == laneId).array;
        }

        Task[] ofProject(UUID projectId)
        {
            return database.tasks.filter!(task => projectOfLane(task.laneId) == projectId).array;
        }

        Nullable!Task find(UUID id)
        {
            auto found = database.tasks.filter!(task => task.id == id);
            return found.empty ? Nullable!Task.init : found.front.nullable;
        }

        bool lock(UUID id)
        {
            return !find(id).isNull;
        }

        Task[] awaitingScheduling()
        {
            assert(false, "Not used by TaskService.");
        }

        Task[] awaitingExecution()
        {
            assert(false, "Not used by TaskService.");
        }

        bool changeAgentStatus(UUID id, AgentStatus from, AgentStatus to)
        {
            assert(false, "Not used by TaskService.");
        }

        ulong changeAgentStatuses(AgentStatus from, AgentStatus to)
        {
            assert(false, "Not used by TaskService.");
        }

        TaskNote[] notes(UUID taskId)
        {
            return null;
        }

        bool projectExists(UUID projectId)
        {
            return database.projects.canFind!(project => project.id == projectId);
        }

        Nullable!UUID projectOfLane(UUID laneId)
        {
            auto found = database.lanes.filter!(lane => lane.id == laneId);
            return found.empty ? Nullable!UUID.init : found.front.projectId.nullable;
        }

        bool acceptsNewTasks(UUID laneId)
        {
            auto lane = database.lanes.filter!(candidate => candidate.id == laneId).front;
            auto project = database.projects.filter!(candidate => candidate.id == lane.projectId).front;
            return project.taskAddRule == TaskAddRule.anyLane || !database.lanes.canFind!(
                other => other.projectId == lane.projectId && other.position.get < lane.position.get);
        }

        Task add(Task task, Nullable!AgentStatus agentStatus)
        {
            place(task);
            task.id = randomUUID;
            database.tasks ~= task;
            database.agentStatuses[task.id] = agentStatus;
            return task;
        }

        bool update(Task task)
        {
            if (find(task.id).isNull)
            {
                return false;
            }

            place(task);
            foreach (ref stored; database.tasks)
            {
                if (stored.id == task.id)
                {
                    stored = task;
                }
            }

            return true;
        }

        /// As the postgres repository does: the bottom of the lane for a task with no position.
        private void place(Task task)
        {
            if (task.position.isNull)
            {
                int next = 0;
                foreach (other; database.tasks.filter!(candidate => candidate.laneId == task.laneId
                        && candidate.id != task.id))
                {
                    next = max(next, other.position.get + 1);
                }

                task.position = next;
            }
            else if (database.tasks.canFind!(other => other.laneId == task.laneId
                    && other.position.get == task.position.get && other.id != task.id))
            {
                throw new PositionConflict("Taken.");
            }
        }

        /// Moves the task, shifting the tasks from `before` on down by one, as postgres does.
        void move(UUID id, UUID laneId, UUID before)
        {
            auto task = find(id).get;
            if (before == UUID.init)
            {
                task.laneId = laneId;
                task.position = Nullable!int.init;
                place(task);
                return;
            }

            auto neighbour = find(before);
            if (neighbour.isNull || neighbour.get.laneId != laneId)
            {
                throw new PositionConflict("Gone.");
            }

            const position = neighbour.get.position.get;
            foreach (other; database.tasks.filter!(candidate => candidate.laneId == laneId && candidate.id != id))
            {
                if (other.position.get >= position)
                {
                    other.position = other.position.get + 1;
                }
            }

            task.laneId = laneId;
            task.position = position;
        }

        Nullable!UUID assignedAiAgent(UUID id)
        {
            assert(false, "Not used by TaskService.");
        }

        bool assignAiAgent(UUID id, Nullable!UUID agentId)
        {
            assert(false, "Not used by TaskService.");
        }

        bool recordSchedulingFailure(UUID id, UUID schedulerId)
        {
            assert(false, "Not used by TaskService.");
        }

        bool recordNoAgentFound(UUID id, UUID schedulerId)
        {
            assert(false, "Not used by TaskService.");
        }

        bool recordExecutionFailure(UUID id, UUID agentId)
        {
            assert(false, "Not used by TaskService.");
        }

        bool addNote(UUID id, string note)
        {
            assert(false, "Not used by TaskService.");
        }

        Nullable!AgentStatus agentStatus(UUID id)
        {
            auto status = id in database.agentStatuses;
            return status is null ? Nullable!AgentStatus.init : *status;
        }

        bool[UUID] agentsAtWork(UUID[] ids)
        {
            assert(false, "Not used by TaskService.");
        }

        bool endStoppedRun(UUID id, AgentStatus from, AgentStatus to, bool unassign, string note)
        {
            assert(false, "Not used by TaskService.");
        }

        bool reschedule(UUID id)
        {
            auto status = id in database.agentStatuses;
            if (find(id).isNull || (status !is null && !status.isNull
                    && [AgentStatus.scheduling, AgentStatus.executing].canFind(status.get)))
            {
                return false;
            }

            database.agentStatuses[id] = AgentStatus.toBeScheduled.nullable;
            return true;
        }

        bool recordNoScheduler(UUID id)
        {
            assert(false, "Not used by TaskService.");
        }

        bool remove(UUID id)
        {
            const before = database.tasks.length;
            database.tasks = database.tasks.filter!(task => task.id != id).array;
            return database.tasks.length < before;
        }

        ulong removeOfLane(UUID laneId)
        {
            const before = database.tasks.length;
            database.tasks = database.tasks.filter!(task => task.laneId != laneId).array;
            return before - database.tasks.length;
        }
    }

    /// An IAgentRepository over a MockDatabase.
    private class MockAgentRepository : IAgentRepository
    {
        private MockDatabase database;

        this(MockDatabase database)
        {
            this.database = database;
        }

        Agent[] all()
        {
            return database.agents;
        }

        Nullable!Agent find(UUID id)
        {
            auto found = database.agents.filter!(agent => agent.id == id);
            return found.empty ? Nullable!Agent.init : found.front.nullable;
        }

        bool setEnabled(UUID id, bool enabled)
        {
            auto found = find(id);
            if (found.isNull)
            {
                return false;
            }

            found.get.enabled = enabled;
            return true;
        }

        UUID[] setAllEnabled(bool enabled)
        {
            auto others = database.agents.filter!(agent => agent.enabled != enabled).array;
            foreach (agent; others)
            {
                agent.enabled = enabled;
            }

            return others.map!(agent => agent.id).array;
        }

        bool nameTaken(string name, UUID except)
        {
            return database.agents.canFind!(agent => agent.name == name && agent.id != except);
        }

        Agent add(Agent agent)
        {
            agent.id = randomUUID;
            agent.enabled = true;
            database.agents ~= agent;
            return agent;
        }

        bool update(Agent agent)
        {
            foreach (ref stored; database.agents)
            {
                if (stored.id == agent.id)
                {
                    agent.enabled = stored.enabled;
                    stored = agent;
                    return true;
                }
            }

            return false;
        }

        bool remove(UUID id)
        {
            const before = database.agents.length;
            database.agents = database.agents.filter!(agent => agent.id != id).array;
            return database.agents.length < before;
        }
    }

    /// An IRuntimeRepository with one runtime, "claude-code", offering one model at one effort level.
    private class MockRuntimeRepository : IRuntimeRepository
    {
        Runtime[] all()
        {
            assert(false, "Not used by AgentService.");
        }

        Model[] models()
        {
            assert(false, "Not used by AgentService.");
        }

        Nullable!string name(string id)
        {
            return id == "claude-code" ? "Claude Code".nullable : Nullable!string.init;
        }

        bool offers(string runtime, string model)
        {
            return runtime == "claude-code" && model == "sonnet";
        }

        bool takes(string model, string effort)
        {
            return model == "sonnet" && effort == "default";
        }
    }

    /// An IAgentChat that keeps the agents whose chats it was told to end.
    private class MockAgentChat : IAgentChat
    {
        UUID[] endedAgents;

        string send(Agent agent, Nullable!Project project, string message, ref string sessionId)
        {
            assert(false, "Not used by AgentService.");
        }

        void end(UUID agentId, UUID sessionId) nothrow
        {
            assert(false, "Not used by AgentService.");
        }

        void endAll(UUID agentId) nothrow
        {
            endedAgents ~= agentId;
        }
    }

    /// Working directories under a root that is not there, so that the tests make none.
    private ProjectWorkingDirs noWorkingDirs()
    {
        auto config = new Config;
        config.projectWorkingDirRoot = "/nonexistent/taskavista-test-projects";
        return new ProjectWorkingDirs(config);
    }

    /// A ProjectService over mock repositories that share `database`, reporting to `events`.
    private ProjectService serviceOver(MockDatabase database, MockEventPublisher events = new MockEventPublisher)
    {
        return new ProjectService(new MockProjectRepository(database), new MockLaneRepository(database), events,
            noWorkingDirs(), new MockTransactional);
    }

    /// A LaneService over mock repositories that share `database`, reporting to `events`.
    private LaneService laneServiceOver(MockDatabase database, MockEventPublisher events = new MockEventPublisher)
    {
        return new LaneService(new MockLaneRepository(database), new MockProjectRepository(database), events,
            new MockTransactional);
    }

    /// A TaskService over mock repositories that share `database`.
    private TaskService taskServiceOver(MockDatabase database, MockEventPublisher events = new MockEventPublisher)
    {
        auto projects = new MockProjectRepository(database);
        return new TaskService(new MockTaskRepository(database), projects, new MockLaneRepository(database), events,
            new IndexPages(noWorkingDirs(), projects, events), new MockTransactional);
    }

    /**
     * An AgentService over mock repositories, `database`'s agents and one runtime, reporting to `events` and
     * ending chats in `chats`.
     */
    private AgentService agentServiceOver(MockDatabase database, MockEventPublisher events = new MockEventPublisher,
        MockAgentChat chats = new MockAgentChat)
    {
        return new AgentService(new MockAgentRepository(database), new MockRuntimeRepository, events, chats);
    }

    /// A task already in `database`, in the lane with id `laneId`.
    private Task storedTask(MockDatabase database, UUID laneId, string description, int position)
    {
        auto task = new Task(randomUUID, laneId, description, position);
        database.tasks ~= task;
        return task;
    }

    /// A project already in `database`, with the slug made from its name.
    private Project storedProject(MockDatabase database, string name)
    {
        auto project = new Project(randomUUID, name, slugify(name));
        database.projects ~= project;
        return project;
    }

    /// A lane already in `database`, of the project with id `projectId`.
    private Lane storedLane(MockDatabase database, UUID projectId, string name, int position)
    {
        auto lane = new Lane(randomUUID, projectId, name, position, "#000000", false);
        database.lanes ~= lane;
        return lane;
    }
}

// save, for a project on its own.
unittest
{
    auto database = new MockDatabase;
    auto service = serviceOver(database);

    auto created = service.save(new Project("Q3 finance", null));
    assert(created.isSuccessful);
    assert(created.value.id != UUID.init);
    assert(created.value.slug == "q3-finance");
    assert(database.projects.length == 1);

    auto chosen = service.save(new Project("Website", "site"));
    assert(chosen.isSuccessful && chosen.value.slug == "site");

    created.value.description = "Numbers.";
    auto updated = service.save(created.value);
    assert(updated.isSuccessful);
    assert(database.projects[0].description == "Numbers.");

    auto missing = service.save(new Project(randomUUID, "Gone", "gone"));
    assert(cast(ProjectNotFoundError) missing.error);
}

// save, for the slug checks.
unittest
{
    auto database = new MockDatabase;
    auto service = serviceOver(database);
    auto finance = storedProject(database, "Q3 finance");

    assert(cast(SlugInvalidError) service.save(new Project("Bad", "Not A Slug")).error);
    assert(cast(SlugReservedError) service.save(new Project("Anything", "new")).error);
    assert(cast(NameReservedError) service.save(new Project("New", null)).error);
    assert(cast(SlugTakenError) service.save(new Project("Other", "q3-finance")).error);

    auto taken = cast(NameTakenError) service.save(new Project("Q3 Finance!", null)).error;
    assert(taken !is null);
    assert(taken.ownerName == "Q3 finance");

    // A project keeps its own slug on an update.
    assert(service.save(new Project(finance.id, "Q3 finance", "q3-finance")).isSuccessful);

    // A failed check writes nothing.
    assert(database.projects.length == 1);
}

// get, getAll and remove.
unittest
{
    auto database = new MockDatabase;
    auto service = serviceOver(database);
    auto finance = storedProject(database, "Q3 finance");
    storedProject(database, "Website");

    assert(service.get(finance.id).value is finance);
    assert(cast(ProjectNotFoundError) service.get(randomUUID).error);

    assert(service.getAll().length == 2);

    assert(service.remove(finance.id).isSuccessful);
    assert(service.getAll().length == 1);
    assert(cast(ProjectNotFoundError) service.remove(finance.id).error);
}

// save, for a project with its lanes.
unittest
{
    import std.algorithm : all;

    auto database = new MockDatabase;
    auto service = serviceOver(database);

    auto created = service.save(new ProjectWithLanes(new Project("Q3 finance", null), [
        new Lane(UUID.init, UUID.init, "To do", 0, "#000000", false),
        new Lane(UUID.init, UUID.init, "Done", 1, "#000000", true)
    ]));
    assert(created.isSuccessful);
    auto project = created.value.project;
    assert(project.id != UUID.init && project.slug == "q3-finance");
    assert(database.lanes.length == 2);
    assert(database.lanes.map!(lane => lane.projectId).all!(id => id == project.id));

    auto toDo = database.lanes[0];
    auto done = database.lanes[1];
    toDo.name = "Backlog";
    auto updated = service.save(new ProjectWithLanes(project, [
        toDo,
        new Lane(UUID.init, UUID.init, "Doing", 1, "#000000", false)
    ]));
    assert(updated.isSuccessful);
    assert(database.removedLanes == [done.id]);
    assert(database.lanes.map!(lane => lane.name).array == ["Backlog", "Doing"]);

    auto missing = service.save(new ProjectWithLanes(new Project(randomUUID, "Gone", "gone"), []));
    assert(cast(ProjectNotFoundError) missing.error);

    auto renamed = new Project(project.id, "New", null);
    assert(cast(NameReservedError) service.save(new ProjectWithLanes(renamed, [])).error);
}

// The events reported for the writes, and for nothing else.
unittest
{
    auto database = new MockDatabase;
    auto events = new MockEventPublisher;
    auto service = serviceOver(database, events);

    auto created = service.save(new Project("Q3 finance", null)).value;
    service.save(created);
    service.save(new Project("Q3 finance", null));
    service.save(new Project(randomUUID, "Gone", "gone"));
    service.remove(created.id);
    service.remove(created.id);
    assert(events.projects == [
        Published(Event.created, created.id),
        Published(Event.changed, created.id),
        Published(Event.deleted, created.id)
    ]);

    events.projects = null;
    auto withLanes = service.save(new ProjectWithLanes(new Project("Website", null), [])).value.project;
    service.save(new ProjectWithLanes(withLanes, []));
    service.save(new ProjectWithLanes(new Project(randomUUID, "Gone", "gone"), []));
    assert(events.projects == [
        Published(Event.created, withLanes.id),
        Published(Event.changed, withLanes.id)
    ]);
}

// save, for the lane checks on a project with its lanes.
unittest
{
    auto database = new MockDatabase;
    auto service = serviceOver(database);
    auto finance = storedProject(database, "Q3 finance");
    auto website = storedProject(database, "Website");
    auto toDo = storedLane(database, finance.id, "To do", 0);
    auto elsewhere = storedLane(database, website.id, "Ideas", 0);

    auto save(Lane[] lanes)
    {
        return service.save(new ProjectWithLanes(new Project(finance.id, "Q3 finance", "q3-finance"), lanes));
    }

    assert(cast(LaneOfOtherProjectError) save([toDo, elsewhere]).error);
    assert(cast(LaneNotFoundError) save([new Lane(randomUUID, finance.id, "Lost", 1, "#000000", false)]).error);
    assert(cast(LaneListedTwiceError) save([toDo, toDo]).error);

    // A failed check writes nothing.
    assert(database.removedLanes.length == 0);
    assert(database.lanes.length == 2);
}

// LaneService: reading, and creating, updating and deleting a lane.
unittest
{
    auto database = new MockDatabase;
    auto events = new MockEventPublisher;
    auto service = laneServiceOver(database, events);
    auto finance = storedProject(database, "Q3 finance");
    auto toDo = storedLane(database, finance.id, "To do", 0);

    assert(service.getOfProject(finance.id).value == [toDo]);
    assert(cast(ProjectNotFoundError) service.getOfProject(randomUUID).error);
    assert(service.get(toDo.id).value is toDo);
    assert(cast(LaneNotFoundError) service.get(randomUUID).error);

    auto done = new Lane;
    done.projectId = finance.id;
    done.name = "Done";
    done.color = "#000000";
    auto created = service.save(done);
    assert(created.isSuccessful);
    assert(created.value.id != UUID.init && created.value.position.get == 1);

    auto taken = new Lane(UUID.init, finance.id, "Doing", 0, "#000000", false);
    assert(cast(LanePositionTakenError) service.save(taken).error);
    auto lost = new Lane(UUID.init, randomUUID, "Lost", 0, "#000000", false);
    assert(cast(ProjectNotFoundError) service.save(lost).error);

    // An update keeps the lane in its project, and may keep its own position.
    auto renamed = new Lane(toDo.id, randomUUID, "Backlog", 0, "#000000", false);
    assert(service.save(renamed).isSuccessful);
    assert(renamed.projectId == finance.id);
    auto gone = new Lane(randomUUID, finance.id, "Gone", 5, "#000000", false);
    assert(cast(LaneNotFoundError) service.save(gone).error);

    assert(service.remove(done.id).isSuccessful);
    assert(cast(LaneNotFoundError) service.remove(done.id).error);

    assert(events.lanes == [
        Published(Event.created, done.id),
        Published(Event.changed, toDo.id),
        Published(Event.deleted, done.id)
    ]);
}

// TaskService: reading, and creating, updating and deleting a task.
unittest
{
    auto database = new MockDatabase;
    auto events = new MockEventPublisher;
    auto service = taskServiceOver(database, events);
    auto finance = storedProject(database, "Q3 finance");
    auto website = storedProject(database, "Website");
    auto toDo = storedLane(database, finance.id, "To do", 0);
    auto done = storedLane(database, finance.id, "Done", 1);
    auto ideas = storedLane(database, website.id, "Ideas", 0);
    auto report = storedTask(database, toDo.id, "Write the report", 0);

    assert(service.getOfProject(finance.id).value == [report]);
    assert(cast(ProjectNotFoundError) service.getOfProject(randomUUID).error);
    assert(service.getOfLane(toDo.id).value == [report]);
    assert(cast(LaneNotFoundError) service.getOfLane(randomUUID).error);
    assert(service.get(report.id).value is report);
    assert(cast(TaskNotFoundError) service.get(randomUUID).error);
    assert(service.getNotes(report.id).isSuccessful);
    assert(cast(TaskNotFoundError) service.getNotes(randomUUID).error);

    auto check = new Task;
    check.laneId = toDo.id;
    check.description = "Check the numbers";
    auto created = service.save(check);
    assert(created.isSuccessful);
    assert(check.id != UUID.init && check.position.get == 1);

    assert(cast(LaneNotFoundError) service.save(new Task(UUID.init, randomUUID, "Lost", 0)).error);
    assert(cast(LaneClosedToNewTasksError) service.save(new Task(UUID.init, done.id, "Late", 0)).error);
    assert(cast(TaskPositionTakenError) service.save(new Task(UUID.init, toDo.id, "Clash", 0)).error);

    // An update may move the task within its project, and keeps its lane when it names none.
    auto moved = new Task(report.id, done.id, "Write the report", 0);
    assert(service.save(moved).isSuccessful);
    auto kept = new Task(report.id, UUID.init, "Write the full report", 0);
    assert(service.save(kept).isSuccessful && kept.laneId == done.id);
    assert(cast(TaskLeavesProjectError) service.save(new Task(report.id, ideas.id, "Away", 0)).error);
    assert(cast(LaneNotFoundError) service.save(new Task(report.id, randomUUID, "Lost", 0)).error);
    assert(cast(TaskNotFoundError) service.save(new Task(randomUUID, toDo.id, "Gone", 5)).error);

    assert(service.remove(check.id).isSuccessful);
    assert(cast(TaskNotFoundError) service.remove(check.id).error);

    // Only a task of a project managed by AI is to be scheduled; any other gets no status.
    assert(database.agentStatuses[check.id].isNull);
    website.managedByAi = true;
    auto draft = new Task(UUID.init, ideas.id, "Draft the copy", 0);
    assert(service.save(draft).isSuccessful);
    assert(database.agentStatuses[draft.id] == AgentStatus.toBeScheduled);

    assert(events.tasks == [
        Published(Event.created, check.id),
        Published(Event.changed, report.id),
        Published(Event.changed, report.id),
        Published(Event.deleted, check.id),
        Published(Event.created, draft.id)
    ]);

}

// TaskService: handing a task back to the task scheduler.
unittest
{
    auto database = new MockDatabase;
    auto events = new MockEventPublisher;
    auto service = taskServiceOver(database, events);
    auto managed = storedProject(database, "AI test");
    managed.managedByAi = true;
    auto unmanaged = storedProject(database, "Q3 finance");
    auto toDo = storedLane(database, managed.id, "To do", 0);
    auto done = new Lane(randomUUID, managed.id, "Done", 1, "#5fd6ab", true);
    database.lanes ~= done;
    auto declined = storedTask(database, toDo.id, "Write the poem", 0);
    database.agentStatuses[declined.id] = AgentStatus.declined.nullable;

    assert(service.reschedule(declined.id).isSuccessful);
    assert(database.agentStatuses[declined.id] == AgentStatus.toBeScheduled);
    assert(events.notes == [declined.id]);

    // A task the scheduler is at, a done one, and one of a project the agents do not work on stay as they are.
    database.agentStatuses[declined.id] = AgentStatus.scheduling.nullable;
    assert(cast(TaskBeingScheduledError) service.reschedule(declined.id).error);
    database.agentStatuses[declined.id] = AgentStatus.executing.nullable;
    assert(cast(TaskBeingWorkedOnError) service.reschedule(declined.id).error);
    assert(cast(TaskDoneError) service.reschedule(storedTask(database, done.id, "Read the poem", 0).id).error);
    auto ideas = storedLane(database, unmanaged.id, "Ideas", 0);
    assert(cast(ProjectNotManagedByAiError) service.reschedule(storedTask(database, ideas.id, "Sum it", 0).id).error);
    assert(cast(TaskNotFoundError) service.reschedule(randomUUID).error);
    assert(events.notes == [declined.id]);
}

// TaskService: clearing a lane deletes its tasks and no others.
unittest
{
    auto database = new MockDatabase;
    auto events = new MockEventPublisher;
    auto service = taskServiceOver(database, events);
    auto finance = storedProject(database, "Q3 finance");
    auto toDo = storedLane(database, finance.id, "To do", 0);
    auto done = storedLane(database, finance.id, "Done", 1);
    auto report = storedTask(database, toDo.id, "Write the report", 0);
    storedTask(database, done.id, "Send the invoice", 0);
    storedTask(database, done.id, "Pay the rent", 1);

    assert(service.clear(done.id).isSuccessful);
    assert(database.tasks == [report]);
    assert(service.clear(done.id).isSuccessful);
    assert(cast(LaneNotFoundError) service.clear(randomUUID).error);

    assert(events.lanes == [Published(Event.cleared, done.id), Published(Event.cleared, done.id)]);
    assert(events.tasks.length == 0);
}

// TaskService: moving a task the agents are done with to another lane hands it back to the task scheduler.
unittest
{
    auto database = new MockDatabase;
    auto events = new MockEventPublisher;
    auto service = taskServiceOver(database, events);
    auto managed = storedProject(database, "AI test");
    managed.managedByAi = true;
    auto toDo = storedLane(database, managed.id, "To do", 0);
    auto doing = storedLane(database, managed.id, "Doing", 1);
    auto done = new Lane(randomUUID, managed.id, "Done", 2, "#5fd6ab", true);
    database.lanes ~= done;
    auto poem = storedTask(database, toDo.id, "Write the poem", 0);
    auto essay = storedTask(database, toDo.id, "Write the essay", 1);
    database.agentStatuses[poem.id] = AgentStatus.declined.nullable;
    database.agentStatuses[essay.id] = AgentStatus.scheduled.nullable;

    // A move within the lane, or of a task that is not in a terminal status, changes nothing.
    assert(service.move(poem.id, toDo.id, Nullable!UUID.init).isSuccessful);
    assert(service.move(essay.id, doing.id, Nullable!UUID.init).isSuccessful);
    assert(database.agentStatuses[poem.id] == AgentStatus.declined);
    assert(database.agentStatuses[essay.id] == AgentStatus.scheduled);

    // Nor does a move to a done lane.
    assert(service.move(poem.id, done.id, Nullable!UUID.init).isSuccessful);
    assert(database.agentStatuses[poem.id] == AgentStatus.declined);
    assert(events.notes.length == 0);

    // Moving it out again does, and so does a PUT that changes its lane.
    assert(service.move(poem.id, doing.id, Nullable!UUID.init).isSuccessful);
    assert(database.agentStatuses[poem.id] == AgentStatus.toBeScheduled);
    database.agentStatuses[poem.id] = AgentStatus.declined.nullable;
    assert(service.save(new Task(poem.id, toDo.id, "Write the poem", 5)).isSuccessful);
    assert(database.agentStatuses[poem.id] == AgentStatus.toBeScheduled);
    assert(events.notes == [poem.id, poem.id]);

    // A task of a project not managed by AI has no status, and keeps none.
    auto unmanaged = storedProject(database, "Q3 finance");
    auto ideas = storedLane(database, unmanaged.id, "Ideas", 0);
    auto later = storedLane(database, unmanaged.id, "Later", 1);
    auto sum = storedTask(database, ideas.id, "Sum it", 0);
    assert(service.move(sum.id, later.id, Nullable!UUID.init).isSuccessful);
    assert(sum.id !in database.agentStatuses);
}

// AgentService: reading, and creating, updating, enabling and deleting an agent.
unittest
{
    auto database = new MockDatabase;
    auto events = new MockEventPublisher;
    auto chats = new MockAgentChat;
    auto service = agentServiceOver(database, events, chats);

    auto writer = new Agent(UUID.init, "Writer", "claude-code", "sonnet", "default", false);
    auto created = service.save(writer);
    assert(created.isSuccessful && writer.id != UUID.init);
    assert(service.getAll() == [writer]);
    assert(service.get(writer.id).value is writer);
    assert(cast(AgentNotFoundError) service.get(randomUUID).error);

    assert(cast(RuntimeNotFoundError) service.save(new Agent(UUID.init, "A", "other", "sonnet", "default", false))
            .error);
    auto notOffered = cast(ModelNotOfferedError) service.save(
        new Agent(UUID.init, "A", "claude-code", "other", "default", false)).error;
    assert(notOffered !is null && notOffered.runtimeName == "Claude Code");
    assert(cast(EffortNotTakenError) service.save(new Agent(UUID.init, "A", "claude-code", "sonnet", "max", false))
            .error);
    assert(cast(AgentNameTakenError) service.save(
        new Agent(UUID.init, "Writer", "claude-code", "sonnet", "default", false)).error);

    // An agent keeps its own name on an update.
    assert(service.save(new Agent(writer.id, "Writer", "claude-code", "sonnet", "default", true)).isSuccessful);
    assert(cast(AgentNotFoundError) service.save(
        new Agent(randomUUID, "Gone", "claude-code", "sonnet", "default", false)).error);

    assert(service.setEnabled(writer.id, false).isSuccessful && !service.get(writer.id).value.enabled);
    // Only setEnabled enables an agent: a save keeps what it was.
    auto saved = new Agent(writer.id, "Writer", "claude-code", "sonnet", "default", true);
    assert(service.save(saved).isSuccessful && !saved.enabled && !service.get(writer.id).value.enabled);
    assert(service.setEnabled(writer.id, true).isSuccessful && service.get(writer.id).value.enabled);
    assert(cast(AgentNotFoundError) service.setEnabled(randomUUID, false).error);

    assert(service.remove(writer.id).isSuccessful);
    assert(cast(AgentNotFoundError) service.remove(writer.id).error);
    assert(chats.endedAgents == [writer.id]);

    assert(events.agents == [
        Published(Event.created, writer.id),
        Published(Event.changed, writer.id),
        Published(Event.changed, writer.id),
        Published(Event.changed, writer.id),
        Published(Event.changed, writer.id),
        Published(Event.deleted, writer.id)
    ]);
}

// AgentService: enabling or disabling every agent at once.
unittest
{
    auto database = new MockDatabase;
    auto events = new MockEventPublisher;
    auto service = agentServiceOver(database, events);

    auto writer = new Agent(UUID.init, "Writer", "claude-code", "sonnet", "default", false);
    auto reviewer = new Agent(UUID.init, "Reviewer", "claude-code", "sonnet", "default", false);
    assert(service.save(writer).isSuccessful && service.save(reviewer).isSuccessful);
    assert(service.setEnabled(reviewer.id, false).isSuccessful);
    events.agents = null;

    // Only the agents that change are changed, and reported.
    assert(service.setAllEnabled(false) == [writer.id] && !writer.enabled && !reviewer.enabled);
    assert(events.agents == [Published(Event.changed, writer.id)]);
    assert(service.setAllEnabled(false).length == 0);
    assert(service.setAllEnabled(true) == [writer.id, reviewer.id] && writer.enabled && reviewer.enabled);
}

// The field checks every save makes before it writes.
unittest
{
    auto database = new MockDatabase;
    auto projects = serviceOver(database);
    auto lanes = laneServiceOver(database);
    auto tasks = taskServiceOver(database);
    auto agents = agentServiceOver(database);
    auto finance = storedProject(database, "Q3 finance");
    auto toDo = storedLane(database, finance.id, "To do", 0);

    assert(cast(ProjectNameMissingError) projects.save(new Project(" ", null)).error);
    assert(cast(ProjectNameUnusableError) projects.save(new Project("!!!", null)).error);
    auto badLane = new Lane(UUID.init, UUID.init, "Doing", 0, "red", false);
    assert(cast(LaneColorInvalidError) projects.save(new ProjectWithLanes(new Project("Website", null), [badLane]))
            .error);

    assert(cast(LaneNameMissingError) lanes.save(new Lane(UUID.init, finance.id, "", 1, "#000000", false)).error);
    assert(cast(LanePositionNegativeError) lanes.save(new Lane(UUID.init, finance.id, "A", -1, "#000000", false))
            .error);
    assert(cast(LaneColorInvalidError) lanes.save(new Lane(UUID.init, finance.id, "A", 1, "#00000g", false)).error);
    auto shouted = new Lane(UUID.init, finance.id, "Done", 1, "#8FA6FF", false);
    assert(lanes.save(shouted).isSuccessful && shouted.color == "#8fa6ff");

    assert(cast(TaskDescriptionMissingError) tasks.save(new Task(UUID.init, toDo.id, " ", 0)).error);
    assert(cast(TaskPositionNegativeError) tasks.save(new Task(UUID.init, toDo.id, "A", -1)).error);

    Agent draft(string name, string runtime, string model, string[] labels = null)
    {
        return new Agent(UUID.init, name, runtime, model, "default", false, null, labels);
    }

    assert(cast(AgentNameMissingError) agents.save(draft("", "claude-code", "sonnet")).error);
    assert(cast(AgentRuntimeMissingError) agents.save(draft("A", " ", "sonnet")).error);
    assert(cast(AgentModelMissingError) agents.save(draft("A", "claude-code", "")).error);
    auto idle = draft("A", "claude-code", "sonnet");
    idle.maxParallelTasks = 0;
    assert(cast(MaxParallelTasksInvalidError) agents.save(idle).error);
    assert(cast(LabelBlankError) agents.save(draft("A", "claude-code", "sonnet", ["ops", " "])).error);
    auto repeated = cast(LabelRepeatedError) agents.save(draft("A", "claude-code", "sonnet", ["Ops", "ops"])).error;
    assert(repeated !is null && repeated.label == "ops");

    // A failed check writes nothing.
    assert(database.projects.length == 1 && database.lanes.length == 2 && database.tasks.length == 0
        && database.agents.length == 0);
}

// TaskService: moving a task.
unittest
{
    import std.algorithm : sort;

    auto database = new MockDatabase;
    auto events = new MockEventPublisher;
    auto service = taskServiceOver(database, events);
    auto finance = storedProject(database, "Q3 finance");
    auto website = storedProject(database, "Website");
    auto toDo = storedLane(database, finance.id, "To do", 0);
    auto done = storedLane(database, finance.id, "Done", 1);
    auto ideas = storedLane(database, website.id, "Ideas", 0);
    auto report = storedTask(database, toDo.id, "Write the report", 0);
    auto check = storedTask(database, toDo.id, "Check the numbers", 1);
    auto copy = storedTask(database, ideas.id, "Write the copy", 0);

    UUID[] order(Task[] tasks)
    {
        return tasks.sort!((a, b) => a.position.get < b.position.get).map!(task => task.id).array;
    }

    auto bottom = service.move(report.id, done.id, Nullable!UUID.init);
    assert(bottom.isSuccessful && order(bottom.value) == [report.id]);
    auto above = service.move(check.id, done.id, report.id.nullable);
    assert(above.isSuccessful && order(above.value) == [check.id, report.id]);

    assert(cast(TaskNotFoundError) service.move(randomUUID, done.id, Nullable!UUID.init).error);
    assert(cast(LaneNotFoundError) service.move(report.id, randomUUID, Nullable!UUID.init).error);
    assert(cast(TaskLeavesProjectError) service.move(report.id, ideas.id, Nullable!UUID.init).error);
    assert(cast(TaskBeforeItselfError) service.move(report.id, done.id, report.id.nullable).error);
    assert(cast(BeforeTaskNotFoundError) service.move(report.id, done.id, randomUUID.nullable).error);
    assert(cast(BeforeTaskNotFoundError) service.move(report.id, done.id, UUID.init.nullable).error);
    assert(cast(BeforeTaskNotInLaneError) service.move(report.id, done.id, copy.id.nullable).error);

    assert(events.tasks == [Published(Event.moved, report.id), Published(Event.moved, check.id)]);
}

// ProjectService: pausing and resuming a project's AI agents.
unittest
{
    auto database = new MockDatabase;
    auto events = new MockEventPublisher;
    auto service = serviceOver(database, events);
    auto managed = storedProject(database, "Q3 finance");
    managed.managedByAi = true;
    auto unmanaged = storedProject(database, "Website");

    assert(service.setAiPaused(managed.id, true).isSuccessful && managed.aiPaused);
    assert(service.setAiPaused(managed.id, false).isSuccessful && !managed.aiPaused);
    assert(service.setAiPaused(unmanaged.id, true).isSuccessful);
    assert(cast(ProjectNotManagedByAiError) service.setAiPaused(unmanaged.id, false).error);
    assert(cast(ProjectNotFoundError) service.setAiPaused(randomUUID, true).error);

    assert(events.projects == [
        Published(Event.changed, managed.id),
        Published(Event.changed, managed.id),
        Published(Event.changed, unmanaged.id)
    ]);
}

// A slug or an agent name another write took after the check is answered as the check would have.
unittest
{
    import std.exception : assertThrown;

    /// A project repository whose add finds the slug taken by a rival added after the check.
    ProjectService racedOver(MockDatabase database, MockEventPublisher events)
    {
        auto repository = new class(database) MockProjectRepository
        {
            this(MockDatabase database)
            {
                super(database);
            }

            override Project add(Project project)
            {
                database.projects ~= new Project(randomUUID, "Q3 finance", project.slug);
                throw new UniqueViolation("projects_slug_key", "Taken.");
            }
        };

        return new ProjectService(repository, new MockLaneRepository(database), events, noWorkingDirs(),
            new MockTransactional);
    }

    auto events = new MockEventPublisher;
    assert(cast(SlugTakenError) racedOver(new MockDatabase, events).save(new Project("Other", "q3-finance")).error);
    auto taken = cast(NameTakenError) racedOver(new MockDatabase, events).save(new Project("Q3 Finance!", null)).error;
    assert(taken !is null && taken.ownerName == "Q3 finance");
    assert(events.projects.length == 0);

    auto database = new MockDatabase;
    string constraint = "agents_name_key";
    auto agents = new class(database) MockAgentRepository
    {
        this(MockDatabase database)
        {
            super(database);
        }

        override Agent add(Agent agent)
        {
            throw new UniqueViolation(constraint, "Taken.");
        }
    };
    auto service = new AgentService(agents, new MockRuntimeRepository, events, new MockAgentChat);
    auto writer = new Agent(UUID.init, "Writer", "claude-code", "sonnet", "default", false);
    assert(cast(AgentNameTakenError) service.save(writer).error);
    constraint = "some_other_key";
    assertThrown!UniqueViolation(service.save(writer));
    assert(events.agents.length == 0);
}
