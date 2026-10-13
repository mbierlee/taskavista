module agent;

import vibe.core.core : runTask;
import vibe.core.file : existsFile, moveFile, writeFileUTF8;
import vibe.core.path : NativePath;
import vibe.core.process : ProcessConfig = Config, Redirect, collectOutput, pipeProcess;
import vibe.core.log : logError, logInfo;
import vibe.data.json : Json, parseJsonString, serializeToJson;
import poodinis : Inject;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind, find;
import std.array : array, join;
import std.datetime.systime : SysTime;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : mkdirRecurse, tempDir;
import std.format : format;
import std.path : buildPath;
import std.range : chain;
import std.string : indexOf, lastIndexOf, strip, toLower;
import std.typecons : Nullable, nullable;
import std.uuid : UUID, randomUUID;

import changes : ChangeFeed;
import config : Config, apiUrl;
import model : Agent, AgentLogEntry, EffortLevel, Model, Project, Runtime, defaultEffort;
import prompt : PromptParser;
import repository : AgentLogRepository, AgentRepository, DefaultRepository, LaneRepository, ProjectRepository,
    RuntimeRepository, TaskRepository;

/// The permission mode Claude Code runs in. Auto, since in print mode there is
/// nobody to answer a permission prompt.
private enum claudeCodePermissionMode = "auto";

interface IRuntime
{
    /**
     * Sends a prompt to an agent, as a one-off or in a session.
     *
     * Params:
     *   agent = The agent, one that runs on this runtime.
     *   prompt = What to send it.
     *   createSession = Whether to keep the conversation as a session. Without
     *     one, the prompt is a one-off, nothing of it is kept, and `sessionId` is
     *     not read.
     *   sessionId = The session to continue, or null to start a new one, whose
     *     id it is set to.
     *   systemPrompt = Instructions that frame the conversation, or null for
     *     none. Given with the prompt that starts a session, the runtime keeps
     *     them for the rest of it where it can.
     *
     * Returns: The agent's answer, with leading and trailing whitespace stripped.
     *
     * Throws: `Exception` when the agent has no session `sessionId`, or the
     *   runtime fails.
     */
    public string prompt(Agent agent, string prompt, bool createSession, ref string sessionId,
        string systemPrompt = null);

    public string runTimeType();
}

/// Creates the directory an agent runs in for one run, or for every run of
/// one session, if it is not there yet, and returns its path. Every runtime
/// runs its agents in one, so an agent does not start out among the
/// dashboard's files or pick up the settings of the project it would otherwise
/// run in. They share a parent of their own, since tempDir falls back to the
/// current directory when it finds no temp directory.
string createAgentWorkDir(UUID agentId, UUID runId)
{
    auto workDir = buildPath(tempDir, "taskavista-tmp", format("taskavista-agent-%s-%s", agentId, runId));
    mkdirRecurse(workDir);

    return workDir;
}

/// Writes a system prompt to a file, for a runtime that reads it from one, and
/// returns the file's path. The file is named after a hash of the prompt, so
/// the same prompt reuses the file it was written to before. It is never
/// removed, since a run of another agent may be reading it. Written under a
/// name of its own first and then moved into place, so a run started meanwhile
/// with the same prompt never reads half of it.
string createSystemPromptFile(string systemPrompt)
{
    auto dir = buildPath(tempDir, "taskavista-tmp", "system-prompts");
    mkdirRecurse(dir);

    auto path = buildPath(dir, format("%s.txt", sha256Of(systemPrompt).toHexString()));
    if (existsFile(path))
    {
        return path;
    }

    auto partialPath = buildPath(dir, format("%s.partial", randomUUID()));
    writeFileUTF8(NativePath(partialPath), systemPrompt);
    moveFile(partialPath, path);

    return path;
}

/// Runs a prompt on whichever runtime the agent runs on, and records the
/// prompt and its answer in the agent's log, so no runtime has to look up the
/// agent or do its own logging.
class RuntimeExecutor
{
    private AgentRepository agents;
    private AgentLogRepository log;

    /// Every registered runtime. A field, since Poodinis injects arrays only
    /// into fields, not constructor parameters.
    @Inject private IRuntime[] runtimes;

