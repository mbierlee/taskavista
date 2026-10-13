module agent;

import vibe.core.core : runTask;
import vibe.core.file : existsFile, moveFile, writeFileUTF8;
import vibe.core.path : NativePath;
import vibe.core.process : ProcessConfig = Config, Redirect, collectOutput, pipeProcess;
import vibe.core.log : logError, logInfo;
import poodinis : Inject;

import std.algorithm.iteration : filter, map;
import std.array : join;
import std.datetime.systime : SysTime;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : mkdirRecurse, tempDir;
import std.format : format;
import std.path : buildPath;
import std.string : strip, toLower;
import std.typecons : Nullable;
import std.uuid : UUID, randomUUID;

import changes : ChangeFeed;
import config : Config, apiUrl;
import model : Agent, AgentLogEntry, Project, defaultEffort;
import prompt : PromptParser;
import repository : AgentLogRepository, AgentRepository, LaneRepository, ProjectRepository, TaskRepository;

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
        }

        const conditions = ["project": !project.isNull];
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
            "<lane name>": lane.get.name,
            "<task description>": task.get.description.strip,
            "<agent list>": agentList(all)
        ];

        const bool[string] noConditions;
        auto scheduler = schedulers.front;
        auto prompt = parser.parse(schedulePrompt, placeholders, noConditions);
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
