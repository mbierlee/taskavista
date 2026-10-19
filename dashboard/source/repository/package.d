module repository;

import std.typecons : Nullable;
import std.uuid : UUID;

import model : Agent, AgentLogEntry, AgentStatus, Default, Lane, Model, Project, Runtime, Task, TaskNote;

/// Reads and writes rows of the projects table.
interface IProjectRepository
{
    /**
     * Gets every project.
     *
     * Returns: Every project, by name.
     */
    Project[] all();

    /**
     * Finds a project.
     *
     * Params:
     *   id = The project's id.
     *
     * Returns: The project with this id, or an empty Nullable when there is none.
     */
    Nullable!Project find(UUID id);

    /**
     * Finds the project that already has a slug.
     *
     * Params:
     *   slug = The slug to look for.
     *   except = The id of the project not to count, or UUID.init to check against every
     *     project.
     *
     * Returns: The name of the project other than `except` that has this slug, or an empty
     *   Nullable when none has.
     */
    Nullable!string slugOwner(string slug, UUID except);

    /**
     * Inserts a project.
     *
     * Fills in the id the database assigned it, and whether its AI agents are paused, which
     * they are unless it is managed by AI.
     *
     * Params:
     *   project = The project to insert.
     *
     * Returns: The same instance, so it can be used as an expression.
     */
    Project add(Project project);

    /**
     * Writes a project back over the row with its id.
     *
     * Fills in whether its AI agents are paused now (see pausedOnceManaged); the aiPaused it
     * carries is not written.
     *
     * Params:
     *   project = The project to write.
     *
     * Returns: False when no row has that id, in which case nothing was written.
     */
    bool update(Project project);

    /**
     * Pauses or resumes a project's AI agents.
     *
     * Params:
     *   id = The project's id.
     *   paused = Whether its AI agents are to be paused.
     *
     * Returns: False when no row has that id, in which case nothing was written.
     */
    bool setAiPaused(UUID id, bool paused);

    /**
     * Inserts a project and its lanes in one transaction.
     *
     * The lanes go in at the positions they carry. Fills in the ids the database assigned them
     * and, as add does, whether the project's AI agents are paused.
     *
     * Params:
     *   project = The project to insert.
     *   lanes = Its lanes.
     */
    void addWithLanes(Project project, Lane[] lanes);

    /**
     * Writes a project back over its row and gives it exactly these lanes, in one transaction.
     *
     * The lanes in `removed` are deleted, tasks and all, the rest are written at the positions
     * they carry, and a lane with no id yet is inserted and given the one the database
     * assigned. The position constraint is deferred to the commit, since lanes trading places
     * briefly share one. Whether the project's AI agents are paused is written and filled in as
     * update does it.
     *
     * Params:
     *   project = The project to write.
     *   lanes = The lanes it keeps or gains.
     *   removed = The ids of the lanes it loses.
     */
    void replaceWithLanes(Project project, Lane[] lanes, UUID[] removed);

    /**
     * Deletes a project.
     *
     * Params:
     *   id = The project's id.
     *
     * Returns: False when no row had it.
     */
    bool remove(UUID id);
}

/// Reads and writes rows of the lanes table.
interface ILaneRepository
{
    /**
     * Gets a project's lanes.
     *
     * Params:
     *   projectId = The project's id.
     *
     * Returns: Every lane of the project, in board order.
     */
    Lane[] ofProject(UUID projectId);

    /**
     * Finds a lane.
     *
     * Params:
     *   id = The lane's id.
     *
     * Returns: The lane with this id, or an empty Nullable when there is none.
     */
    Nullable!Lane find(UUID id);

    /**
     * Checks whether a project exists.
     *
     * Params:
     *   projectId = The project's id.
     *
     * Returns: Whether a project has this id.
     */
    bool projectExists(UUID projectId);

    /**
     * Gets the position just after a project's last lane.
     *
     * Params:
     *   projectId = The project's id.
     *   except = The id of the lane not to count, or UUID.init to count every lane of the
     *     project.
     *
     * Returns: The position just after the last lane other than `except`; 0 when there are no
     *   others.
     */
    int nextPosition(UUID projectId, UUID except);