    this(AgentRepository agents, AgentLogRepository log)
    {
        this.agents = agents;
        this.log = log;
    }

    /**
     * Sends a prompt to an agent on its runtime, as a one-off or in a session.
     *
     * Params:
     *   agentId = The agent's id.
     *   prompt = What to send it.
     *   createSession = Whether to keep the conversation as a session. Without
     *     one, the prompt is a one-off and `sessionId` is not read.
     *   sessionId = The session to continue, or null to start a new one, whose
     *     id it is set to.
     *   systemPrompt = Instructions that frame the conversation, or null for
     *     none.
     *
     * Returns: The agent's answer.
     *
     * Throws: `Exception` when the agent does not exist, no runtime runs it, the
     *   agent has no session `sessionId`, or the runtime throws.
     */
    public string prompt(string agentId, string prompt, bool createSession, ref string sessionId,
        string systemPrompt = null)
    {
        auto agent = agents.find(UUID(agentId));
        if (agent.isNull)
        {
            throw new Exception(format("There is no agent %s.", agentId));
        }

        auto runtime = runtimeOf(agent.get);

        // Logged before the run, so a prompt still in progress, or one that
        // failed, shows up with no result.
        auto entry = log.add(new AgentLogEntry(UUID.init, agent.get.id, SysTime.init, prompt,
                Nullable!string.init));

        auto result = runtime.prompt(agent.get, prompt, createSession, sessionId, systemPrompt);
        log.setResult(entry.id, result);

        return result;
    }

    /// Logs an error for every agent whose runtime is not one of the
    /// registered ones, since its prompts would all fail. Logs rather than
    /// throws, like the rest of start-up, so the server still starts when the
    /// database is down.
    public void logAgentsWithoutRuntime() nothrow
    {
        try
        {
            foreach (agent; agents.all())
            {
                if (findRuntime(agent) is null)
                {
                    logError("%s", noRuntimeMessage(agent));
                }
            }
        }
        catch (Exception exception)
        {
            logError("Could not check the agents' runtimes: %s", exception.msg);
        }
    }

    private IRuntime runtimeOf(Agent agent)
    {
        auto runtime = findRuntime(agent);
        if (runtime is null)
        {
            throw new Exception(noRuntimeMessage(agent));
        }

        return runtime;
    }

    /// The runtime the agent runs on, or null when none of the registered ones is.
    private IRuntime findRuntime(Agent agent)
    {
        foreach (runtime; runtimes)
        {
            if (runtime.runTimeType() == agent.runtime)
            {
                return runtime;
            }
        }

        return null;
    }

    private static string noRuntimeMessage(Agent agent)
    {
        return format("Agent %s (%s) runs on %s, which no runtime here provides.", agent.name, agent.id, agent
                .runtime);
    }
}

/// Runs an agent's prompt through the Claude Code command line, in print mode,
/// with the model the agent is configured with.
class ClaudeCodeRuntime : IRuntime
{
    /// The id of this runtime in the runtimes table.
    enum id = "claude-code";

    /// Lets agents call the API without auto mode's classifier, which judges
    /// every command afresh and blocks one call while allowing the next. Given
    /// on the command line rather than in a settings file, so it holds whatever
    /// directory the agent runs in. The rules match the command as written, so
    /// agent-help.txt asks for curl with the URL unquoted and nothing piped.
    private string[] allowedTools;

    this(Config config)
    {
        auto url = config.apiUrl;
        allowedTools = [format("Bash(curl %s/*)", url), format("Bash(curl * %s/*)", url)];
    }

