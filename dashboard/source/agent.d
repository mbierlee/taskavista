/**
 * Taskavista
 *
 * The AI agents: the runtimes they run on, their chats, and the task scheduler and executor
 * that hand them tasks and run them.
 *
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2026 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

module agent;

import vibe.core.core : runTask, sleep;
import vibe.core.file : existsFile, moveFile, writeFileUTF8;
import vibe.core.path : NativePath;
import vibe.core.process : ProcessConfig = Config, Process, Redirect, collectOutput, pipeProcess;
import vibe.core.log : logError, logInfo;
import vibe.data.json : Json, parseJsonString, serializeToJson;
import poodinis : Inject;

import std.algorithm.comparison : among;
import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind, find;
import std.array : array, join;
import std.datetime : Duration, seconds;
import std.datetime.date : DateTime;
import std.datetime.systime : SysTime;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : SpanMode, dirEntries, exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.format : format;
import std.path : buildPath;
import std.range : chain, retro;
import std.string : indexOf, lastIndexOf, strip, toLower;
import std.typecons : Nullable, nullable;
import std.uuid : UUID, randomUUID;

import eventing : Event, IEventPublisher;
import config : Config, apiUrl;
import model : Agent, AgentLogEntry, AgentStatus, EffortLevel, Lane, Model, Project, Runtime, Task,
    TaskNote, defaultEffort;
import prompt : PromptParser;
import repository : IAgentLogRepository, IAgentRepository, IDefaultRepository, ILaneRepository, IProjectRepository,
    IRuntimeRepository, ITaskRepository, ITransactional;
import workingdir : IndexPages, ProjectWorkingDirs;

/**
 * The permission mode Claude Code runs in. Auto, since in print mode there is
 * nobody to answer a permission prompt.
 */
private enum claudeCodePermissionMode = "auto";

/// How long Claude Code is given to end once it is asked to, before it is killed.
private enum Duration claudeCodeStopGrace = 5.seconds;

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
     *   workingDir = The directory the agent works on, such as its project's
     *     working directory, or null for none.
     *   scratchSpace = The directory the agent keeps what is temporary in, or
     *     null for one the runtime makes, of the run or of the session.
     *   runIn = Which of the two the agent runs in; the other is open to it
     *     too. A session is continued in the directory it started in.
     *   stop = What the run can be stopped with while it is going, or null for
     *     a run that is never stopped.
     *
     * Returns: The agent's answer, with leading and trailing whitespace stripped.
     *
     * Throws: `RunStoppedException` when the run was stopped through `stop`, and
     *   `Exception` when the agent has no session `sessionId`, or the runtime
     *   fails.
     */
    public string prompt(Agent agent, string prompt, bool createSession, ref string sessionId,
        string systemPrompt = null, string workingDir = null, string scratchSpace = null,
        RunIn runIn = RunIn.workingDir, RunStop stop = null);

    public string runTimeType();
}

/**
 * Which directory an agent runs in. The working directory when there is one,
 * except for a session that has to outlast it being renamed, which runs in
 * its scratch space.
 */
enum RunIn
{
    workingDir,
    scratchSpace
}

/**
 * Lets whoever starts a run stop it while it is going, such as a task's run once the task is no
 * longer wanted. The runtime the run is on says what stopping it takes, for as long as it runs.
 */
class RunStop
{
    private bool requested;
    private void delegate() nothrow stopRun;

    /// Stops the run, or keeps it from starting when it has not yet.
    public void request() nothrow
    {
        if (requested)
        {
            return;
        }

        requested = true;
        if (stopRun !is null)
        {
            stopRun();
        }
    }

    /// Whether the run has been asked to stop.
    public bool isRequested() const nothrow
    {
        return requested;
    }

    /// For a runtime: sets what stopping the run takes while it is going, or null once it is not.
    public void whileRunning(void delegate() nothrow stopRun) nothrow
    {
        this.stopRun = stopRun;
    }
}

/// Thrown by a run that was stopped through its `RunStop`, so that it is told apart from a failure.
class RunStoppedException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

/**
 * Creates the scratch space of an agent's run, or of every run of one session,
 * if it is not there yet, and returns its path. It is where the agent keeps
 * what is temporary, and where it runs when it has no working directory, so
 * an agent does not start out among the dashboard's files or pick up its
 * settings. They share a parent of their own, since tempDir falls back to the
 * current directory when it finds no temp directory.
 */
string createAgentScratchSpace(UUID agentId, UUID runId)
{
    auto scratchSpace = agentScratchSpace(agentId, runId);
    mkdirRecurse(scratchSpace);

    return scratchSpace;
}

/**
 * Removes the scratch space of an agent's run, or of a session, once nothing runs in it any more,
 * along with whatever the agent left there. One that is not there is passed over. A failure is
 * logged rather than thrown, since what the run was for is done either way.
 */
void removeAgentScratchSpace(UUID agentId, UUID runId) nothrow
{
    try
    {
        removeScratchSpace(agentScratchSpace(agentId, runId));
    }
    catch (Exception e)
    {
        logError("The scratch space of run %s of agent %s could not be removed: %s", runId, agentId, e.msg);
    }
}

/// Removes every scratch space of an agent's, such as once the agent is deleted, as `removeAgentScratchSpace` does one.
void removeAgentScratchSpaces(UUID agentId) nothrow
{
    try
    {
        auto root = scratchSpaceRoot();
        if (!root.exists)
        {
            return;
        }

        // Listed before any is removed, since removing them while they are listed may skip some.
        auto scratchSpaces = dirEntries(root, format("%s-*", scratchSpacePrefix(agentId)), SpanMode.shallow, false)
            .map!(entry => entry.name).array;
        foreach (scratchSpace; scratchSpaces)
        {
            try
            {
                removeScratchSpace(scratchSpace);
            }
            catch (Exception e)
            {
                logError("The scratch space %s could not be removed: %s", scratchSpace, e.msg);
            }
        }
    }
    catch (Exception e)
    {
        logError("The scratch spaces of agent %s could not be removed: %s", agentId, e.msg);
    }
}

private string agentScratchSpace(UUID agentId, UUID runId)
{
    return buildPath(scratchSpaceRoot(), format("%s-%s", scratchSpacePrefix(agentId), runId));
}

private string scratchSpacePrefix(UUID agentId)
{
    return format("taskavista-scratch-%s", agentId);
}

private string scratchSpaceRoot()
{
    return buildPath(tempDir, "taskavista-tmp");
}

/// rmdirRecurse does not follow symbolic links, so a link an agent left there to elsewhere only loses the link.
private void removeScratchSpace(string scratchSpace)
{
    if (scratchSpace.exists)
    {
        rmdirRecurse(scratchSpace);
    }
}

/**
 * Writes a system prompt to a file, for a runtime that reads it from one, and
 * returns the file's path. The file is named after a hash of the prompt, so
 * the same prompt reuses the file it was written to before. It is never
 * removed, since a run of another agent may be reading it. Written under a
 * name of its own first and then moved into place, so a run started meanwhile
 * with the same prompt never reads half of it.
 */
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

/**
 * Runs a prompt on whichever runtime the agent runs on, and records the
 * prompt and its answer in the agent's log, so no runtime has to look up the
 * agent or do its own logging.
 */
class RuntimeExecutor
{
    private IAgentRepository agents;
    private IAgentLogRepository log;

    /**
     * Every registered runtime. A field, since Poodinis injects arrays only
     * into fields, not constructor parameters.
     */
    @Inject private IRuntime[] runtimes;