    /**
     * Checks whether a lane of a project already sits at a position.
     *
     * Params:
     *   projectId = The project's id.
     *   position = The position to check.
     *   except = The id of the lane not to count, or UUID.init to check against every lane of
     *     the project.
     *
     * Returns: Whether a lane other than `except` sits at this position.
     */
    bool positionTaken(UUID projectId, int position, UUID except);

    /**
     * Inserts a lane.
     *
     * Fills in the id the database assigned it.
     *
     * Params:
     *   lane = The lane to insert.
     *
     * Returns: The same instance, so it can be used as an expression.
     */
    Lane add(Lane lane);

    /**
     * Writes a lane back over the row with its id, leaving its project as it is.
     *
     * Params:
     *   lane = The lane to write.
     *
     * Returns: False when no row has that id, in which case nothing was written.
     */
    bool update(Lane lane);

    /**
     * Deletes a lane.
     *
     * Params:
     *   id = The lane's id.
     *
     * Returns: False when no row had it.
     */
    bool remove(UUID id);
}

/// Reads and writes rows of the tasks table.
interface ITaskRepository
{
    /**
     * Gets a lane's tasks.
     *
     * Params:
     *   laneId = The lane's id.
     *
     * Returns: Every task of the lane, in lane order.
     */
    Task[] ofLane(UUID laneId);

    /**
     * Gets a project's tasks.
     *
     * Params:
     *   projectId = The project's id.
     *
     * Returns: Every task of the project, lane by lane in board order, and in lane order within
     *   each lane.
     */
    Task[] ofProject(UUID projectId);

    /**
     * Finds a task.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: The task with this id, or an empty Nullable when there is none.
     */
    Nullable!Task find(UUID id);

    /**
     * Gets the tasks waiting for the task scheduler: those of the projects managed by AI that
     * are not paused, which are to be scheduled, assigned to no agent and not in a done
     * lane.
     *
     * Returns: The tasks, the oldest first.
     */
    Task[] awaitingScheduling();

    /**
     * Gets the tasks waiting for the agents they are assigned to: those of the projects managed
     * by AI that are not paused, which are scheduled and not in a done lane.
     *
     * Returns: The tasks, the oldest first.
     */
    Task[] awaitingExecution();

    /**
     * Changes how far the agents got with a task, but only from the status it is expected to
     * have, so that of two writers that both read that status, one wins and the other learns
     * it lost.
     *
     * Params:
     *   id = The task's id.
     *   from = The status the task is expected to have.
     *   to = The status it gets.
     *
     * Returns: False, with nothing changed, when no row has that id or the task's status is not
     *   `from`.
     */
    bool changeAgentStatus(UUID id, AgentStatus from, AgentStatus to);

    /**
     * Changes the agent status of every task with one status to another.
     *
     * Params:
     *   from = The status of the tasks to change.
     *   to = The status they get.
     *
     * Returns: How many tasks were changed.
     */
    ulong changeAgentStatuses(AgentStatus from, AgentStatus to);

    /**
     * Gets a task's notes.
     *
     * Params:
     *   taskId = The task's id.
     *
     * Returns: The task's notes, newest first. Empty both for a task with none and for no task
     *   at all.
     */
    TaskNote[] notes(UUID taskId);

    /**
     * Checks whether a project exists.
     *
     * Params:
     *   projectId = The project's id.
     *
     * Returns: Whether a project has this id.
     */
    bool projectExists(UUID projectId);

    /**
     * Finds the project a lane belongs to.
     *
     * Params:
     *   laneId = The lane's id.
     *
     * Returns: The project's id, or an empty Nullable when no lane has that id.
     */
    Nullable!UUID projectOfLane(UUID laneId);

    /**
     * Checks whether a lane's project lets a new task be added to it.
     *
     * Any lane does when the project's rule is any_lane, otherwise only its first lane does.
     *
     * Params:
     *   laneId = The lane's id.
     *
     * Returns: Whether a new task may be added to the lane. False when no lane has that id.
     */
    bool acceptsNewTasks(UUID laneId);