    /**
     * Claude Code resumes a session only from the directory it ran in, so
     * every run of a session runs in the directory named after it.
     *
     * The directory is made again if it has gone, since the session is kept
     * in Claude Code's own files, not in it. Running in it also keeps one
     * agent from resuming another's session.
     */
    public string prompt(Agent agent, string prompt, bool createSession, ref string sessionId,
        string systemPrompt = null)
    {
        if (!createSession)
        {
            return run(agent, prompt, systemPrompt, createAgentWorkDir(agent.id, randomUUID()), [
                "--no-session-persistence"
            ]);
        }

        if (sessionId is null)
        {
            auto newSessionId = randomUUID();
            auto answer = run(agent, prompt, systemPrompt, createAgentWorkDir(agent.id, newSessionId), [
                "--session-id", newSessionId.toString
            ]);

            sessionId = newSessionId.toString;

            return answer;
        }

        UUID session;
        try
        {
            // Not parseUUID, which takes a variable by ref and consumes it,
            // leaving sessionId empty for the caller.
            session = UUID(sessionId);
        }
        catch (Exception exception)
        {
            throw new Exception(format("Agent %s has no session %s.", agent.name, sessionId));
        }

        return run(agent, prompt, systemPrompt, createAgentWorkDir(agent.id, session), [
            "--resume", session.toString
        ]);
    }

    public string runTimeType()
    {
        return id;
    }

    /// Returns Claude Code's answer. Throws when Claude Code exits with an error.
    private string run(Agent agent, string prompt, string systemPrompt, string workDir, string[] sessionArgs)
    {
        // Appended to Claude Code's own system prompt, since replacing that
        // would take away its instructions for using its tools. Claude Code
        // records the one a session starts with and reuses it on resume. Given
        // in a file rather than as an argument, which the kernel caps at 128 KiB
        // and cuts off at the first NUL. The file is kept out of the work
        // directory, which is meant to become the project's own directory, so
        // nothing of the dashboard's should be left in it.
        string[] systemPromptArgs;
        if (systemPrompt !is null)
        {
            systemPromptArgs = ["--append-system-prompt-file", createSystemPromptFile(systemPrompt)];
        }

        // Not std.process, which would block the event loop, and with it every
        // other request, for as long as Claude Code takes. stderr is not read,
        // since reading two pipes one after the other can deadlock once the
        // unread one fills up. The prompt goes on stdin so one starting with "-"
        // is not taken for an option. No MCP config is given, so the agent gets
        // none of the MCP servers of whoever runs the dashboard.
        auto claude = pipeProcess([
            "claude",
            "--print",
            "--strict-mcp-config",
            "--permission-mode", claudeCodePermissionMode,
            "--allowedTools"
        ] ~ allowedTools ~ [
            // Right after the rules, since --allowedTools takes every argument
            // up to the next option.
            "--model", agent.model
        ] ~ effortArgs(agent) ~ sessionArgs ~ systemPromptArgs,
        Redirect.stdin | Redirect.stdout, null, ProcessConfig.none, NativePath(workDir));

        claude.stdin.write(prompt);
        claude.stdin.close();

        auto answer = claude.stdout.collectOutput();
        auto status = claude.process.wait();
        if (status != 0)
        {
            throw new Exception(format("Claude Code exited with status %s: %s", status, answer));
        }

        return answer.strip;
    }

    /// Claude Code has no name for its default effort level; it picks it
    /// when none is given.
    private static string[] effortArgs(Agent agent)
    {
        return agent.effort == defaultEffort ? [] : ["--effort", agent.effort];
    }
}

/// Tells an agent who it is and how it uses the API. Comes first in the system
/// prompt of every interaction with an agent.
private enum agentPromptTemplate = import("agent.txt");

/// Introduces the agent to the person chatting with it. Follows the agent prompt
/// in the system prompt of a chat.
private enum newChatPrompt = import("new-agent-chat.txt");

/// How an agent uses the API, with the API's URL left to fill in.
private enum agentHelpTemplate = import("agent-help.txt");

/// How an agent uses the API. Given to an agent at the start of every
/// interaction, and served to agents at /agent-help.txt, so it is written to
/// make sense on its own.
class AgentHelp
{
    /// The help, filled in once, since the URL comes from the config.
    public immutable string text;

    this(Config config, PromptParser parser)
    {
        const bool[string] noConditions;
        text = parser.parse(agentHelpTemplate, ["<api url>": config.apiUrl], noConditions).strip;
    }
}

/// The part of a system prompt that every interaction with an agent starts
/// with, whatever the interaction is: who the agent is, its own instructions,
/// and the API help.
class AgentPrompt
{
    private PromptParser parser;
    private AgentHelp help;

    this(PromptParser parser, AgentHelp help)
    {
        this.parser = parser;
        this.help = help;
    }