    this(IAgentRepository agents, IAgentLogRepository log)
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
     *   workingDir = The directory the agent works on, or null for none.
     *   scratchSpace = The directory for what is temporary, or null for one
     *     the runtime makes.
     *   runIn = Which of the two the agent runs in.
     *   stop = What the run can be stopped with, or null for none.
     *
     * Returns: The agent's answer.
     *
     * Throws: `RunStoppedException` when the run was stopped, and `Exception`
     *   when the agent does not exist, no runtime runs it, the agent has no
     *   session `sessionId`, or the runtime throws.
     */
    public string prompt(string agentId, string prompt, bool createSession, ref string sessionId,
        string systemPrompt = null, string workingDir = null, string scratchSpace = null,
        RunIn runIn = RunIn.workingDir, RunStop stop = null)
    {
        auto agent = agents.find(UUID(agentId));
        if (agent.isNull)
        {
            throw new Exception(format("There is no agent %s.", agentId));
        }

        auto runtime = runtimeOf(agent.get);

        // Logged before the run, so a prompt still in progress, or one that
        // failed or was stopped, shows up with no result.
        auto entry = log.add(new AgentLogEntry(UUID.init, agent.get.id, SysTime.init, prompt,
                Nullable!string.init));

        auto result = runtime.prompt(agent.get, prompt, createSession, sessionId, systemPrompt, workingDir,
            scratchSpace, runIn, stop);
        log.setResult(entry.id, result);

        return result;
    }

    /**
     * Logs an error for every agent whose runtime is not one of the
     * registered ones, since its prompts would all fail. Logs rather than
     * throws, like the rest of start-up, so the server still starts when the
     * database is down.
     */
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

/**
 * Runs an agent's prompt through the Claude Code command line, in print mode,
 * with the model the agent is configured with.
 */
class ClaudeCodeRuntime : IRuntime
{
    /// The id of this runtime in the runtimes table.
    enum id = "claude-code";

    /**
     * Lets agents call the API without auto mode's classifier, which judges
     * every command afresh and blocks one call while allowing the next. Given
     * on the command line rather than in a settings file, so it holds whatever
     * directory the agent runs in. The rules match the command as written, so
     * agent-help.txt asks for curl with the URL unquoted and nothing piped.
     */
    private string[] allowedTools;

    this(Config config)
    {
        auto url = config.apiUrl;
        allowedTools = [
            format("Bash(curl %s/*)", url), format("Bash(curl * %s/*)", url)
        ];
    }

    /**
     * Claude Code resumes a session only from the directory it ran in, so
     * every run of a session that runs in a scratch space of the runtime's
     * runs in the one named after it.
     *
     * The scratch space is made again if it has gone, since the session is kept
     * in Claude Code's own files, not in it. Running in it also keeps one
     * agent from resuming another's session.
     */
    public string prompt(Agent agent, string prompt, bool createSession, ref string sessionId,
        string systemPrompt = null, string workingDir = null, string scratchSpace = null,
        RunIn runIn = RunIn.workingDir, RunStop stop = null)
    {
        // Claude Code lets an agent write only in the directory it runs in and
        // the ones added to it.
        static string[] addDir(string dir)
        {
            return dir is null ? [] : ["--add-dir", dir];
        }

        string runAs(UUID runId, string[] sessionArgs)
        {
            if (runIn == RunIn.workingDir && workingDir !is null)
            {
                return run(agent, prompt, systemPrompt, workingDir, addDir(scratchSpace) ~ sessionArgs, stop);
            }

            auto scratch = scratchSpace is null ? createAgentScratchSpace(agent.id, runId)
                : scratchSpace;
            return run(agent, prompt, systemPrompt, scratch, addDir(workingDir) ~ sessionArgs, stop);
        }

        // The scratch spaces removed here are only those runAs makes: a one-off's, which nothing runs
        // in again, and a new session's whose first run failed, since the caller never learns
        // the session to continue it.
        if (!createSession)
        {
            auto runId = randomUUID();
            scope (exit)
            {
                if (scratchSpace is null)
                {
                    removeAgentScratchSpace(agent.id, runId);
                }
            }

            return runAs(runId, [
                    "--no-session-persistence"
                ]);
        }

        if (sessionId is null)
        {
            auto newSessionId = randomUUID();
            scope (failure)
            {
                if (scratchSpace is null)
                {
                    removeAgentScratchSpace(agent.id, newSessionId);
                }
            }

            auto answer = runAs(newSessionId, [
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

        return runAs(session, [
                "--resume", session.toString
            ]);
    }

    public string runTimeType()
    {
        return id;
    }

    /**
     * Returns Claude Code's answer. Throws `RunStoppedException` when it was stopped through `stop`,
     * and `Exception` when it exits with an error.
     */
    private string run(Agent agent, string prompt, string systemPrompt, string dir, string[] runArgs,
        RunStop stop)
    {
        if (stop !is null && stop.isRequested)
        {
            throw new RunStoppedException("Claude Code was stopped before it started.");
        }

        // Appended to Claude Code's own system prompt, since replacing that
        // would take away its instructions for using its tools. Claude Code
        // records the one a session starts with and reuses it on resume. Given
        // in a file rather than as an argument, which the kernel caps at 128 KiB
        // and cuts off at the first NUL. The file is kept out of the directory
        // the agent runs in, so nothing of the dashboard's is left among the
        // project's files.
        string[] systemPromptArgs;
        if (systemPrompt !is null)
        {
            systemPromptArgs = [
                "--append-system-prompt-file",
                createSystemPromptFile(systemPrompt)
            ];
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
        ] ~ effortArgs(agent) ~ runArgs ~ systemPromptArgs,
        Redirect.stdin | Redirect.stdout, null, ProcessConfig.none, NativePath(dir));

        // On the heap, since a closure cannot hold a struct with a destructor, as Process has.
        auto process = new Process;
        *process = claude.process;
        if (stop !is null)
        {
            stop.whileRunning(() nothrow { stopProcess(process); });
        }
        scope (exit)
        {
            if (stop !is null)
            {
                stop.whileRunning(null);
            }
        }

        string answer;
        int status;
        try
        {
            claude.stdin.write(prompt);
            claude.stdin.close();

            answer = claude.stdout.collectOutput();
            status = process.wait();
        }
        catch (Exception e)
        {
            // A process stopped while its prompt is written breaks the pipe.
            if (stop is null || !stop.isRequested)
            {
                throw e;
            }
        }

        if (stop !is null && stop.isRequested)
        {
            throw new RunStoppedException("Claude Code was stopped.");
        }

        if (status != 0)
        {
            throw new Exception(format("Claude Code exited with status %s: %s", status, answer));
        }

        return answer.strip;
    }

    /**
     * Asks Claude Code to end, with SIGTERM, so that it can stop the processes it started and
     * leave its own files whole, and kills it if it has not ended after `claudeCodeStopGrace`.
     */
    private static void stopProcess(Process* process) nothrow
    {
        try
        {
            process.kill();
            runTask((Process* process) nothrow {
                try
                {
                    if (process.wait(claudeCodeStopGrace).isNull)
                    {
                        process.forceKill();
                    }
                }
                catch (Exception e)
                {
                    logError("Claude Code could not be killed: %s", e.msg);
                }
            }, process);
        }
        catch (Exception e)
        {
            logError("Claude Code could not be stopped: %s", e.msg);
        }
    }

    /**
     * Claude Code has no name for its default effort level; it picks it
     * when none is given.
     */
    private static string[] effortArgs(Agent agent)
    {
        return agent.effort == defaultEffort ? [] : ["--effort", agent.effort];
    }
}

/**
 * Tells an agent who it is and how it uses the API. Comes first in the system
 * prompt of every interaction with an agent.
 */
private enum agentPromptTemplate = import("system/agent.txt");

/**
 * Introduces the agent to the person chatting with it. Follows the agent prompt
 * in the system prompt of a chat.
 */
private enum newChatPrompt = import("system/new-agent-chat.txt");

/// How an agent uses the API, with the API's URL left to fill in.
private enum agentHelpTemplate = import("agent-help.txt");

/**
 * How an agent uses the API. Given to an agent at the start of every
 * interaction, and served to agents at /agent-help.txt, so it is written to
 * make sense on its own.
 */
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

/**
 * The part of a system prompt that every interaction with an agent starts
 * with, whatever the interaction is: who the agent is, its own instructions,
 * and the API help.
 */
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

        const conditions = [
            "labels": agent.labels.length > 0,
            "instructions": agent.instructions.strip.length > 0
        ];

        return parser.parse(agentPromptTemplate, placeholders, conditions)
            .strip
            ~ "\n\n" ~ interactionPrompt.strip;
    }
}

/// A person's chats with agents.
interface IAgentChat
{
    /**
     * Sends the person's message to an agent, in a chat that is going on or as
     * the start of a new one, and waits for its answer.
     *
     * Params:
     *   agent = The agent to chat with.
     *   project = The project the chat started in, or null when it started in
     *     none. Only told to the agent when the chat starts, but its working
     *     directory is opened to the agent with every message.
     *   message = What the person wrote.
     *   sessionId = The chat's session, or null to start a new chat, whose
     *     session it is set to.
     *
     * Returns: The agent's answer.
     *
     * Throws: `RunStoppedException` when the chat was ended while the agent was
     *   answering, and `Exception` when the agent has no session `sessionId`, its
     *   runtime is not one this server provides, or the runtime fails.
     */
    public string send(Agent agent, Nullable!Project project, string message, ref string sessionId);

