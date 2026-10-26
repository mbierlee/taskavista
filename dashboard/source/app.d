/**
 * Taskavista
 *
 * The server's entry point, which wires the application together and serves the web UI.
 *
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2026 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

import vibe.vibe;
import poodinis;

import std.algorithm : startsWith;
import std.functional : toDelegate;
import std.path : baseName, extension;

import agent : AgentChat, AgentDrafter, AgentHelp, AgentPrompt, ClaudeCodeRuntime, IAgentChat, IRuntime,
    ProjectDrafter, RuntimeExecutor, TaskExecutor, TaskScheduler;
import config : Config, connectionString, loadConfig;
import helpers : formatURL;
import prompt : PromptParser;
import repository : IAgentLogRepository, IAgentRepository, IDefaultRepository, ILaneRepository, IProjectRepository,
    IRuntimeRepository, ITaskRepository, ITransactional;
import repository.postgres : PostgresAgentLogRepository, PostgresAgentRepository, PostgresConnections,
    PostgresDefaultRepository, PostgresLaneRepository, PostgresProjectRepository, PostgresRuntimeRepository,
    PostgresTaskRepository;
import api.rest : AgentApi, AgentController, DefaultApi, DefaultController, LaneApi, LaneController, ProjectApi,
    ProjectController, RuntimeApi, RuntimeController, TaskApi, TaskController;
import api.errors : answerNoSuchEndpoint, renderApiError;
import api.rpc : RpcApi, RpcController, answerNoSuchCall, enforceJsonObjectBody;
import eventing : CommittedEventPublisher, EventStream, IEventPublisher, IEventStream;
import schema : installSchemaWhenEmpty;
import service : AgentService, DefaultService, LaneService, ProjectService, RuntimeService, TaskService;
import workingdir : IndexPages, ProjectWorkingDirs, WorkingDirFiles;

/**
 * Wires the application together. Everything resolvable is registered here, so
 * the classes themselves stay free of container knowledge.
 */
class DashboardContext : ApplicationContext
{
    @Inject private Config config;

    override void registerDependencies(shared(DependencyContainer) container)
    {
        container.register!Config.existingInstance(loadConfig());
        container.register!(IEventStream, EventStream);
        // What is published reaches the stream once the write it reports has committed.
        container.register!(IEventPublisher, CommittedEventPublisher);
        container.register!ProjectWorkingDirs;
        container.register!IndexPages;
        container.register!WorkingDirFiles;
        container.register!(IProjectRepository, PostgresProjectRepository);
        container.register!ProjectService;
        container.register!(ProjectApi, ProjectController);
        container.register!(ILaneRepository, PostgresLaneRepository);
        container.register!LaneService;
        container.register!(LaneApi, LaneController);
        container.register!(ITaskRepository, PostgresTaskRepository);
        container.register!TaskService;
        container.register!(TaskApi, TaskController);
        container.register!(IRuntimeRepository, PostgresRuntimeRepository);
        container.register!RuntimeService;
        container.register!(RuntimeApi, RuntimeController);
        container.register!(IAgentRepository, PostgresAgentRepository);
        container.register!(IAgentLogRepository, PostgresAgentLogRepository);
        container.register!AgentService;
        container.register!(AgentApi, AgentController);
        container.register!(IDefaultRepository, PostgresDefaultRepository);
        container.register!DefaultService;
        container.register!(DefaultApi, DefaultController);
        container.register!(RpcApi, RpcController);
        container.register!(IRuntime, ClaudeCodeRuntime);
        container.register!RuntimeExecutor;
        container.register!TaskScheduler;
        container.register!TaskExecutor;
        container.register!PromptParser;
        container.register!AgentHelp;
        container.register!AgentPrompt;
        container.register!(IAgentChat, AgentChat);
        container.register!AgentDrafter;
        container.register!ProjectDrafter;
    }

    private PostgresConnections connections;

    /**
     * The connections come from a factory method because their connection string is
     * config, not a dependency. One instance is shared, which is the point of a
     * pool, and serves both as the repositories' way to the database and as the
     * services' ITransactional. It connects lazily, so the server still starts with
     * no database running.
     */
    @Component PostgresConnections postgresConnections()
    {
        if (connections is null)
        {
            connections = new PostgresConnections(config.database.connectionString,
                config.database.connectionPoolSize);
        }

        return connections;
    }