    /**
     * Puts the agent prompt ahead of the prompt of an interaction.
     *
     * Params:
     *   agent = The agent the system prompt is for.
     *   interactionPrompt = The interaction's own prompt, filled in already.
     *
     * Returns: The whole system prompt.
     */
    public string systemPrompt(Agent agent, string interactionPrompt)
    {
        string[string] placeholders = [
            "<agent name>": agent.name,
            "<agent id>": agent.id.toString,
            "<agent labels>": agent.labels.join(", "),
            "<agent instructions>": agent.instructions.strip,
            "<agent help>": help.text
        ];

        const conditions = ["labels": agent.labels.length > 0, "instructions": agent.instructions.strip.length > 0];

        return parser.parse(agentPromptTemplate, placeholders, conditions).strip
            ~ "\n\n" ~ interactionPrompt.strip;
    }
}

/// Passes a person's chat messages on to an agent. A chat is a session on the
/// agent's runtime, started with the agent prompt and the new-chat prompt as its
/// system prompt, which tell the agent who it is and where the person is. Every
/// message goes as it is.
class AgentChat
{
    private RuntimeExecutor executor;
    private PromptParser parser;
    private AgentPrompt agentPrompt;

    this(RuntimeExecutor executor, PromptParser parser, AgentPrompt agentPrompt)
    {
        this.executor = executor;
        this.parser = parser;
        this.agentPrompt = agentPrompt;
    }

    /**
     * Sends the person's message to an agent, in a chat that is going on or as
     * the start of a new one, and waits for its answer.
     *
     * Params:
     *   agent = The agent to chat with.
     *   project = The project the person is in, or null when they are in none.
     *     Only told to the agent when the chat starts.
     *   message = What the person wrote.
     *   sessionId = The chat's session, or null to start a new chat, whose
     *     session it is set to.
     *
     * Returns: The agent's answer.
     *
     * Throws: `Exception` when the agent has no session `sessionId`, its runtime
     *   is not one this server provides, or the runtime fails.
     */
    public string send(Agent agent, Nullable!Project project, string message, ref string sessionId)
    {
        if (sessionId !is null)
        {
            return executor.prompt(agent.id.toString, message, true, sessionId);
        }

        string[string] placeholders;
        if (!project.isNull)
        {
            placeholders["<project name>"] = project.get.name;
            placeholders["<project id>"] = project.get.id.toString;
            placeholders["<project description>"] = project.get.description.strip;
        }

        const conditions = [
            "project": !project.isNull,
            "description": !project.isNull && project.get.description.strip.length > 0
        ];
        auto chatPrompt = parser.parse(newChatPrompt, placeholders, conditions);

        return executor.prompt(agent.id.toString, message, true, sessionId,
            agentPrompt.systemPrompt(agent, chatPrompt));
    }
}

/// Asks an agent which agent should work on the task, given the agents there are.
private enum schedulePrompt = import("schedule-tasks.txt");

/// Picks the agent that should work on a task.
class TaskScheduler
{
    private AgentRepository agents;
    private TaskRepository tasks;
    private LaneRepository lanes;
    private ProjectRepository projects;
    private PromptParser parser;
    private AgentPrompt agentPrompt;
    private RuntimeExecutor executor;
    private ChangeFeed changes;

    this(AgentRepository agents, TaskRepository tasks, LaneRepository lanes, ProjectRepository projects,
        PromptParser parser, AgentPrompt agentPrompt, RuntimeExecutor executor, ChangeFeed changes)
    {
        this.agents = agents;
        this.tasks = tasks;
        this.lanes = lanes;
        this.projects = projects;
        this.parser = parser;
        this.agentPrompt = agentPrompt;
        this.executor = executor;
        this.changes = changes;
    }

    /// Has the scheduler agent choose an agent for the task, in the background,
    /// since the request that added the task should not wait on an agent.
    public void schedule(UUID taskId)
    {
        runTask(() nothrow {
            try
            {
                choose(taskId);
            }
            catch (Exception e)
            {
                logError("Scheduling task %s failed: %s", taskId, e.msg);
            }
        });
    }