    /**
     * Ends a chat, which can then no longer be continued. An answer the agent is
     * still giving is stopped. A chat that has ended already is passed over.
     *
     * Params:
     *   agentId = The agent the chat is with, which may have been deleted.
     *   sessionId = The chat's session.
     */
    public void end(UUID agentId, UUID sessionId) nothrow;

    /// Ends every chat with an agent, such as once it is deleted, including those no page knows of any more.
    public void endAll(UUID agentId) nothrow;
}

/**
 * Passes a person's chat messages on to an agent. A chat is a session on the
 * agent's runtime, started with the agent prompt and the new-chat prompt as its
 * system prompt, which tell the agent who it is and where the person is. Every
 * message goes as it is.
 *
 * A chat in a project runs in its scratch space with the project's working
 * directory open to it, rather than in the working directory, since a session
 * is continued in the directory it started in, and the working directory moves
 * when the project's slug changes. The scratch space stays until the chat is
 * ended; one whose page was closed without ending it is left to the OS, which
 * clears the temp directory it is in.
 */
class AgentChat : IAgentChat
{
    private RuntimeExecutor executor;
    private PromptParser parser;
    private AgentPrompt agentPrompt;
    private ProjectWorkingDirs workingDirs;
    /**
     * The messages the agents are answering now. The requests all run on one thread, so no lock
     * is needed.
     */
    private ChatRun[] runs;

    this(RuntimeExecutor executor, PromptParser parser, AgentPrompt agentPrompt, ProjectWorkingDirs workingDirs)
    {
        this.executor = executor;
        this.parser = parser;
        this.agentPrompt = agentPrompt;
        this.workingDirs = workingDirs;
    }

    public string send(Agent agent, Nullable!Project project, string message, ref string sessionId)
    {
        auto run = new ChatRun(agent.id, sessionId);
        runs ~= run;
        // A chat ended while its agent was answering keeps its scratch space until the agent has
        // stopped, so that it is not removed from under the agent.
        scope (exit)
        {
            runs = runs.filter!(going => going !is run).array;
            if (run.ended)
            {
                removeAgentScratchSpace(agent.id, run.endedSession);
            }
        }

        auto workingDir = project.isNull ? null : workingDirs.ensure(project.get.workingDir);
        if (sessionId !is null)
        {
            return executor.prompt(agent.id.toString, message, true, sessionId, null, workingDir, null,
                RunIn.scratchSpace, run.stop);
        }

        string[string] placeholders = ["<working dir>": workingDir];
        if (!project.isNull)
        {
            placeholders["<project name>"] = project.get.name;
            placeholders["<project id>"] = project.get.id.toString;
            placeholders["<project description>"] = project.get.description.strip;
        }

        const conditions = [
            "project": !project.isNull,
            "description": !project.isNull && project.get.description.strip.length > 0,
            "working-dir": workingDir !is null
        ];

        auto chatPrompt = parser.parse(newChatPrompt, placeholders, conditions);

        return executor.prompt(agent.id.toString, message, true, sessionId,
            agentPrompt.systemPrompt(agent, chatPrompt), workingDir, null, RunIn.scratchSpace, run.stop);
    }

    public void end(UUID agentId, UUID sessionId) nothrow
    {
        auto session = sessionId.toString;
        foreach (run; runs)
        {
            if (run.agentId == agentId && run.sessionId == session)
            {
                run.ended = true;
                run.endedSession = sessionId;
                run.stop.request();
                return;
            }
        }

        removeAgentScratchSpace(agentId, sessionId);
    }

    public void endAll(UUID agentId) nothrow
    {
        // A chat's first message has no session yet, and when it is stopped the runtime removes the
        // scratch space it made for it.
        foreach (run; runs)
        {
            if (run.agentId == agentId)
            {
                run.stop.request();
            }
        }

        removeAgentScratchSpaces(agentId);
    }
}

/// A chat message an agent is answering.
private class ChatRun
{
    UUID agentId;
    /// The chat's session, or null for the message that starts it, whose session is not known yet.
    string sessionId;
    RunStop stop;
    /// Whether the chat was ended while the message was answered, and its session if it was.
    bool ended;
    UUID endedSession;

    this(UUID agentId, string sessionId)
    {
        this.agentId = agentId;
        this.sessionId = sessionId;
        stop = new RunStop;
    }
}

/// Why a task's run was stopped.
private enum StopReason
{
    taskDeleted,
    agentsPaused,
    agentDisabled,
    agentDeleted
}

/**
 * A run of the task scheduler or an agent on a task, while it is going, with what the loop that
 * started it checks it against each round.
 */
private class TaskRun
{
    RunStop stop;
    /// The agent at work on the task, or for the task scheduler, the scheduler, once it is chosen.
    Nullable!UUID agentId;
    /// Kept for the note, since an agent that was deleted can no longer be looked up.
    string agentName;
    /// The working directory the agent works on, or null for none.
    string workingDir;
    /// Why the run was stopped, once it was.
    Nullable!StopReason reason;

    this()
    {
        stop = new RunStop;
    }

    this(UUID agentId, string agentName)
    {
        this();
        this.agentId = agentId;
        this.agentName = agentName;
    }
}

/**
 * Stops the runs that are no longer wanted: those whose task is gone, whose project's agents are
 * paused, or whose agent is disabled or gone. Each one's reason is kept on it, for whoever handles
 * its end.
 */
private void stopUnwantedRuns(TaskRun[UUID] runs, ITaskRepository tasks, IAgentRepository agents)
{
    auto going = runs.byKeyValue.filter!(entry => entry.value.reason.isNull).map!(entry => entry.key).array;
    if (going.length == 0)
    {
        return;
    }

    auto atWork = tasks.agentsAtWork(going);
    Agent[UUID] byId;
    foreach (agent; agents.all())
    {
        byId[agent.id] = agent;
    }

    foreach (taskId; going)
    {
        auto run = runs[taskId];
        auto reason = stopReason(taskId in atWork, run.agentId, byId);
        if (reason.isNull)
        {
            continue;
        }

        run.reason = reason;
        logInfo("The run on task %s is stopped, since %s.", taskId, stopCause(run));
        run.stop.request();
    }
}

/**
 * Why a run is no longer wanted, or an empty Nullable when it still is. `atWork` is whether its
 * task's project's agents are at work, or null when the task is gone.
 */
private Nullable!StopReason stopReason(const bool* atWork, Nullable!UUID agentId, Agent[UUID] agents)
{
    if (atWork is null)
    {
        return StopReason.taskDeleted.nullable;
    }

    if (!*atWork)
    {
        return StopReason.agentsPaused.nullable;
    }

    if (agentId.isNull)
    {
        return Nullable!StopReason.init;
    }

    auto agent = agentId.get in agents;
    if (agent is null)
    {
        return StopReason.agentDeleted.nullable;
    }

    return agent.enabled ? Nullable!StopReason.init : StopReason.agentDisabled.nullable;
}

/// Why a run was stopped, to follow "since".
private string stopCause(TaskRun run)
{
    final switch (run.reason.get)
    {
    case StopReason.taskDeleted:
        return "the task was deleted";
    case StopReason.agentsPaused:
        return "the project's agents were paused";
    case StopReason.agentDisabled:
        return format(`"%s" was disabled`, run.agentName);
    case StopReason.agentDeleted:
        return format(`"%s" was deleted`, run.agentName);
    }
}

/**
 * Why a run was stopped, as its task's notes say it. An agent's run may have changed files
 * halfway, which the next agent on the task is told, since nothing is undone.
 */
private string stopNote(TaskRun run)
{
    auto note = "Stopped, since " ~ stopCause(run);
    return run.workingDir is null ? note : note ~ "; it may have left changes in the working directory";
}

/// How long the task scheduler waits between one look at the tasks and the next.
private enum schedulerInterval = 5.seconds;

/**
 * Decides the next step of the tasks in the lanes the AI agents pick up, from a loop that
 * keeps running in the background: each task to be scheduled, with no agent and outside a done
 * lane, whether new or just worked on, is moved on to the lane the task scheduler agent chooses
 * for it and assigned the agent it chooses, closed in a done lane when the scheduler finds it
 * finished, or declined when there is no agent for it.
 */
class TaskScheduler
{
    private IAgentRepository agents;
    private ITaskRepository tasks;
    private ILaneRepository lanes;
    private IProjectRepository projects;
    private PromptParser parser;
    private AgentPrompt agentPrompt;
    private RuntimeExecutor executor;
    private IEventPublisher events;
    private IndexPages indexPages;
    private ITransactional transactions;
    /// How many tasks are being scheduled now. The tasks all run on one thread, so no lock is needed.
    private int running;
    /// The runs scheduling a task, by the task's id.
    private TaskRun[UUID] runs;

