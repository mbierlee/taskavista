module changes;

import vibe.core.core : runTask;
import vibe.core.log : logDiagnostic;
import vibe.core.sync : LocalManualEvent, createManualEvent;
import vibe.data.json : Json;
import vibe.http.websockets : WebSocket;

import std.algorithm.mutation : remove;
import std.uuid : UUID;

/// What happened to a resource. Only a task can be moved, as the moveTask
/// call does; any other write to one is a change.
enum Change : string
{
    created = "created",
    changed = "changed",
    moved = "moved",
    deleted = "deleted",
}

/**
 * Tells every open web UI what has changed, over a WebSocket each, so that a
 * change made elsewhere, such as by an AI agent calling the API, shows without
 * a reload.
 *
 * A message is an event and the ids it concerns, such as
 * `{"type": "task-moved", "taskId": "…", "projectId": "…", "fromLaneId": "…",
 * "toLaneId": "…"}`, never the data
 * itself: the UI fetches what it needs through the REST API, which keeps one
 * way of reading the data, and makes a message missed while a socket
 * reconnects cost nothing more than a refetch. Every write is reported,
 * including those the UI made itself.
 */
class ChangeFeed
{
    private Subscriber[] subscribers;

    /**
     * Reports that a task was created, changed, moved or deleted.
     *
     * The lanes are named so that the UI fetches exactly the ones that changed,
     * rather than working out from what it has drawn where the task was, which
     * is out of date while it is behind on a run of changes.
     *
     * Params:
     *   change = What happened to the task.
     *   taskId = The task.
     *   projectId = The project it is in.
     *   fromLaneId = The lane it was in, or `UUID.init` for one just created.
     *   toLaneId = The lane it is in now, or `UUID.init` for one deleted. The
     *     same lane as `fromLaneId` when it did not leave its lane.
     */
    public void task(Change change, UUID taskId, UUID projectId, UUID fromLaneId, UUID toLaneId)
    {
        UUID[string] ids = ["taskId": taskId, "projectId": projectId];
        if (fromLaneId != UUID.init)
        {
            ids["fromLaneId"] = fromLaneId;
        }
        if (toLaneId != UUID.init)
        {
            ids["toLaneId"] = toLaneId;
        }
        publish("task", change, ids);
    }

    /// A lane of the project `projectId` was created, changed or deleted.
    public void lane(Change change, UUID laneId, UUID projectId)
    {
        publish("lane", change, ["laneId": laneId, "projectId": projectId]);
    }

    /// A project was created, changed or deleted. A change to it may have
    /// changed its lanes as well, as the saveProjectSettings call does.
    public void project(Change change, UUID projectId)
    {
        publish("project", change, ["projectId": projectId]);
    }

    /// An AI agent was created, changed or deleted.
    public void agent(Change change, UUID agentId)
    {
        publish("agent", change, ["agentId": agentId]);
    }

    /**
     * Sends the changes to one web UI for as long as its socket is open.
     *
     * Params:
     *   socket = The UI's socket. Anything it sends is read and ignored.
     */
    public void serve(scope WebSocket socket)
    {
        auto subscriber = new Subscriber;
        subscribers ~= subscriber;
        scope (exit)
        {
            subscribers = subscribers.remove!(s => s is subscriber);
        }

        // Sent from a task of its own, so that a UI slow to read holds up only
        // itself, never the API call that made the change. This task reads
        // meanwhile, which is how it learns that the socket has closed.
        auto sender = runTask(() nothrow { forward(subscriber, socket); });
        scope (exit)
        {
            subscriber.closed = true;
            subscriber.signal.emit();
            sender.joinUninterruptible();
        }

        while (socket.waitForData())
        {
            socket.receiveText(false);
        }
    }

    private void publish(string resource, Change change, UUID[string] ids)
    {
        auto message = Json(["type": Json(resource ~ "-" ~ change)]);
        foreach (name, id; ids)
        {
            message[name] = id.toString;
        }

        const text = message.toString;
        foreach (subscriber; subscribers)
        {
            subscriber.pending ~= text;
            subscriber.signal.emit();
        }
    }

    /// Logs rather than throws, since a socket that fails is only a UI that
    /// will reconnect.
    private static void forward(Subscriber subscriber, WebSocket socket) nothrow
    {
        try
        {
            while (!subscriber.closed)
            {
                // Taken before sending, so a change published during a send is
                // not waited past.
                const emitted = subscriber.signal.emitCount;
                auto messages = subscriber.pending;
                subscriber.pending = null;
                foreach (message; messages)
                {
                    socket.send(message);
                }
                subscriber.signal.waitUninterruptible(emitted);
            }
        }
        catch (Exception exception)
        {
            logDiagnostic("Could not send a change to a web UI: %s", exception.msg);
        }
    }
}

/// One open socket, with the changes not yet sent to it.
private class Subscriber
{
    string[] pending;
    bool closed;
    LocalManualEvent signal;

    this()
    {
        signal = createManualEvent();
    }
}