    private void choose(UUID taskId)
    {
        // TODO: Deal with paused projects.
        // The task, its lane or its project may be gone by the time it is
        // scheduled, and then there is nothing to schedule.
        auto task = tasks.find(taskId);
        if (task.isNull)
        {
            return;
        }

        auto lane = lanes.find(task.get.laneId);
        if (lane.isNull)
        {
            return;
        }

        auto project = projects.find(lane.get.projectId);
        if (project.isNull)
        {
            return;
        }

        auto all = agents.all();
        auto schedulers = all.filter!(agent => agent.taskScheduler);
        if (schedulers.empty)
        {
            logInfo("Task %s is not scheduled, since there is no task scheduler agent.", taskId);
            noted(tasks.recordNoScheduler(taskId), taskId, project.get.id);
            return;
        }

        string[string] placeholders = [
            "<project name>": project.get.name,
            "<project id>": project.get.id.toString,
            "<project description>": project.get.description.strip,
            "<lane name>": lane.get.name,
            "<task description>": task.get.description.strip,
            "<agent list>": agentList(all)
        ];

        const conditions = ["description": project.get.description.strip.length > 0];
        auto scheduler = schedulers.front;
        auto prompt = parser.parse(schedulePrompt, placeholders, conditions);
        auto systemPrompt = agentPrompt.systemPrompt(scheduler, "").strip;

        // Caught here rather than by schedule, so the log says which scheduler failed.
        string answer;
        try
        {
            string noSession;
            answer = executor.prompt(scheduler.id.toString, prompt, false, noSession, systemPrompt).strip;
        }
        catch (Exception e)
        {
            logError("Scheduler %s failed on task %s: %s", scheduler.name, taskId, e.msg);
            noted(tasks.recordSchedulingFailure(taskId, scheduler.id), taskId, project.get.id);
            return;
        }

        Nullable!UUID chosen;
        if (answer != "none")
        {
            auto matches = all.filter!(agent => !agent.taskScheduler && agent.id.toString == answer.toLower);
            if (matches.empty)
            {
                logError("Scheduler %s answered task %s with \"%s\", which is not an agent it could choose.",
                    scheduler.name, taskId, answer);
                noted(tasks.recordSchedulingFailure(taskId, scheduler.id), taskId, project.get.id);
                return;
            }

            chosen = matches.front.id;
        }

        // An assignment is a note only when it changed the agent, which it
        // almost always did, and a needless event costs the UI only a refetch.
        const assigned = tasks.assignAiAgent(taskId, chosen);
        if (chosen.isNull)
        {
            noted(tasks.recordNoAgentFound(taskId, scheduler.id), taskId, project.get.id);
        }
        else
        {
            noted(assigned, taskId, project.get.id);
        }
    }

    /// Reports a note on the task, when one was added.
    private void noted(bool added, UUID taskId, UUID projectId)
    {
        if (added)
        {
            changes.note(taskId, projectId);
        }
    }

    /// One block per agent that can be given a task, set apart by tags since an
    /// agent's instructions run over several lines. Schedulers are left out,
    /// since they hand out tasks rather than work on them.
    private static string agentList(Agent[] all)
    {
        return all
            .filter!(agent => !agent.taskScheduler)
            .map!(agent => describe(agent))
            .join("\n\n");
    }

    /// An agent as the scheduler sees it. Labels are always given, as "none" when
    /// there are none, while instructions are left out when there are none.
    private static string describe(Agent agent)
    {
        auto labels = agent.labels.length == 0 ? "none" : agent.labels.join(", ");
        auto instructions = agent.instructions.strip;

        return format("<agent>\nID: %s\nName: %s\nLabels: %s\n%s</agent>", agent.id, agent.name, labels,
            instructions.length == 0 ? "" : "Instructions:\n" ~ instructions ~ "\n");
    }
}

/// Asks an agent to draft a new agent from a person's description of it.
private enum quickCreatePrompt = import("quick-create-agent.txt");

/// Drafts a new agent from a person's description of it, for the person to
/// review in the new agent dialog before anything is created. Any agent can
/// draft one, so the one named Generic is asked first, as the chat offers it
/// first, and then each task scheduler, since there is always meant to be one.
class AgentDrafter
{
    private AgentRepository agents;
    private RuntimeRepository runtimes;
    private DefaultRepository defaults;
    private PromptParser parser;
    private AgentPrompt agentPrompt;
    private RuntimeExecutor executor;