    this(IAgentRepository agents, ITaskRepository tasks, ILaneRepository lanes, IProjectRepository projects,
        PromptParser parser, AgentPrompt agentPrompt, RuntimeExecutor executor, IEventPublisher events,
        IndexPages indexPages, ITransactional transactions)
    {
        this.agents = agents;
        this.tasks = tasks;
        this.lanes = lanes;
        this.projects = projects;
        this.parser = parser;
        this.agentPrompt = agentPrompt;
        this.executor = executor;
        this.events = events;
        this.indexPages = indexPages;
        this.transactions = transactions;
    }

    /**
     * Runs the loop. It never returns, so a caller should run it in a task of its own.
     *
     * Throws: `Exception` when the loop fails.
     */
    void run()
    {
        // A task left being scheduled was being scheduled when the server last stopped, and
        // nothing else will pick it up again.
        try
        {
            const released = tasks.changeAgentStatuses(AgentStatus.scheduling, AgentStatus
                    .toBeScheduled);
            if (released > 0)
            {
                logInfo("The task scheduler put %s tasks it was scheduling back to be scheduled.", released);
            }
        }
        catch (Exception e)
        {
            logError("The task scheduler failed to put the tasks it was scheduling back to be scheduled: %s", e
                    .msg);
        }

        while (true)
        {
            // A database that is down fails one round, not the loop.
            try
            {
                stopUnwantedRuns(runs, tasks, agents);
            }
            catch (Exception e)
            {
                logError("The task scheduler failed to check the tasks it is scheduling: %s", e.msg);
            }

            try
            {
                assignWaitingTasks();
            }
            catch (Exception e)
            {
                logError("The task scheduler failed to assign tasks: %s", e.msg);
            }

            // Yields to the other tasks on the event loop, which a loop that never waited would starve.
            sleep(schedulerInterval);
        }
    }

    /**
     * Starts scheduling the tasks waiting for an agent, each in a task of its own, as many at
     * once as the scheduler agent may work on. A task is claimed first, by its status, so that
     * no other scheduler takes it up as well. What does not fit is left for a later round.
     */
    private void assignWaitingTasks()
    {
        auto waiting = tasks.awaitingScheduling();
        if (waiting.length == 0)
        {
            return;
        }

        const limit = schedulingLimit();
        foreach (task; waiting)
        {
            if (!limit.isNull && running >= limit.get)
            {
                return;
            }

            // Another scheduler claimed it since the tasks were read.
            if (!tasks.changeAgentStatus(task.id, AgentStatus.toBeScheduled, AgentStatus.scheduling))
            {
                continue;
            }

            running++;
            runs[task.id] = new TaskRun;
            // Passed as an argument rather than captured, since a closure in a loop shares one
            // variable across all its iterations.
            runTask(&scheduleClaimed, task);
        }
    }

    /**
     * How many tasks may be scheduled at once: the scheduler agent's limit, or none when there
     * is no enabled scheduler agent, since each task is then declined straight away.
     */
    private Nullable!int schedulingLimit()
    {
        auto schedulers = agents.all().filter!(agent => isActiveScheduler(agent));
        if (schedulers.empty)
        {
            return Nullable!int.init;
        }

        return schedulers.front.maxParallelTasks;
    }

    /**
     * Schedules a task claimed for scheduling, and marks it scheduled, done or declined. A task
     * that gets no agent is declined, so that it is not asked about every round, which would
     * cost an agent call and add a note each time.
     */
    private void scheduleClaimed(Task task) nothrow
    {
        auto run = runs[task.id];
        scope (exit)
        {
            running--;
            runs.remove(task.id);
        }

        try
        {
            statusChanged(tasks, events, task.id);
            const status = assign(task, run);
            if (tasks.changeAgentStatus(task.id, AgentStatus.scheduling, status))
            {
                statusChanged(tasks, events, task.id);
            }
        }
        catch (RunStoppedException e)
        {
            // Whatever it was stopped for, the task is to be scheduled again once that has passed.
            endStoppedRun(tasks, events, task.id, run, AgentStatus.scheduling, AgentStatus.toBeScheduled,
                false);
        }
        catch (Exception e)
        {
            logError("Scheduling task %s failed: %s", task.id, e.msg);
            // Left to be scheduled again, since it failed for some other reason than the agent. A
            // database that is down fails this too, and then the next start puts it back.
            try
            {
                if (tasks.changeAgentStatus(task.id, AgentStatus.scheduling, AgentStatus.toBeScheduled))
                {
                    statusChanged(tasks, events, task.id);
                }
            }
            catch (Exception resetError)
            {
                logError("Task %s could not be put back to be scheduled: %s", task.id, resetError
                        .msg);
            }
        }
    }

    /**
     * Has the scheduler agent choose the task's next step, from its notes: an agent for it and
     * the lane it moves to as that agent starts on it, or a done lane that closes it. Then moves
     * the task, and assigns the agent. Waits on the agent, which takes a while.
     *
     * Returns: The task's agent status from here: scheduled when it was assigned to an agent,
     *   done when it was closed, and declined otherwise.
     *
     * Throws: `RunStoppedException` when the run was stopped while the scheduler was at it.
     */
    private AgentStatus assign(Task task, TaskRun run)
    {
        // The lane or its project may be gone since the tasks were read.
        auto lane = lanes.find(task.laneId);
        if (lane.isNull)
        {
            return AgentStatus.declined;
        }

        auto project = projects.find(lane.get.projectId);
        if (project.isNull)
        {
            return AgentStatus.declined;
        }

        auto all = agents.all();
        auto schedulers = all.filter!(agent => isActiveScheduler(agent));
        if (schedulers.empty)
        {
            logInfo("Task %s is not assigned, since there is no enabled task scheduler agent.", task.id);
            noted(tasks.recordNoScheduler(task.id), task.id, project.get.id);
            return AgentStatus.declined;
        }

        auto board = lanes.ofProject(project.get.id);
        auto notes = tasks.notes(task.id);
        string[string] placeholders = [
            "<project name>": project.get.name,
            "<project id>": project.get.id.toString,
            "<project description>": project.get.description.strip,
            "<lane name>": lane.get.name,
            "<task description>": task.description.strip,
            "<note list>": noteList(notes),
            "<agent list>": agentList(all),
            "<lane list>": laneList(board)
        ];

        const conditions = [
            "notes": notes.length > 0,
            "project-description": project.get.description.strip.length > 0
        ];

        auto scheduler = schedulers.front;
        run.agentId = scheduler.id;
        run.agentName = scheduler.name;
        auto prompt = parser.parse(schedulePrompt, placeholders, conditions);
        auto systemPrompt = agentPrompt.systemPrompt(scheduler, "").strip;

        // Caught here rather than by the caller, so the log says which scheduler failed.
        string answer;
        try
        {
            string noSession;
            answer = executor.prompt(scheduler.id.toString, prompt, false, noSession, systemPrompt, null, null,
                RunIn.workingDir, run.stop).strip;
        }
        catch (RunStoppedException e)
        {
            throw e;
        }
        catch (Exception e)
        {
            logError("Scheduler %s failed on task %s: %s", scheduler.name, task.id, e.msg);
            noted(tasks.recordSchedulingFailure(task.id, scheduler.id), task.id, project.get.id);
            return AgentStatus.declined;
        }

        auto schedule = readSchedule(answer, all, board);
        if (schedule.isNull)
        {
            logError("Scheduler %s answered task %s with \"%s\", which is not a next step it could choose.",
                scheduler.name, task.id, answer);
            noted(tasks.recordSchedulingFailure(task.id, scheduler.id), task.id, project.get.id);
            return AgentStatus.declined;
        }

        if (schedule.get.laneId.isNull)
        {
            noted(tasks.recordNoAgentFound(task.id, scheduler.id), task.id, project.get.id);
            return AgentStatus.declined;
        }

        moveOn(task.id, lane.get.id, schedule.get.laneId.get, project.get.id);
        if (schedule.get.agentId.isNull)
        {
            return AgentStatus.done;
        }

        noted(tasks.assignAiAgent(task.id, schedule.get.agentId), task.id, project.get.id);
        return AgentStatus.scheduled;
    }