    /**
     * Inserts a task, with its creation in its notes.
     *
     * Fills in the id the database assigned it, and its position when it carries none.
     *
     * Params:
     *   task = The task to insert.
     *   agentStatus = How far the agents got with it, or null when they are not to work on it.
     *
     * Returns: The same instance, so it can be used as an expression.
     *
     * Throws: `PositionConflict` when another task of the lane is at its position.
     */
    Task add(Task task, Nullable!AgentStatus agentStatus);

    /**
     * Writes a task back over the row with its id, lane included.
     *
     * Adds a change of lane or description to its notes. A task carrying no position goes to
     * the bottom of its lane, and is given that position.
     *
     * Params:
     *   task = The task to write.
     *
     * Returns: False when no row has that id, in which case nothing was written.
     *
     * Throws: `PositionConflict` when another task of the lane is at its position.
     */
    bool update(Task task);

    /**
     * Moves a task, and adds a change of lane to its notes.
     *
     * The position constraint is deferred to the commit, since the shift can briefly give two
     * tasks the same position.
     *
     * Params:
     *   id = The task's id.
     *   laneId = The lane it moves to.
     *   before = The task it goes just above, or UUID.init for the bottom of the lane.
     *
     * Throws: `PositionConflict` when `before` is no longer in the lane.
     */
    void move(UUID id, UUID laneId, UUID before);

    /**
     * Finds the AI agent a task is assigned to.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: The agent's id, or an empty Nullable when the task is assigned to none or there
     *   is no such task.
     */
    Nullable!UUID assignedAiAgent(UUID id);

    /**
     * Assigns a task to an AI agent.
     *
     * Adds the assignment to its notes when it puts the task with another agent.
     *
     * Params:
     *   id = The task's id.
     *   agentId = The agent's id, or null to assign the task to none.
     *
     * Returns: False when no row has that id.
     */
    bool assignAiAgent(UUID id, Nullable!UUID agentId);

    /**
     * Adds to a task's notes that its scheduler failed to assign it to an agent.
     *
     * Params:
     *   id = The task's id.
     *   schedulerId = The scheduler's id.
     *
     * Returns: False, with nothing added, when the task or the scheduler is gone.
     */
    bool recordSchedulingFailure(UUID id, UUID schedulerId);

    /**
     * Adds to a task's notes that its scheduler found no agent for its next step.
     *
     * Params:
     *   id = The task's id.
     *   schedulerId = The scheduler's id.
     *
     * Returns: False, with nothing added, when the task or the scheduler is gone.
     */
    bool recordNoAgentFound(UUID id, UUID schedulerId);

    /**
     * Adds to a task's notes that the agent it is assigned to failed to work on it.
     *
     * Params:
     *   id = The task's id.
     *   agentId = The agent's id.
     *
     * Returns: False, with nothing added, when the task or the agent is gone.
     */
    bool recordExecutionFailure(UUID id, UUID agentId);

    /**
     * Adds a note of any text to a task.
     *
     * Params:
     *   id = The task's id.
     *   note = The note's text.
     *
     * Returns: False, with nothing added, when the task is gone.
     */
    bool addNote(UUID id, string note);

    /**
     * Finds how far the agents got with a task.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: The task's agent status, or an empty Nullable when it has none or there is no
     *   such task.
     */
    Nullable!AgentStatus agentStatus(UUID id);

    /**
     * Hands a task back to the task scheduler: takes it off its agent and marks it to be scheduled
     * again, and adds that to its notes. A task being scheduled or worked on is left alone,
     * since the scheduler or its agent is at it.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: False, with nothing changed, when no row has that id or the task is being
     *   scheduled or worked on.
     */
    bool reschedule(UUID id);

    /**
     * Adds to a task's notes that there was no task scheduler agent to assign it.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: False, with nothing added, when the task is gone.
     */
    bool recordNoScheduler(UUID id);

    /**
     * Deletes a task.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: False when no row had it.
     */
    bool remove(UUID id);
}

/**
 * Thrown by a task write whose place in its lane clashes with the lane as it stands once
 * locked.
 *
 * A check made before the write cannot rule this out.
 */
class PositionConflict : Exception
{
    this(string message) @safe pure nothrow
    {
        super(message);
    }
}