    this(AgentRepository agents, RuntimeRepository runtimes, DefaultRepository defaults, PromptParser parser,
        AgentPrompt agentPrompt, RuntimeExecutor executor)
    {
        this.agents = agents;
        this.runtimes = runtimes;
        this.defaults = defaults;
        this.parser = parser;
        this.agentPrompt = agentPrompt;
        this.executor = executor;
    }

    /**
     * Has an agent draft a new agent from the description. An agent that fails
     * to answer, or answers with something that is not a draft, is passed over
     * for the next.
     *
     * Params:
     *   description = What the person wrote the new agent should do.
     *
     * Returns: The draft, as an object with the fields of the new agent dialog,
     *   or one with only an `error`, a message for the person, when the agent
     *   found the description too vague or no agent could draft one.
     */
    public Json draft(string description)
    {
        auto all = agents.all();
        auto drafters = all.filter!(agent => isGeneric(agent))
            .chain(all.filter!(agent => agent.taskScheduler && !isGeneric(agent)))
            .array;
        if (drafters.length == 0)
        {
            return draftError("There is no agent to draft one with. Add an agent named Generic, or a task scheduler.");
        }

        auto models = runtimes.models();
        string[string] defaultIds;
        foreach (entry; defaults.all())
        {
            defaultIds[entry.key] = entry.value;
        }

        string[string] placeholders = [
            "<agent request>": description.strip,
            "<default runtime>": defaultIds.get("runtime", ""),
            "<default model>": defaultIds.get("model", ""),
            "<default effort>": defaultIds.get("effort", defaultEffort),
            "<runtime list>": runtimeList(runtimes.all(), models),
            "<agent list>": all.map!(agent => describe(agent)).join("\n")
        ];
        auto prompt = parser.parse(quickCreatePrompt, placeholders, ["agents": all.length > 0]);

        foreach (drafter; drafters)
        {
            string answer;
            try
            {
                string noSession;
                answer = executor.prompt(drafter.id.toString, prompt, false, noSession,
                    agentPrompt.systemPrompt(drafter, "").strip);
            }
            catch (Exception exception)
            {
                logError("Agent %s could not draft an agent: %s", drafter.name, exception.msg);
                continue;
            }

            auto draft = readDraft(answer, models, defaultIds);
            if (draft.isNull)
            {
                logError("Agent %s answered a request to draft an agent with \"%s\", which is not a draft.",
                    drafter.name, answer);
                continue;
            }

            return draft.get;
        }

        return draftError("No agent could draft one. The server's log says why.");
    }

    /// Found by name, as the chat finds it, since it is an ordinary agent with
    /// nothing else to tell it by.
    private static bool isGeneric(Agent agent)
    {
        return agent.name.toLower == "generic";
    }

    /// One block per runtime, with a line per model it offers.
    private static string runtimeList(Runtime[] all, Model[] models)
    {
        return all.map!(runtime => format("<runtime>\nID: %s\nName: %s\nModels:\n%s</runtime>", runtime.id,
                runtime.name, models
                .filter!(model => model.runtime == runtime.id)
                .map!(model => format("- ID %s (%s), effort levels: %s\n", model.id, model.name,
                    model.effortLevels.map!(level => level.id).join(", ")))
                .join))
            .join("\n\n");
    }

    /// An existing agent, by the name it is known by and its labels.
    private static string describe(Agent agent)
    {
        return format("- %s (labels: %s)", agent.name, agent.labels.length == 0 ? "none" : agent.labels.join(", "));
    }
}

private Json draftError(string message)
{
    auto error = Json.emptyObject;
    error["error"] = message;

    return error;
}

/**
 * Reads an agent's answer to the quick-create prompt.
 *
 * Agents are asked for a bare JSON object but often wrap it in a code fence
 * or a sentence, so the object is taken from between the first `{` and the
 * last `}`. A runtime, model and effort level that do not go together are
 * replaced by the defaults, and the labels are made lowercase and unique, so
 * the dialog shows only what it could save. Whatever else is in the object
 * is dropped.
 *
 * Returns: The draft, or an error object when the agent answered with one, or
 *   an empty Nullable when the answer is neither.
 */