    /**
     * Moves the task to the bottom of the lane the scheduler chose. A task that left its lane
     * while the agent was at work was moved by someone else, whose move is kept. The lane it goes
     * to and the task are locked, in that order, as a move locks them, so that no move comes
     * between the look at its lane and this move.
     */
    private void moveOn(UUID taskId, UUID fromLaneId, UUID toLaneId, UUID projectId)
    {
        if (toLaneId == fromLaneId)
        {
            return;
        }

        transactions.run({
            if (!lanes.lock(toLaneId) || !tasks.lock(taskId) || tasks.find(taskId).get.laneId != fromLaneId)
            {
                return false;
            }

            tasks.move(taskId, toLaneId, UUID.init);
            events.task(Event.moved, taskId, projectId, fromLaneId, toLaneId);
            transactions.afterCommit(() => indexPages.check(projectId));
            return true;
        });
    }

    /// Reports a note on the task, when one was added.
    private void noted(bool added, UUID taskId, UUID projectId)
    {
        if (added)
        {
            events.note(taskId, projectId);
        }
    }
}

/// How long the task executor waits between one look at the tasks and the next.
private enum executorInterval = 5.seconds;

/**
 * Has the agents work on the tasks assigned to them, from a loop that keeps running in the
 * background: each scheduled task outside a done lane, in a lane the agents pick up, is worked on
 * by its agent, with the agent's result in its notes. A task its agent has answered is handed
 * back to the task scheduler, which decides its next step from that result, and one whose agent
 * could not answer is failed.
 */
class TaskExecutor
{
    private IAgentRepository agents;
    private ITaskRepository tasks;
    private ILaneRepository lanes;
    private IProjectRepository projects;
    private PromptParser parser;
    private AgentPrompt agentPrompt;
    private RuntimeExecutor executor;
    private IEventPublisher events;
    private ProjectWorkingDirs workingDirs;
    /**
     * How many tasks each agent is working on now, by the agent's id. The tasks all run on one
     * thread, so no lock is needed.
     */
    private int[UUID] running;
    /// The runs working on a task, by the task's id.
    private TaskRun[UUID] runs;

    this(IAgentRepository agents, ITaskRepository tasks, ILaneRepository lanes, IProjectRepository projects,
        PromptParser parser, AgentPrompt agentPrompt, RuntimeExecutor executor, IEventPublisher events,
        ProjectWorkingDirs workingDirs)
    {
        this.agents = agents;
        this.tasks = tasks;
        this.lanes = lanes;
        this.projects = projects;
        this.parser = parser;
        this.agentPrompt = agentPrompt;
        this.executor = executor;
        this.events = events;
        this.workingDirs = workingDirs;
    }

    /**
     * Runs the loop. It never returns, so a caller should run it in a task of its own.
     *
     * Throws: `Exception` when the loop fails.
     */
    void run()
    {
        // A task left being worked on was being worked on when the server last stopped, and
        // nothing else will pick it up again. Its agent starts on it afresh, with its notes.
        try
        {
            const released = tasks.changeAgentStatuses(AgentStatus.executing, AgentStatus.scheduled);
            if (released > 0)
            {
                logInfo("The task executor put %s tasks its agents were working on back to scheduled.", released);
            }
        }
        catch (Exception e)
        {
            logError("The task executor failed to put the tasks its agents were working on back to scheduled: %s",
                e.msg);
        }

        while (true)
        {
            // A database that is down fails one round, not the loop.
            try
            {
                stopUnwantedRuns(runs, tasks, agents);
            }
            catch (Exception e)
            {
                logError("The task executor failed to check the tasks its agents are working on: %s", e.msg);
            }

            try
            {
                startWaitingTasks();
            }
            catch (Exception e)
            {
                logError("The task executor failed to start on tasks: %s", e.msg);
            }

            // Yields to the other tasks on the event loop, which a loop that never waited would starve.
            sleep(executorInterval);
        }
    }

    /**
     * Starts the agents on the tasks waiting for them, each in a task of its own, with no agent
     * working on more at once than it may. A task is claimed first, by its status, so that no
     * other executor takes it up as well. What does not fit is left for a later round.
     */
    private void startWaitingTasks()
    {
        foreach (task; tasks.awaitingExecution())
        {
            // An agent that is deleted takes its assignments with it, and one that is disabled
            // may not start on them, and then the task needs another, which only the scheduler
            // can give it.
            auto agentId = tasks.assignedAiAgent(task.id);
            auto agent = agentId.isNull ? Nullable!Agent.init : agents.find(agentId.get);
            if (agent.isNull || !agent.get.enabled)
            {
                handBack(task);
                continue;
            }

            const limit = agent.get.maxParallelTasks;
            if (!limit.isNull && running.get(agentId.get, 0) >= limit.get)
            {
                continue;
            }

            // Another executor claimed it since the tasks were read.
            if (!tasks.changeAgentStatus(task.id, AgentStatus.scheduled, AgentStatus.executing))
            {
                continue;
            }

            running[agentId.get] = running.get(agentId.get, 0) + 1;
            runs[task.id] = new TaskRun(agentId.get, agent.get.name);
            // Passed as arguments rather than captured, since a closure in a loop shares one
            // variable across all its iterations.
            runTask(&executeClaimed, task, agentId.get);
        }
    }

    /// Hands a scheduled task whose agent is gone or disabled back to the task scheduler.
    private void handBack(Task task)
    {
        logInfo("Task %s is handed back to the task scheduler, since its agent is gone or disabled.", task.id);
        auto projectId = tasks.projectOfLane(task.laneId);
        if (tasks.reschedule(task.id) && !projectId.isNull)
        {
            events.note(task.id, projectId.get);
        }
    }

    /**
     * Has the agent work on a task claimed for it, and marks the task to be scheduled or failed.
     * A failed task is not taken up again by itself, since trying again every round would cost
     * an agent call and add a note each time.
     */
    private void executeClaimed(Task task, UUID agentId) nothrow
    {
        auto run = runs[task.id];
        scope (exit)
        {
            if (--running[agentId] == 0)
            {
                running.remove(agentId);
            }
            runs.remove(task.id);
        }

        try
        {
            statusChanged(tasks, events, task.id);
            const status = execute(task, agentId, run) ? AgentStatus.toBeScheduled : AgentStatus.failed;
            if (tasks.changeAgentStatus(task.id, AgentStatus.executing, status))
            {
                statusChanged(tasks, events, task.id);
            }
        }
        catch (RunStoppedException e)
        {
            // A paused project's task waits for its agent, while one whose agent is disabled or gone
            // needs another, which only the scheduler can give it.
            if (run.reason.get == StopReason.agentsPaused)
            {
                endStoppedRun(tasks, events, task.id, run, AgentStatus.executing, AgentStatus.scheduled, false);
            }
            else
            {
                endStoppedRun(tasks, events, task.id, run, AgentStatus.executing, AgentStatus.toBeScheduled,
                    true);
            }
        }
        catch (Exception e)
        {
            logError("Working on task %s failed: %s", task.id, e.msg);
            // Left scheduled to try again, since it failed for some other reason than the agent. A
            // database that is down fails this too, and then the next start puts it back.
            try
            {
                if (tasks.changeAgentStatus(task.id, AgentStatus.executing, AgentStatus.scheduled))
                {
                    statusChanged(tasks, events, task.id);
                }
            }
            catch (Exception resetError)
            {
                logError("Task %s could not be put back to scheduled: %s", task.id, resetError.msg);
            }
        }
    }

