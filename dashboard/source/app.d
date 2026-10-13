import vibe.vibe;
import vibe.db.postgresql;
import poodinis;

import std.algorithm : startsWith;
import std.functional : toDelegate;
import std.path : baseName, extension;

import agent : AgentChat, AgentDrafter, AgentHelp, AgentPrompt, ClaudeCodeRuntime, IRuntime, RuntimeExecutor, TaskScheduler;
import config : Config, connectionString, loadConfig;
import helpers : formatURL;
import prompt : PromptParser;
import repository : AgentLogRepository, AgentRepository, DefaultRepository, LaneRepository, ProjectRepository,
    RuntimeRepository, TaskRepository;
import api.rest : AgentApi, AgentService, DefaultApi, DefaultService, LaneApi, LaneService, ProjectApi,
    ProjectService, RuntimeApi, RuntimeService, TaskApi, TaskService;
import api.errors : answerNoSuchEndpoint, renderApiError;
import api.rpc : RpcApi, RpcService, answerNoSuchCall, enforceJsonObjectBody;
import changes : ChangeFeed;
import schema : installSchemaWhenEmpty;

/// Wires the application together. Everything resolvable is registered here, so
/// the classes themselves stay free of container knowledge.
class DashboardContext : ApplicationContext
{
    @Inject private Config config;

    override void registerDependencies(shared(DependencyContainer) container)
    {
        container.register!Config.existingInstance(loadConfig());
        container.register!ChangeFeed;
        container.register!ProjectRepository;
        container.register!(ProjectApi, ProjectService);
        container.register!LaneRepository;
        container.register!(LaneApi, LaneService);
        container.register!TaskRepository;
        container.register!(TaskApi, TaskService);
        container.register!RuntimeRepository;
        container.register!(RuntimeApi, RuntimeService);
        container.register!AgentRepository;
        container.register!AgentLogRepository;
        container.register!(AgentApi, AgentService);
        container.register!DefaultRepository;
        container.register!(DefaultApi, DefaultService);
        container.register!(RpcApi, RpcService);
        container.register!(IRuntime, ClaudeCodeRuntime);
        container.register!RuntimeExecutor;
        container.register!TaskScheduler;
        container.register!PromptParser;
        container.register!AgentHelp;
        container.register!AgentPrompt;
        container.register!AgentChat;
        container.register!AgentDrafter;
    }

    /// The pool comes from a factory method because its connection string is
    /// config, not a dependency. One instance is shared, which is the point of a
    /// pool. It connects lazily, so the server still starts with no database running.
    @Component PostgresClient postgresClient()
    {
        return new PostgresClient(config.database.connectionString,
            config.database.connectionPoolSize);
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
    router.get("/api/changes/v1", handleWebSockets(&container.resolve!ChangeFeed.serve));

    // Before the static files, since the file has the API's URL left to fill in.
    auto agentHelp = container.resolve!AgentHelp;
    router.get("/agent-help.txt", (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        res.writeBody(agentHelp.text, "text/plain; charset=UTF-8");
    });

    auto fileSettings = new HTTPFileServerSettings;
    fileSettings.cacheControl = "no-cache";
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

/// Serves the web UI's page for a path no file matched. Its screens are client-side
/// routes (see public/app.js), so the server does not know them: each gets the
/// same page, and app.js works out which screen to show from the URL. A path
/// under /api/ or ending in a file extension is left alone, since it is a
/// mistyped endpoint or a missing file, and a 404 says so better than a page of HTML.
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
