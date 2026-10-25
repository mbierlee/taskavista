/**
 * Taskavista
 *
 * The resources as the APIs send and receive them, which may differ from their rows in
 * `model.d`. The services map between the two.
 *
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2026 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

module viewmodel;

import vibe.data.serialization : optional;

import std.datetime.systime : SysTime;
import std.typecons : Nullable;
import std.uuid : UUID;

import model : TaskAddRule, defaultEffort, defaultMaxParallelTasks;

/// A project.
class ProjectViewModel
{
    /// Optional on the wire: a client creating a project has no id yet.
    @optional UUID id;
    string name;
    /**
     * The project's name in its URL. Optional on the wire: the service derives one from the name
     * when a client leaves it out.
     */
    @optional string slug;
    /// What the project is about, and directions for its AI agents. Empty for none.
    @optional string description;
    @optional TaskAddRule taskAddRule = TaskAddRule.firstLane;
    /// Whether AI agents may add, edit and move the project's tasks.
    @optional bool managedByAi;
    /**
     * Whether the project's AI agents are paused: always, for a project not managed by AI.
     * Read-only, and ignored in a body: it follows managedByAi when that changes, and the
     * setAiPaused RPC call changes it otherwise.
     */
    @optional bool aiPaused;
    /**
     * Whether the project has something the web UI can open, in a tab of its own: for now, an
     * index.html in its working directory, served under /working-dirs/. Read-only, and ignored in
     * a body.
     */
    @optional bool canBeOpened;

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
        bool aiPaused = false, bool canBeOpened = false) @safe
    {
        this(name, slug, description, taskAddRule, managedByAi);
        this.id = id;
        this.aiPaused = aiPaused;
        this.canBeOpened = canBeOpened;
    }
}

/// A lane of a project's board.
class LaneViewModel
{
    /// Optional on the wire: a client creating a lane has no id yet.
    @optional UUID id;
    /**
     * Optional on the wire: the path says which project a lane is created in, and a lane never
     * moves to another project.
     */
    @optional UUID projectId;
    string name;
    /**
     * Where the lane sits on its board, counted from 0. Optional on the wire: the service puts a
     * lane that has none after the project's last lane.
     */
    @optional Nullable!int position;
    /// A web colour, "#" and six hex digits.
    string color;
    /// Whether the tasks in this lane count as done. Optional on the wire, and false when left out.
    @optional bool marksDone;

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

/// A task on a lane.
class TaskViewModel
{
    /// Optional on the wire: a client creating a task has no id yet.
    @optional UUID id;
    /**
     * Optional on the wire: the path says which lane a task is created in, and a task sent
     * without one to replace it stays in the lane it is in.
     */
    @optional UUID laneId;
    string description;
    /**
     * Where the task sits in its lane, counted from 0. Optional on the wire: the service puts a
     * task that has none after the lane's last task.
     */
    @optional Nullable!int position;
    /**
     * The AI agent at work on the task now: its own agent while it works on it, and the task
     * scheduler agent while it schedules it. Null when none is. Read-only, and ignored in a body.
     */
    @optional Nullable!UUID workingAgentId;
    /**
     * Whether the task was handed to the AI agents: false for one added while its project was not
     * managed by AI, until it is rescheduled. Read-only, and ignored in a body.
     */
    @optional bool handedToAgents;

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
}

/// A note on something that happened to a task.
class TaskNoteViewModel
{
    UUID id;
    SysTime insertedAt;
    /// What happened, in words, with the names of the lanes and agents involved as they were then.
    string note;
    /// The colour of the lane the note says the task went into, as it was then; null for any other.
    Nullable!string laneColor;

    this() @safe
    {
    }

    this(UUID id, SysTime insertedAt, string note, Nullable!string laneColor) @safe
    {
        this.id = id;
        this.insertedAt = insertedAt;
        this.note = note;
        this.laneColor = laneColor;
    }
}

/// Something an agent runs in, such as Claude Code.
class RuntimeViewModel
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

/// How hard a model works at a prompt.
class EffortLevelViewModel
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

/// A model an agent can use, in the runtime that offers it.
class ModelViewModel
{
    /// The name the runtime itself knows the model by.
    string id;
    string name;
    /// The id of the runtime that offers the model.
    string runtime;
    /// The effort levels the model takes, lowest first, which starts with the default.
    EffortLevelViewModel[] effortLevels;

    this() @safe
    {
    }

    this(string id, string name, string runtime, EffortLevelViewModel[] effortLevels = null) @safe
    {
        this.id = id;
        this.name = name;
        this.runtime = runtime;
        this.effortLevels = effortLevels;
    }
}

/// An AI agent.
class AgentViewModel
{
    /// Optional on the wire: a client creating an agent has no id yet.
    @optional UUID id;
    string name;
    /// The id of the runtime the agent runs in.
    string runtime;
    /// The id of the model the agent uses, one its runtime offers.
    string model;
    /// The id of the effort level the agent works at, one its model takes.
    @optional string effort = defaultEffort;
    /// Whether the agent plans and assigns tasks to the other agents.
    @optional bool taskScheduler;
    /**
     * Whether the agent can be given tasks, and, for a task scheduler, whether it schedules them.
     * Read-only, and ignored in a body: the setAgentEnabled RPC call changes it.
     */
    @optional bool enabled = true;
    /// The agent's own instructions, added to its system prompt. Empty for none.
    @optional string instructions;
    /**
     * How many tasks the agent works on at once, or, for a task scheduler, how many tasks it
     * schedules at once. Null for no limit; above 0 otherwise. Not optional on the wire, since
     * vibe takes a null for an optional field as left out, which would leave no way to send
     * "no limit".
     */
    Nullable!int maxParallelTasks = defaultMaxParallelTasks;
    /// The agent's labels, lowercase, in alphabetical order.
    @optional string[] labels;

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

/**
 * The value an app-wide setting starts from, such as the runtime, model and effort level a new
 * agent is offered.
 */
class DefaultViewModel
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