    /**
     * Has the agent work on the task with the execute prompt, then adds its result to the
     * task's notes and takes the task off it. Waits on the agent, which can take a long while.
     *
     * Returns: Whether the agent answered with a result, rather than failing; a failure is
     *   noted on the task.
     *
     * Throws: `RunStoppedException` when the run was stopped while the agent was at it.
     */
    private bool execute(Task task, UUID agentId, TaskRun run)
    {
        // The lane or its project may be gone since the tasks were read.
        auto lane = lanes.find(task.laneId);
        if (lane.isNull)
        {
            return false;
        }

        auto project = projects.find(lane.get.projectId);
        if (project.isNull)
        {
            return false;
        }

        auto agent = agents.find(agentId);
        if (agent.isNull)
        {
            logInfo("Task %s is not worked on, since its agent is gone.", task.id);
            noted(tasks.addNote(task.id, "Not worked on, since it is assigned to no agent"), task.id,
                project.get.id);
            return false;
        }

        // Made before the prompt, which names them. Caught here, so the task's notes say the
        // agent could not get to work.
        auto workingDir = workingDirs.ensure(project.get.workingDir);
        run.workingDir = workingDir;
        auto runId = randomUUID();
        string scratchSpace;
        try
        {
            scratchSpace = createAgentScratchSpace(agent.get.id, runId);
        }
        catch (Exception e)
        {
            logError("Agent %s could not work on task %s: %s", agent.get.name, task.id, e.msg);
            noted(tasks.recordExecutionFailure(task.id, agent.get.id), task.id, project.get.id);
            return false;
        }
        scope (exit)
        {
            removeAgentScratchSpace(agent.get.id, runId);
        }

        auto board = lanes.ofProject(project.get.id);
        auto notes = tasks.notes(task.id);
        string[string] placeholders = [
            "<project name>": project.get.name,
            "<project id>": project.get.id.toString,
            "<project description>": project.get.description.strip,
            "<task id>": task.id.toString,
            "<lane name>": lane.get.name,
            "<task description>": task.description.strip,
            "<note list>": noteList(notes),
            "<lane list>": laneList(board),
            "<working dir>": workingDir,
            "<scratch space>": scratchSpace
        ];

        const conditions = [
            "notes": notes.length > 0,
            "project-description": project.get.description.strip.length > 0,
            "working-dir": workingDir !is null
        ];

        auto prompt = parser.parse(executeTaskPrompt, placeholders, conditions);
        auto systemPrompt = agentPrompt.systemPrompt(agent.get, "").strip;

        // Caught here rather than by the caller, so the task's notes say the agent failed.
        string answer;
        try
        {
            string noSession;
            answer = executor.prompt(agent.get.id.toString, prompt, false, noSession, systemPrompt, workingDir,
                scratchSpace, RunIn.workingDir, run.stop);
        }
        catch (RunStoppedException e)
        {
            throw e;
        }
        catch (Exception e)
        {
            logError("Agent %s failed on task %s: %s", agent.get.name, task.id, e.msg);
            noted(tasks.recordExecutionFailure(task.id, agent.get.id), task.id, project.get.id);
            return false;
        }

        // The answer is the result as it is, so an empty one is all that can be told from a failure.
        auto result = answer.strip;
        if (result.length == 0)
        {
            logError("Agent %s answered task %s with nothing.", agent.get.name, task.id);
            noted(tasks.recordExecutionFailure(task.id, agent.get.id), task.id, project.get.id);
            return false;
        }

        noted(tasks.addNote(task.id, result), task.id, project.get.id);

        tasks.assignAiAgent(task.id, Nullable!UUID.init);
        return true;
    }

