module model;

import std.conv : text;
import std.datetime.systime : SysTime;
import std.traits : EnumMembers;
import std.typecons : Nullable;
import std.uuid : UUID;

/**
 * How a new task gets placed on the board, mirroring the
 * task_add_rule check constraint in sql/init.sql.
 */
enum TaskAddRule : string
{
    firstLane = "first_lane",
    anyLane = "any_lane"
}

/**
 * Converts a task_add_rule column value to its enum member. Throws on anything
 * the schema's check constraint would not have allowed in the first place.
 */
TaskAddRule toTaskAddRule(string value) @safe
{
    foreach (rule; EnumMembers!TaskAddRule)
    {
        if (rule == value)
        {
            return rule;
        }
    }

    throw new Exception(text("Not a task_add_rule the schema allows: ", value));
}

/// How far the agents got with a task: a tasks.agent_status value.
enum AgentStatus : string
{
    toBeScheduled = "to_be_scheduled",
    scheduling = "scheduling",
    scheduled = "scheduled",
    declined = "declined",
    executing = "executing",
    done = "done",
    failed = "failed"
}

/**
 * The agent statuses a task stays in until something hands it back to the task scheduler, such
 * as a person moving it to another lane: nothing is under way for it, and nothing will be.
 */
immutable AgentStatus[] terminalAgentStatuses = [AgentStatus.declined, AgentStatus.done, AgentStatus.failed];

/**
 * Converts an agent_status column value to its enum member. Throws on anything
 * the schema's check constraint would not have allowed in the first place.
 */
AgentStatus toAgentStatus(string value) @safe
{
    foreach (status; EnumMembers!AgentStatus)
    {
        if (status == value)
        {
            return status;
        }
    }

    throw new Exception(text("Not an agent_status the schema allows: ", value));
}

/// A row of the projects table.
class Project
{
    /// Assigned by the database on insert, so UUID.init until the project is stored.
    UUID id;
    string name;
    /// The project's name in its URL.
    string slug;
    /// What the project is about, and directions for its AI agents. Empty for none.
    string description;
    TaskAddRule taskAddRule = TaskAddRule.firstLane;
    /// Whether AI agents may add, edit and move the project's tasks.
    bool managedByAi;
    /**
     * Whether the project's AI agents are paused: always, for a project not managed by AI. It
     * follows managedByAi when that changes, and is otherwise written only by
     * `IProjectRepository.setAiPaused`.
     */
    bool aiPaused;

    this() @safe
    {
    }

    this(string name, string slug, string description = null,
        TaskAddRule taskAddRule = TaskAddRule.firstLane, bool managedByAi = false) @safe
    {
        this.name = name;
        this.slug = slug;
        this.description = description;
        this.taskAddRule = taskAddRule;
        this.managedByAi = managedByAi;
    }

    this(UUID id, string name, string slug, string description = null,
        TaskAddRule taskAddRule = TaskAddRule.firstLane, bool managedByAi = false,
        bool aiPaused = false) @safe
    {
        this.id = id;
        this.name = name;
        this.slug = slug;
        this.description = description;
        this.taskAddRule = taskAddRule;
        this.managedByAi = managedByAi;
        this.aiPaused = aiPaused;
    }
}

/// A row of the lanes table.
class Lane
{
    /// Assigned by the database on insert, so UUID.init until the lane is stored.
    UUID id;
    UUID projectId;
    string name;
    /**
     * Where the lane sits on its board, counted from 0. Null for a lane to be placed after the
     * project's last lane, which the service does before it is written.
     */
    Nullable!int position;
    /// A web colour, "#" and six hex digits.
    string color;
    /// Whether the tasks in this lane count as done.
    bool marksDone;

    this() @safe
    {
    }

    this(UUID id, UUID projectId, string name, int position, string color, bool marksDone) @safe
    {
        this.id = id;
        this.projectId = projectId;
        this.name = name;
        this.position = position;
        this.color = color;
        this.marksDone = marksDone;
    }
}

/// A row of the tasks table.
class Task
{
    /// Assigned by the database on insert, so UUID.init until the task is stored.
    UUID id;
    UUID laneId;
    string description;
    /**
     * Where the task sits in its lane, counted from 0. Null for a task to be placed at the
     * bottom of its lane, which the repository does as it writes it.
     */
    Nullable!int position;
    /// Assigned by the database on insert, like the id.
    SysTime createdAt;
    /// Set by the repository on every write to the task's row, but for a shift to make room.
    SysTime updatedAt;
    /// The agent the task scheduler assigned the task to, or null when it has none.
    Nullable!UUID assignedAiAgentId;
    /**
     * How far the agents got with the task, or null for one they are not to work on: one added
     * while its project was not managed by AI. Written on insert, and afterwards only through
     * the repository's agent status methods.
     */
    Nullable!AgentStatus agentStatus;

    this() @safe
    {
    }

    this(UUID id, UUID laneId, string description, int position) @safe
    {
        this.id = id;
        this.laneId = laneId;
        this.description = description;
        this.position = position;
    }