private Nullable!Json readDraft(string answer, Model[] models, string[string] defaultIds)
{
    const start = answer.indexOf('{');
    const end = answer.lastIndexOf('}');
    if (start < 0 || end < start)
    {
        return Nullable!Json.init;
    }

    Json json;
    try
    {
        json = parseJsonString(answer[start .. end + 1]);
    }
    catch (Exception exception)
    {
        return Nullable!Json.init;
    }

    if (json.type != Json.Type.object)
    {
        return Nullable!Json.init;
    }

    string text(string key)
    {
        auto value = key in json;
        return value !is null && value.type == Json.Type.string ? value.get!string.strip : "";
    }

    if (text("error").length > 0)
    {
        return draftError(text("error")).nullable;
    }

    if (text("name").length == 0)
    {
        return Nullable!Json.init;
    }

    auto runtime = text("runtime");
    auto modelId = text("model");
    auto effort = text("effort");
    auto model = models.find!(m => m.id == modelId && m.runtime == runtime);
    if (model.length == 0)
    {
        runtime = defaultIds.get("runtime", "");
        modelId = defaultIds.get("model", "");
        effort = defaultIds.get("effort", defaultEffort);
    }
    else if (!model[0].effortLevels.canFind!(level => level.id == effort))
    {
        effort = defaultEffort;
    }

    string[] labels;
    if (auto list = "labels" in json)
    {
        if (list.type == Json.Type.array)
        {
            foreach (item; *list)
            {
                if (item.type != Json.Type.string)
                {
                    continue;
                }

                auto label = item.get!string.strip.toLower;
                if (label.length > 0 && !labels.canFind(label))
                {
                    labels ~= label;
                }
            }
        }
    }

    auto scheduler = "taskScheduler" in json;

    auto draft = Json.emptyObject;
    draft["name"] = text("name");
    draft["runtime"] = runtime;
    draft["model"] = modelId;
    draft["effort"] = effort;
    draft["instructions"] = text("instructions");
    draft["labels"] = serializeToJson(labels);
    draft["taskScheduler"] = scheduler !is null && scheduler.type == Json.Type.bool_ && scheduler.get!bool;

    return draft.nullable;
}

unittest
{
    auto models = [
        new Model("sonnet", "Claude Sonnet", "claude-code", [
            new EffortLevel("default", "Default"), new EffortLevel("high", "High")
        ])
    ];
    auto defaultIds = ["runtime": "claude-code", "model": "sonnet", "effort": "default"];

    auto fenced = readDraft("```json\n{\"name\": \" Writer \", \"runtime\": \"claude-code\", \"model\": \"sonnet\","
            ~ " \"effort\": \"high\", \"labels\": [\"Docs\", \"docs\", \" \", 3], \"taskScheduler\": true}\n```",
            models, defaultIds);
    assert(!fenced.isNull);
    assert(fenced.get["name"].get!string == "Writer");
    assert(fenced.get["effort"].get!string == "high");
    assert(fenced.get["labels"].length == 1 && fenced.get["labels"][0].get!string == "docs");
    assert(fenced.get["taskScheduler"].get!bool);
    assert(fenced.get["instructions"].get!string == "");

    auto unknown = readDraft(`{"name": "Writer", "runtime": "x", "model": "opus", "effort": "max"}`, models,
        defaultIds);
    assert(unknown.get["model"].get!string == "sonnet" && unknown.get["effort"].get!string == "default");

    auto tooHard = readDraft(`{"name": "Writer", "runtime": "claude-code", "model": "sonnet", "effort": "max"}`,
        models, defaultIds);
    assert(tooHard.get["model"].get!string == "sonnet" && tooHard.get["effort"].get!string == "default");

    auto error = readDraft(`{"error": "Say what it should do."}`, models, defaultIds);
    assert(error.get["error"].get!string == "Say what it should do." && "name" !in error.get);

    assert(readDraft("I cannot help with that.", models, defaultIds).isNull);
    assert(readDraft(`{"name": " "}`, models, defaultIds).isNull);
    assert(readDraft(`{"name": "Writer"`, models, defaultIds).isNull);
}