    /// Reports a note on the task, when one was added.
    private void noted(bool added, UUID taskId, UUID projectId)
    {
        if (added)
        {
            events.note(taskId, projectId);
        }
    }
}

/**
 * Asks an agent for a task's next step: which agent should work on it, given the
 * agents there are, and which lane it moves to as that agent starts on it, or
 * the done lane that closes it.
 */
private enum schedulePrompt = import("schedule-task.txt");

/// Asks the agent a task is assigned to to work on it, and what came of it.
private enum executeTaskPrompt = import("execute-task.txt");

/**
 * Reports a change to the task's agent status, which says on its card whether an agent is at work
 * on it. Reported where it is now, since the scheduler may have moved it on meanwhile.
 */
private void statusChanged(ITaskRepository tasks, IEventPublisher events, UUID taskId)
{
    auto task = tasks.find(taskId);
    if (task.isNull)
    {
        return;
    }

    auto projectId = tasks.projectOfLane(task.get.laneId);
    if (!projectId.isNull)
    {
        events.task(Event.changed, taskId, projectId.get, task.get.laneId, task.get.laneId);
    }
}

/**
 * Ends a run that was stopped, by putting its task where its reason says, with a note why. A
 * deleted task gets nothing, and a task changed meanwhile by something else is left as it is.
 */
private void endStoppedRun(ITaskRepository tasks, IEventPublisher events, UUID taskId, TaskRun run,
    AgentStatus from, AgentStatus to, bool unassign) nothrow
{
    if (run.reason.get == StopReason.taskDeleted)
    {
        return;
    }

    try
    {
        if (!tasks.endStoppedRun(taskId, from, to, unassign, stopNote(run)))
        {
            return;
        }

        statusChanged(tasks, events, taskId);
        auto task = tasks.find(taskId);
        auto projectId = task.isNull ? Nullable!UUID.init : tasks.projectOfLane(task.get.laneId);
        if (!projectId.isNull)
        {
            events.note(taskId, projectId.get);
        }
    }
    catch (Exception e)
    {
        logError("The stopped run on task %s could not be ended: %s", taskId, e.msg);
    }
}

/**
 * A lane per line, with "done" after the lanes whose tasks count as done and "no agents" after
 * those the agents do not pick up.
 */
private string laneList(Lane[] board)
{
    return board.map!(lane => format("- ID %s: %s%s%s", lane.id, lane.name, lane.marksDone ? " (done)" : "",
            lane.agentsPickUp ? "" : " (no agents)"))
        .join("\n");
}

/**
 * A note per line, oldest first, since the agent reads them as the task's
 * history.
 */
private string noteList(TaskNote[] notes)
{
    return notes.retro
        .map!(note => format("- %s: %s", (cast(DateTime) note.insertedAt)
                .toISOExtString, note.note))
        .join("\n");
}

/// Whether the agent schedules tasks: a task scheduler that is enabled.
private bool isActiveScheduler(Agent agent)
{
    return agent.taskScheduler && agent.enabled;
}

/// Whether the agent can be given a task: one that is enabled and not a task scheduler.
private bool isAssignable(Agent agent)
{
    return !agent.taskScheduler && agent.enabled;
}

/**
 * One block per agent that can be given a task, set apart by tags since an
 * agent's instructions run over several lines. Schedulers are left out,
 * since they hand out tasks rather than work on them, and so are disabled
 * agents.
 */
private string agentList(Agent[] all)
{
    return all
        .filter!(agent => isAssignable(agent))
        .map!(agent => describeAssignable(agent))
        .join("\n\n");
}

/**
 * An agent as the scheduler sees it. Labels are always given, as "none" when
 * there are none, while instructions are left out when there are none.
 */
private string describeAssignable(Agent agent)
{
    auto labels = agent.labels.length == 0 ? "none" : agent.labels.join(", ");
    auto instructions = agent.instructions.strip;

    return format("<agent>\nID: %s\nName: %s\nLabels: %s\n%s</agent>", agent.id, agent.name, labels,
        instructions.length == 0 ? "" : "Instructions:\n" ~ instructions ~ "\n");
}

/**
 * What the scheduler chose for a task: an agent and the lane the task moves
 * to, a done lane with no agent when it is closed, or neither when it is left
 * where it is.
 */
private struct Schedule
{
    Nullable!UUID agentId;
    Nullable!UUID laneId;
}

/**
 * Reads the scheduler's answer to the schedule prompt.
 *
 * Params:
 *   answer = The scheduler's answer, a JSON object with an `agent-id` and a
 *     `next-lane-id`, either of which may be null.
 *   all = Every agent, of which only the enabled ones that are not task
 *     schedulers can be chosen.
 *   board = The lanes of the task's project, the only ones it can move to.
 *
 * Returns: The schedule, or an empty Nullable when the answer names an agent
 *   or a lane that cannot be chosen, pairs an agent with a done lane, a lane the
 *   agents do not pick up or no lane, closes the task in a lane that is not done,
 *   or is not such an object at all.
 */
private Nullable!Schedule readSchedule(string answer, Agent[] all, Lane[] board)
{
    auto json = answerObject(answer);
    if (json.isNull)
    {
        return Nullable!Schedule.init;
    }

    auto agentId = "agent-id" in json.get;
    auto laneId = "next-lane-id" in json.get;
    if (agentId is null || laneId is null || !agentId.type.among(Json.Type.string, Json.Type.null_)
        || !laneId.type.among(Json.Type.string, Json.Type.null_))
    {
        return Nullable!Schedule.init;
    }

    if (agentId.type == Json.Type.null_ && laneId.type == Json.Type.null_)
    {
        return Schedule().nullable;
    }

    if (laneId.type == Json.Type.null_)
    {
        return Nullable!Schedule.init;
    }

    // IDs are compared as text, since an agent may change their case.
    auto lanes = board.find!(lane => lane.id.toString == laneId.get!string.strip.toLower);
    if (lanes.length == 0)
    {
        return Nullable!Schedule.init;
    }

    // An agent is only started on a task outside a done lane, in a lane the agents pick up, so a
    // done lane closes the task and is the only one it can be moved to without an agent.
    if (agentId.type == Json.Type.null_)
    {
        return lanes[0].marksDone ? Schedule(Nullable!UUID.init, lanes[0].id.nullable).nullable
            : Nullable!Schedule.init;
    }

    auto agents = all.find!(agent => isAssignable(agent) && agent.id.toString == agentId
            .get!string.strip
            .toLower);
    if (agents.length == 0 || lanes[0].marksDone || !lanes[0].agentsPickUp)
    {
        return Nullable!Schedule.init;
    }

    return Schedule(agents[0].id.nullable, lanes[0].id.nullable).nullable;
}

unittest
{
    import std.string : toUpper;

    auto writer = new Agent(randomUUID, "Writer", "claude-code", "sonnet", "default", false, "", [
        ]);
    auto scheduler = new Agent(randomUUID, "Scheduler", "claude-code", "sonnet", "default", true, "", [
        ]);
    auto resting = new Agent(randomUUID, "Resting", "claude-code", "sonnet", "default", false, "", [
        ], Nullable!int.init, false);
    auto doing = new Lane(randomUUID, randomUUID, "Doing", 1, "#000000", false, false, true);
    auto done = new Lane(randomUUID, randomUUID, "Done", 2, "#000000", true, false, true);
    auto manual = new Lane(randomUUID, randomUUID, "Manual", 3, "#000000", false);
    auto all = [writer, scheduler, resting];
    auto board = [doing, done, manual];

    auto chosen = readSchedule(format("```json\n{\"agent-id\": \"%s\", \"next-lane-id\": \" %s \"}\n```",
            writer.id.toString.toUpper, doing.id), all, board);
    assert(!chosen.isNull);
    assert(chosen.get.agentId.get == writer.id && chosen.get.laneId.get == doing.id);

    auto none = readSchedule(`{"agent-id": null, "next-lane-id": null}`, all, board);
    assert(!none.isNull && none.get.agentId.isNull && none.get.laneId.isNull);

    auto closed = readSchedule(format(`{"agent-id": null, "next-lane-id": "%s"}`, done.id), all, board);
    assert(!closed.isNull && closed.get.agentId.isNull && closed.get.laneId.get == done.id);

    assert(readSchedule(format(`{"agent-id": null, "next-lane-id": "%s"}`, doing.id), all, board).isNull);
    assert(readSchedule(format(`{"agent-id": "%s", "next-lane-id": "%s"}`, writer.id, done.id), all, board)
            .isNull);
    assert(readSchedule(format(`{"agent-id": "%s", "next-lane-id": null}`, writer.id), all, board).isNull);
    assert(readSchedule(format(`{"agent-id": "%s", "next-lane-id": "%s"}`, writer.id, manual.id), all, board)
            .isNull);
    assert(laneList(board).canFind("Manual (no agents)") && !laneList(board).canFind("Doing (no agents)"));

    assert(readSchedule(format(`{"agent-id": "%s", "next-lane-id": "%s"}`, scheduler.id, doing.id), all, board)
            .isNull);
    assert(readSchedule(format(`{"agent-id": "%s", "next-lane-id": "%s"}`, resting.id, doing.id), all, board)
            .isNull);
    assert(!agentList(all).canFind(resting.id.toString));
    assert(readSchedule(format(`{"agent-id": "%s", "next-lane-id": "%s"}`, writer.id, randomUUID), all, board)
            .isNull);
    assert(readSchedule(format(`{"agent-id": "%s"}`, writer.id), all, board).isNull);
    assert(readSchedule(writer.id.toString, all, board).isNull);
}

/// Asks an agent to draft a new agent from a person's description of it.
private enum quickCreatePrompt = import("quick-create-agent.txt");

/**
 * Drafts a new agent from a person's description of it, for the person to
 * review in the new agent dialog before anything is created. Any agent can
 * draft one, so the one named Generic is asked first, as the chat offers it
 * first, and then each task scheduler, since there is always meant to be one.
 */
class AgentDrafter
{
    private IAgentRepository agents;
    private IRuntimeRepository runtimes;
    private IDefaultRepository defaults;
    private PromptParser parser;
    private AgentPrompt agentPrompt;
    private RuntimeExecutor executor;

    this(IAgentRepository agents, IRuntimeRepository runtimes, IDefaultRepository defaults, PromptParser parser,
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
            return draftError(
                "There is no agent to draft one with. Add an agent named Generic, or a task scheduler.");
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
        auto prompt = parser.parse(quickCreatePrompt, placeholders, [
                "agents": all.length > 0
            ]);

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
        return format("- %s (labels: %s)", agent.name, agent.labels.length == 0 ? "none" : agent.labels.join(
                ", "));
    }
}

/**
 * Whether the agent is the one named Generic, found by name, as the chat finds
 * it, since it is an ordinary agent with nothing else to tell it by.
 */
private bool isGeneric(Agent agent)
{
    return agent.name.toLower == "generic";
}

private Json draftError(string message)
{
    auto error = Json.emptyObject;
    error["error"] = message;

    return error;
}

/**
 * The JSON object in an agent's answer, or an empty Nullable when there is
 * none. Agents are asked for a bare JSON object but often wrap it in a code
 * fence or a sentence, so the object is taken from between the first `{` and
 * the last `}`.
 */
private Nullable!Json answerObject(string answer)
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

    return json.type == Json.Type.object ? json.nullable : Nullable!Json.init;
}

/**
 * Reads an agent's answer to the quick-create prompt, as `answerObject` finds
 * it. A runtime, model and effort level that do not go together are
 * replaced by the defaults, and the labels are made lowercase and unique, so
 * the dialog shows only what it could save. Whatever else is in the object
 * is dropped.
 *
 * Returns: The draft, or an error object when the agent answered with one, or
 *   an empty Nullable when the answer is neither.
 */
private Nullable!Json readDraft(string answer, Model[] models, string[string] defaultIds)
{
    auto parsed = answerObject(answer);
    if (parsed.isNull)
    {
        return Nullable!Json.init;
    }

    auto json = parsed.get;

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
    draft["taskScheduler"] = scheduler !is null && scheduler.type == Json.Type.bool_ && scheduler
        .get!bool;

    return draft.nullable;
}