    /// Ditto
    @Component @RegisterByType!ITransactional PostgresConnections transactional()
    {
        return postgresConnections();
    }
}

void main()
{
    auto container = new shared DependencyContainer();
    container.registerContext!DashboardContext;

    auto config = container.resolve!Config;

    installSchemaWhenEmpty(config.database.connectionString);
    // In a task, so a slow or unreachable database does not hold up the server
    // starting.
    auto runtimeExecutor = container.resolve!RuntimeExecutor;
    runTask(() nothrow{ runtimeExecutor.logAgentsWithoutRuntime(); });
    auto scheduler = container.resolve!TaskScheduler;
    runTask(() nothrow{
        try
        {
            scheduler.run();
        }
        catch (Exception e)
        {
            logError("The task scheduler stopped: %s", e.msg);
        }
    });
    auto taskExecutor = container.resolve!TaskExecutor;
    runTask(() nothrow{
        try
        {
            taskExecutor.run();
        }
        catch (Exception e)
        {
            logError("The task executor stopped: %s", e.msg);
        }
    });

    auto router = new URLRouter;
    // Before the static file catch-all, so /api/* is not served as a file.
    auto apiSettings = new RestInterfaceSettings;
    apiSettings.errorHandler = toDelegate(&renderApiError);
    router.registerRestInterface(container.resolve!ProjectApi, apiSettings);
    router.registerRestInterface(container.resolve!LaneApi, apiSettings);
    router.registerRestInterface(container.resolve!TaskApi, apiSettings);
    router.registerRestInterface(container.resolve!RuntimeApi, apiSettings);
    router.registerRestInterface(container.resolve!AgentApi, apiSettings);
    router.registerRestInterface(container.resolve!DefaultApi, apiSettings);
    router.any("/api/rest/v1/*", &answerNoSuchEndpoint);
    // The calls sit between a check of their bodies, which has to come before vibe
    // reads one, and a JSON 404 for anything none of them took.
    router.post("/api/rpc/v1/*", &enforceJsonObjectBody);
    router.registerRestInterface(container.resolve!RpcApi, apiSettings);
    router.any("/api/rpc/v1/*", &answerNoSuchCall);
    router.get("/api/events/v1", handleWebSockets(&container.resolve!IEventStream.serve));

    // Before the static files, since the file has the API's URL left to fill in.
    auto agentHelp = container.resolve!AgentHelp;
    router.get("/agent-help.txt", (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        res.writeBody(agentHelp.text, "text/plain; charset=UTF-8");
    });

    auto fileSettings = new HTTPFileServerSettings;
    fileSettings.cacheControl = "no-cache";
    // Before public/, so that a file there cannot take one of the working directories' paths.
    auto workingDirFiles = container.resolve!WorkingDirFiles;
    router.get("/working-dirs/:slug/*", &workingDirFiles.serve);
    router.get("*", serveStaticFiles("public/", fileSettings));
    // Any other path is one of the UI's screens, which are routed in the browser.
    router.get("*", serveUiRoutes("public/index.html", fileSettings));

    auto settings = new HTTPServerSettings;
    settings.port = config.port;
    settings.bindAddresses = config.bindAddresses;

    auto listener = listenHTTP(settings, router);
    scope (exit)
    {
        listener.stopListening();
    }

    foreach (address; config.bindAddresses)
    {
        logInfo("Running at %s", formatURL(address, config.port));
    }

    runApplication();
}

/**
 * Serves the web UI's page for a path no file matched. Its screens are client-side
 * routes (see public/app.js), so the server does not know them: each gets the
 * same page, and app.js works out which screen to show from the URL. A path
 * under /api/ or ending in a file extension is left alone, since it is a
 * mistyped endpoint or a missing file, and a 404 says so better than a page of HTML.
 */
HTTPServerRequestDelegateS serveUiRoutes(string page, HTTPFileServerSettings settings)
{
    return (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        auto path = req.requestPath.toString();
        if (path.startsWith("/api/") || path.baseName.extension != "")
        {
            return;
        }

        sendFile(req, res, NativePath(page), settings);
    };
}