    this(UUID id, UUID laneId, string description, int position, SysTime createdAt, SysTime updatedAt,
        Nullable!UUID assignedAiAgentId, Nullable!AgentStatus agentStatus) @safe
    {
        this(id, laneId, description, position);
        this.createdAt = createdAt;
        this.updatedAt = updatedAt;
        this.assignedAiAgentId = assignedAiAgentId;
        this.agentStatus = agentStatus;
    }
}

/// A row of the task_notes table: a note on something that happened to a task.
class TaskNote
{
    UUID id;
    UUID taskId;
    SysTime insertedAt;
    /**
     * What happened, in words, with the names of the lanes and agents involved
     * as they were at the time.
     */
    string note;
    /**
     * The colour of the lane the note says the task went into, as it was at
     * the time; null for a note on anything else.
     */
    Nullable!string laneColor;

    this() @safe
    {
    }

    this(UUID id, UUID taskId, SysTime insertedAt, string note, Nullable!string laneColor) @safe
    {
        this.id = id;
        this.taskId = taskId;
        this.insertedAt = insertedAt;
        this.note = note;
        this.laneColor = laneColor;
    }
}

/**
 * A row of the runtimes table: something an agent runs in, such as Claude
 * Code. Fixed data, installed with the schema.
 */
class Runtime
{
    string id;
    string name;

    this() @safe
    {
    }

    this(string id, string name) @safe
    {
        this.id = id;
        this.name = name;
    }
}

/**
 * The id of the effort level that leaves it to the runtime to pick one for
 * the model. Every model takes it.
 */
enum defaultEffort = "default";

/// How many tasks an agent works on at once when it is not told otherwise, as in the agents table.
enum defaultMaxParallelTasks = 5;

/**
 * A row of the effort_levels table: how hard a model works at a prompt.
 * Fixed data, installed with the schema.
 */
class EffortLevel
{
    /// The name the runtime itself knows the level by.
    string id;
    string name;

    this() @safe
    {
    }

    this(string id, string name) @safe
    {
        this.id = id;
        this.name = name;
    }
}

/**
 * A row of the models table: a model an agent can use, in the runtime that
 * offers it. Fixed data, installed with the schema.
 */
class Model
{
    /// The name the runtime itself knows the model by.
    string id;
    string name;
    /// The id of the runtime that offers the model.
    string runtime;
    /**
     * The effort levels the model takes, from its rows in model_effort_levels,
     * lowest first, which starts with the default.
     */
    EffortLevel[] effortLevels;

    this() @safe
    {
    }

    this(string id, string name, string runtime, EffortLevel[] effortLevels = null) @safe
    {
        this.id = id;
        this.name = name;
        this.runtime = runtime;
        this.effortLevels = effortLevels;
    }
}

/// A row of the agents table, with its rows in agent_labels.
class Agent
{
    /// Assigned by the database on insert, so UUID.init until the agent is stored.
    UUID id;
    string name;
    /// The id of the runtime the agent runs in.
    string runtime;
    /// The id of the model the agent uses, one its runtime offers.
    string model;
    /// The id of the effort level the agent works at, one its model takes.
    string effort = defaultEffort;
    /// Whether the agent plans and assigns tasks to the other agents.
    bool taskScheduler;
    /**
     * Whether the agent can be given tasks, and, for a task scheduler, whether it schedules them.
     * Written only by `IAgentRepository.setEnabled`: an add or an update reads it back instead.
     */
    bool enabled = true;
    /// The agent's own instructions, added to its system prompt. Empty for none.
    string instructions;
    /**
     * How many tasks the agent works on at once, or, for a task scheduler, how many tasks it
     * schedules at once. Null for no limit; above 0 otherwise.
     */
    Nullable!int maxParallelTasks = defaultMaxParallelTasks;
    /// The agent's rows in agent_labels, lowercase, in alphabetical order when read.
    string[] labels;

    this() @safe
    {
    }

    this(UUID id, string name, string runtime, string model, string effort, bool taskScheduler,
        string instructions = null, string[] labels = null,
        Nullable!int maxParallelTasks = defaultMaxParallelTasks, bool enabled = true) @safe
    {
        this.id = id;
        this.name = name;
        this.runtime = runtime;
        this.model = model;
        this.effort = effort;
        this.taskScheduler = taskScheduler;
        this.instructions = instructions;
        this.labels = labels;
        this.maxParallelTasks = maxParallelTasks;
        this.enabled = enabled;
    }
}

/// A row of the agent_log table: one prompt an agent was given, and its answer.
class AgentLogEntry
{
    /// Assigned by the database on insert, so UUID.init until the entry is stored.
    UUID id;
    UUID agentId;
    /// Assigned by the database on insert, like the id.
    SysTime createdAt;
    string prompt;
    /// Null until the agent has answered, and for good when it failed to.
    Nullable!string result;

    this() @safe
    {
    }

    this(UUID id, UUID agentId, SysTime createdAt, string prompt, Nullable!string result) @safe
    {
        this.id = id;
        this.agentId = agentId;
        this.createdAt = createdAt;
        this.prompt = prompt;
        this.result = result;
    }
}

/**
 * A row of the defaults table: a value an app-wide setting starts from, such
 * as the runtime, model and effort level a new agent is offered.
 */
class Default
{
    string key;
    string value;

    this() @safe
    {
    }

    this(string key, string value) @safe
    {
        this.key = key;
        this.value = value;
    }
}