unittest
{
    auto models = [
        new Model("sonnet", "Claude Sonnet", "claude-code", [
                new EffortLevel("default", "Default"),
                new EffortLevel("high", "High")
            ])
    ];
    auto defaultIds = [
        "runtime": "claude-code", "model": "sonnet", "effort": "default"
    ];

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

/// Asks an agent to suggest a new project from a person's description of it.
private enum quickCreateProjectPrompt = import("quick-create-project.txt");

/**
 * The colours a suggested lane can be given, with what each looks like, for the
 * agent to choose by. Mirrors standardColors in tv-project-settings.js.
 */
private enum string[2][] laneColors = [
    ["#8fa6ff", "blue"],
    ["#e8b154", "amber"],
    ["#5fd6ab", "green"],
    ["#f2836b", "coral"],
    ["#c79bf0", "lilac"],
    ["#8a929e", "grey"],
    ["#6fc7e8", "sky blue"]
];

/**
 * Drafts a new project from a person's description of it, for the person to
 * review on the new project screen before anything is created: the project
 * prompt's "Set up project", shown at first run. As with `AgentDrafter`, the agent named Generic
 * is asked first, and then each task scheduler.
 */
class ProjectDrafter
{
    private IAgentRepository agents;
    private IProjectRepository projects;
    private PromptParser parser;
    private AgentPrompt agentPrompt;
    private RuntimeExecutor executor;

    this(IAgentRepository agents, IProjectRepository projects, PromptParser parser, AgentPrompt agentPrompt,
        RuntimeExecutor executor)
    {
        this.agents = agents;
        this.projects = projects;
        this.parser = parser;
        this.agentPrompt = agentPrompt;
        this.executor = executor;
    }

    /**
     * Has an agent draft a new project from the description. An agent that
     * fails to answer, or answers with something that is not a draft, is
     * passed over for the next.
     *
     * Params:
     *   description = What the person wrote they are working on.
     *
     * Returns: The draft, as an object with the fields of the new project
     *   screen, or one with only an `error`, a message for the person, when the
     *   agent found the description too vague or no agent could draft one.
     */
    public Json draft(string description)
    {
        auto all = agents.all();
        auto drafters = all.filter!(agent => isGeneric(agent))
            .chain(all.filter!(agent => agent.taskScheduler && !isGeneric(agent)))
            .array;
        if (drafters.length == 0)
        {
            return draftError("There is no agent to suggest one with. Add an agent named Generic, or a task "
                    ~ "scheduler, or set the project up manually.");
        }

        auto existing = projects.all();
        string[string] placeholders = [
            "<project request>": description.strip,
            "<project list>": existing.map!(project => "- " ~ project.name).join("\n"),
            "<color list>": laneColors.map!(color => format("- %s (%s)", color[0], color[1])).join("\n")
        ];
        auto prompt = parser.parse(quickCreateProjectPrompt, placeholders, [
                "projects": existing.length > 0
            ]);

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
                logError("Agent %s could not draft a project: %s", drafter.name, exception.msg);
                continue;
            }

            auto draft = readProjectDraft(answer);
            if (draft.isNull)
            {
                logError("Agent %s answered a request to draft a project with \"%s\", which is not a draft.",
                    drafter.name, answer);
                continue;
            }

            return draft.get;
        }

        return draftError("No agent could suggest one. The server's log says why.");
    }
}

/**
 * Reads an agent's answer to the quick-create project prompt, as `answerObject`
 * finds it. A lane without a name is dropped, a colour that is not one of
 * `laneColors` is replaced by one of them, and a lane flag that is not true is
 * false, so the screen shows only what it could save. Whatever else is in the
 * object is dropped.
 *
 * Returns: The draft, or an error object when the agent answered with one, or
 *   an empty Nullable when the answer is neither, or has no lanes.
 */
private Nullable!Json readProjectDraft(string answer)
{
    auto parsed = answerObject(answer);
    if (parsed.isNull)
    {
        return Nullable!Json.init;
    }

    auto json = parsed.get;

    string text(Json object, string key)
    {
        auto value = key in object;
        return value !is null && value.type == Json.Type.string ? value.get!string.strip : "";
    }

    bool flag(Json object, string key)
    {
        auto value = key in object;
        return value !is null && value.type == Json.Type.bool_ && value.get!bool;
    }

    if (text(json, "error").length > 0)
    {
        return draftError(text(json, "error")).nullable;
    }

    if (text(json, "name").length == 0)
    {
        return Nullable!Json.init;
    }

    Json[] lanes;
    if (auto list = "lanes" in json)
    {
        if (list.type == Json.Type.array)
        {
            foreach (item; *list)
            {
                if (item.type != Json.Type.object || text(item, "name").length == 0)
                {
                    continue;
                }

                auto color = text(item, "color").toLower;
                if (!laneColors.canFind!(standard => standard[0] == color))
                {
                    color = laneColors[lanes.length % laneColors.length][0];
                }

                auto lane = Json.emptyObject;
                lane["name"] = text(item, "name");
                lane["color"] = color;
                lane["marksDone"] = flag(item, "marksDone");
                lane["acceptsNewTasks"] = flag(item, "acceptsNewTasks");
                lane["agentsPickUp"] = flag(item, "agentsPickUp");
                lanes ~= lane;
            }
        }
    }

    if (lanes.length == 0)
    {
        return Nullable!Json.init;
    }

    auto draft = Json.emptyObject;
    draft["name"] = text(json, "name");
    draft["description"] = text(json, "description");
    draft["lanes"] = Json(lanes);

    return draft.nullable;
}

unittest
{
    auto fenced = readProjectDraft("Here it is:\n```json\n{\"name\": \" Site Relaunch \", \"description\": \"New site.\","
            ~ " \"lanes\": [{\"name\": \"To do\", \"color\": \"#8FA6FF\", \"acceptsNewTasks\": true, \"agentsPickUp\": true},"
            ~ " {\"name\": \" \", \"color\": \"#e8b154\"}, {\"name\": \"Doing\", \"color\": \"#123456\","
            ~ " \"agentsPickUp\": \"yes\"}, 3, {\"name\": \"Done\", \"color\": \"#5fd6ab\", \"marksDone\": true}],"
            ~ " \"taskAddRule\": \"any_lane\", \"managedByAi\": true, \"extra\": 1}\n```");
    assert(!fenced.isNull);
    auto draft = fenced.get;
    assert(draft["name"].get!string == "Site Relaunch");
    assert(draft["description"].get!string == "New site.");
    assert("extra" !in draft && "taskAddRule" !in draft && "managedByAi" !in draft);
    assert(draft["lanes"].length == 3);
    assert(draft["lanes"][0]["color"].get!string == "#8fa6ff");
    assert(!draft["lanes"][0]["marksDone"].get!bool);
    assert(draft["lanes"][0]["acceptsNewTasks"].get!bool && draft["lanes"][0]["agentsPickUp"].get!bool);
    assert(draft["lanes"][1]["name"].get!string == "Doing");
    assert(draft["lanes"][1]["color"].get!string == "#e8b154");
    assert(!draft["lanes"][1]["acceptsNewTasks"].get!bool && !draft["lanes"][1]["agentsPickUp"].get!bool);
    assert(draft["lanes"][2]["marksDone"].get!bool);

    auto plain = readProjectDraft(`{"name": "Site", "lanes": [{"name": "To do", "color": "#8fa6ff"}]}`);
    assert(!plain.get["lanes"][0]["acceptsNewTasks"].get!bool && !plain.get["lanes"][0]["agentsPickUp"].get!bool);
    assert(plain.get["description"].get!string == "");

    auto error = readProjectDraft(`{"error": "Say what the project is."}`);
    assert(error.get["error"].get!string == "Say what the project is." && "name" !in error.get);

    assert(readProjectDraft("I cannot help with that.").isNull);
    assert(readProjectDraft(`{"name": "Site"}`).isNull);
    assert(readProjectDraft(`{"name": "Site", "lanes": [{"name": " "}]}`).isNull);
    assert(readProjectDraft(`{"name": " ", "lanes": [{"name": "To do"}]}`).isNull);
}