/**
 * Reads the runtimes and models tables.
 *
 * They hold fixed data: they are written only by the schema, never through the application.
 */
interface IRuntimeRepository
{
    /**
     * Gets every runtime.
     *
     * Returns: Every runtime, by name.
     */
    Runtime[] all();

    /**
     * Gets every model.
     *
     * Returns: Every model, by runtime and then by name, with the effort levels it takes.
     */
    Model[] models();

    /**
     * Finds a runtime's name.
     *
     * Params:
     *   id = The runtime's id.
     *
     * Returns: The name of the runtime with this id, or an empty Nullable when there is none.
     */
    Nullable!string name(string id);

    /**
     * Checks whether a runtime offers a model.
     *
     * Params:
     *   runtime = The runtime's id.
     *   model = The model's id.
     *
     * Returns: Whether the runtime offers the model.
     */
    bool offers(string runtime, string model);

    /**
     * Checks whether a model takes an effort level.
     *
     * Params:
     *   model = The model's id.
     *   effort = The effort level's id.
     *
     * Returns: Whether the model takes the effort level.
     */
    bool takes(string model, string effort);
}

/// Reads and writes rows of the agents table.
interface IAgentRepository
{
    /**
     * Gets every agent.
     *
     * There can be any number of task schedulers.
     *
     * Returns: Every agent, the task schedulers first, since they direct the others, and by
     *   name within each group.
     */
    Agent[] all();

    /**
     * Finds an agent.
     *
     * Params:
     *   id = The agent's id.
     *
     * Returns: The agent with this id, or an empty Nullable when there is none.
     */
    Nullable!Agent find(UUID id);

    /**
     * Gets how many tasks an agent may work on at once.
     *
     * Params:
     *   id = The agent's id.
     *
     * Returns: The limit, or an empty Nullable when the agent has none, or there is no such agent.
     */
    Nullable!int maxParallelTasks(UUID id);

    /**
     * Checks whether an agent already has a name.
     *
     * Params:
     *   name = The name to look for.
     *   except = The id of the agent not to count, or UUID.init to check against every agent.
     *
     * Returns: Whether an agent other than `except` has this name.
     */
    bool nameTaken(string name, UUID except);

    /**
     * Inserts an agent and its labels in one transaction.
     *
     * Fills in the id the database assigned it.
     *
     * Params:
     *   agent = The agent to insert.
     *
     * Returns: The same instance, so it can be used as an expression.
     */
    Agent add(Agent agent);

    /**
     * Writes an agent back over the row with its id, and gives it exactly its labels, in one
     * transaction.
     *
     * Params:
     *   agent = The agent to write.
     *
     * Returns: False when no row has that id, in which case nothing was written.
     */
    bool update(Agent agent);

    /**
     * Deletes an agent.
     *
     * Params:
     *   id = The agent's id.
     *
     * Returns: False when no row has that id.
     */
    bool remove(UUID id);
}

/// Reads and writes rows of the agent_log table.
interface IAgentLogRepository
{
    /**
     * Gets an agent's log.
     *
     * Params:
     *   agentId = The agent's id.
     *
     * Returns: The agent's log, newest first. Empty both for an agent with none and for no agent
     *   at all.
     */
    AgentLogEntry[] ofAgent(UUID agentId);

    /**
     * Inserts a log entry.
     *
     * Fills in the id and time the database assigned it.
     *
     * Params:
     *   entry = The entry to insert.
     *
     * Returns: The same instance, so it can be used as an expression.
     */
    AgentLogEntry add(AgentLogEntry entry);

    /**
     * Records an agent's answer to a log entry's prompt.
     *
     * Params:
     *   id = The entry's id.
     *   result = The agent's answer.
     *
     * Returns: False when no row has that id, in which case nothing was written.
     */
    bool setResult(UUID id, string result);
}

/**
 * Reads the defaults table, a value per key.
 *
 * Written only by the schema for now: nothing in the UI changes a default yet.
 */
interface IDefaultRepository
{
    /**
     * Gets every default.
     *
     * Returns: Every default, by key.
     */
    Default[] all();
}
