/**
 * Taskavista
 *
 * How failed API requests are answered, with errors put in the caller's terms.
 *
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2026 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

module api.errors;

import vibe.core.log : logError;
import vibe.http.common : HTTPStatusException;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
import vibe.http.status : HTTPStatus;
import vibe.web.rest : RestErrorInformation;

import std.algorithm : canFind, findSplit, map, startsWith, uniq;
import std.array : join, split;
import std.conv : to;
import std.format : format;
import std.string : strip, stripRight;
import std.typecons : Nullable;
import std.uuid : UUIDParsingException;

import repository : Deadlock, ForeignKeyViolation, UniqueViolation;
import service : AgentModelMissingError, AgentNameMissingError, AgentNameTakenError, AgentNotFoundError,
    AgentRuntimeMissingError, BeforeTaskNotFoundError, BeforeTaskNotInLaneError, EffortNotTakenError,
    IAgentError, ILaneError, IProjectError, ITaskError, LabelBlankError, LabelRepeatedError,
    LaneClosedToNewTasksError, LaneColorInvalidError, LaneListedTwiceError, LaneNameMissingError,
    LaneNotFoundError, LaneOfOtherProjectError, LanePositionNegativeError, LanePositionTakenError,
    MaxParallelTasksInvalidError, ModelNotOfferedError, NameReservedError, NameTakenError, ProjectNameMissingError,
    ProjectNameUnusableError, ProjectNotFoundError, ProjectNotManagedByAiError, RuntimeNotFoundError,
    SlugInvalidError, SlugReservedError, SlugTakenError, TaskBeforeItselfError, TaskBeingScheduledError,
    TaskBeingWorkedOnError, TaskDescriptionMissingError, TaskDoneError, TaskKeptMovingError, TaskLeavesProjectError,
    TaskNotFoundError, TaskPositionNegativeError, TaskPositionTakenError;
import viewmodel : AgentViewModel, LaneViewModel, ProjectViewModel, TaskViewModel;

/**
 * Answers a request under `/api/rest/v1` that no endpoint took, with a 404
 * that has a `statusMessage` like every other failure, rather than vibe's
 * plain-text page. A trailing slash and an unsupported method end up here too.
 */
void answerNoSuchEndpoint(HTTPServerRequest request, HTTPServerResponse response) @safe
{
    response.writeJsonBody(["statusMessage": "There is no " ~ request.method.to!string ~ " "
        ~ request.requestPath.toString ~ "."], HTTPStatus.notFound);
}

/**
 * Answers a failed request as vibe does, except that a message vibe wrote
 * about the body, the path or the arguments is put in the caller's terms. vibe's own words are about vibe
 * and D: a missing argument is a "`body_` parameter", after a kind of
 * parameter in its REST generator, a JSON type is `int_`, a field names its D
 * struct, and a malformed UUID is told in the words of Phobos's parser.
 */
void renderApiError(HTTPServerRequest request, HTTPServerResponse response, RestErrorInformation error) @safe
{
    auto message = error.exception.msg;
    auto clientError = cast(HTTPStatusException) error.exception !is null;
    response.statusCode = error.statusCode;

    auto rewritten = argumentMessage(error.exception);
    if (rewritten !is null)
    {
        message = rewritten;
        // It is the caller's mistake, so a debug build answers it with 400 too.
        clientError = true;
        response.statusCode = HTTPStatus.badRequest;
    }

    if (auto clash = clashError(error.exception))
    {
        message = clash.msg;
        clientError = true;
        response.statusCode = clash.status;
    }

    // Each 503 is a write that is all but sure to go through when sent again.
    if (response.statusCode == HTTPStatus.serviceUnavailable)
    {
        response.headers["Retry-After"] = "1";
    }

    // vibe's default reports an unexpected exception as a 500 with its stack
    // trace in a debug build, and a handler replaces that default, so keep it.
    debug
    {
        if (!clientError)
        {
            response.statusCode = HTTPStatus.internalServerError;
            response.writeJsonBody(["statusMessage": message,
                "statusDebugMessage": () @trusted { return error.exception.toString(); }()]);
            return;
        }
    }
    response.writeJsonBody(["statusMessage": message]);
}

/**
 * The answer to a write the database refused for clashing with another write made at the same
 * time, which no check before the write can rule out and no service turned into an error of its
 * own, or null for any other exception.
 */
private HTTPStatusException clashError(Exception exception) @safe
{
    if (cast(Deadlock) exception)
    {
        logError("A write was aborted to break a deadlock, so some transaction takes its locks out of order: %s",
            exception.msg);
        return new HTTPStatusException(HTTPStatus.serviceUnavailable,
            "The request clashed with another one made at the same time. Send it again.");
    }

    if (cast(UniqueViolation) exception)
    {
        return new HTTPStatusException(HTTPStatus.conflict,
            "Another request made at the same time took a value this one needs to be unique.");
    }

    if (cast(ForeignKeyViolation) exception)
    {
        return new HTTPStatusException(HTTPStatus.notFound,
            "Something the request refers to was deleted by another request made at the same time.");
    }

    return null;
}

/**
 * The message for a body, path id or argument vibe could not read, in the
 * caller's terms, or null when `exception` is not about reading one. The formats are vibe's, so
 * a vibe upgrade can change them; an unmatched one passes through as it is.
 */
private string argumentMessage(Exception exception) @safe
{
    if (auto malformed = cast(UUIDParsingException) exception)
    {
        return "“" ~ malformed.input ~ "” is not a UUID.";
    }

    const message = exception.msg;
    // The same parser failure, for an id in a REST path, which vibe passes on
    // as its own exception with the parser's message.
    if (message.startsWith("An error occured in the UUID parser"))
    {
        return "“" ~ message.between("Input:\t'", "'") ~ "” is not a UUID.";
    }
    // "(0): Error: Expected valid JSON token, got 'garbage'.", from parsing a REST body.
    if (message.startsWith("(") && message.canFind("): Error: "))
    {
        return "The request body is not valid JSON.";
    }
    // A REST body with no Content-Type, or an empty one, reads as undefined.
    if (message == "Expected JSON object, got undefined")
    {
        return "The request body must be a JSON object, sent with the Content-Type application/json.";
    }
    if (message.startsWith("Missing non-optional body_ parameter '"))
    {
        return "The argument " ~ message.between("'", "'") ~ " is missing.";
    }
    if (message.startsWith("Missing non-optional field '"))
    {
        return "The field " ~ message.between("'", "'") ~ " is missing.";
    }
    if (message.startsWith("Unexpected enum value "))
    {
        return "“" ~ message["Unexpected enum value ".length .. $] ~ "” is not one of the allowed values.";
    }
    // "Got JSON of type int_, expected string." and its variants.
    if (message.startsWith("Got ") && message.canFind(" of type ") && message.canFind(", expected "))
    {
        auto got = message.findSplit(" of type ")[2].findSplit(", expected ");
        auto expected = got[2].findSplit(" for ")[0].stripRight(".").split(", ");
        return mistyped(got[0], expected);
    }
    // "Expected JSON array, got string", from reading an array or an object.
    if (message.startsWith("Expected JSON ") && message.canFind(", got "))
    {
        auto parts = message["Expected JSON ".length .. $].findSplit(", got ");
        return mistyped(parts[2], [parts[0]]);
    }

    return null;
}

/// "A value is a number where a string is expected.", from vibe's JSON type names.
private string mistyped(string got, string[] expected) @safe
{
    return "A value is " ~ jsonTypeName(got) ~ " where " ~ expected.map!jsonTypeName.uniq.join(" or ")
        ~ " is expected.";
}

/// A JSON type as a caller would name it, from vibe's `Json.Type` member name.
private string jsonTypeName(string type) @safe
{
    switch (type)
    {
        case "null_":
            return "null";
        case "bool_":
            return "a boolean";
        case "int_":
        case "bigInt":
        case "float_":
            return "a number";
        case "string":
            return "a string";
        case "array":
            return "an array";
        case "object":
            return "an object";
        default:
            return "missing";
    }
}

/// The text of `text` between the first `open` and the next `close` after it.
private string between(string text, string open, string close) @safe
{
    return text.findSplit(open)[2].findSplit(close)[0];
}

/**
 * The HTTP error a project error is answered with. A clash of a slug the client never chose
 * is reported against the name, since the name is all a person in the UI can change.
 */
HTTPStatusException toHTTPError(IProjectError error, ProjectViewModel project)
{
    if (cast(ProjectNotManagedByAiError) error)
    {
        return new HTTPStatusException(HTTPStatus.conflict,
            "The project is not managed by AI agents, so its agents cannot be resumed.");
    }

    if (cast(ProjectNameMissingError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "A project needs a name.");
    }

    if (cast(ProjectNameUnusableError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest,
            "That name is not allowed. A name needs at least one letter or digit.");
    }

    if (auto laneCheck = laneCheckError(cast(Object) error))
    {
        return laneCheck;
    }

    if (cast(ProjectNotFoundError) error)
    {
        return new HTTPStatusException(HTTPStatus.notFound, "No project has that id.");
    }

    if (cast(SlugInvalidError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest,
            "A slug is lowercase letters and digits, in any script, in words joined by single hyphens.");
    }

    if (cast(SlugReservedError) error)
    {
        return new HTTPStatusException(HTTPStatus.conflict,
            format("The slug '%s' is reserved for a page of the web UI.", project.slug));
    }

    if (cast(SlugTakenError) error)
    {
        return new HTTPStatusException(HTTPStatus.conflict,
            format("Another project already has the slug '%s'.", project.slug));
    }

    if (cast(NameReservedError) error)
    {
        return new HTTPStatusException(HTTPStatus.conflict,
            format("A project cannot be called “%s”. Pick another name.", project.name.strip));
    }

    if (auto taken = cast(NameTakenError) error)
    {
        return new HTTPStatusException(HTTPStatus.conflict,
            format("A project called “%s” already exists. Pick another name.", taken.ownerName));
    }

    if (cast(LaneOfOtherProjectError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "A lane sent belongs to another project.");
    }

    if (cast(LaneNotFoundError) error)
    {
        return new HTTPStatusException(HTTPStatus.notFound, "No lane has one of the lane ids sent.");
    }

    if (cast(LaneListedTwiceError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "A lane is listed twice.");
    }

    return unanswered(error);
}

/**
 * The 400s for the lane checks, which both a project's lanes and a lane on its own go through.
 *
 * Returns: The HTTP error, or null for an error that is not one of the lane checks.
 */
private HTTPStatusException laneCheckError(Object error)
{
    if (cast(LaneNameMissingError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "A lane needs a name.");
    }

    if (cast(LanePositionNegativeError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "A lane's position is 0 or more.");
    }

    if (cast(LaneColorInvalidError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest,
            "A lane's color is '#' and six hex digits, like #8fa6ff.");
    }

    return null;
}

/**
 * The position sent, in words, or "its position" for none sent, when the service chose the one
 * that was taken.
 */
private string positionOf(Nullable!int position)
{
    return position.isNull ? "its position" : format("position %s", position.get);
}

/// The 500 for an error a service added without an answer in its toHTTPError.
private HTTPStatusException unanswered(E)(E error)
{
    return new HTTPStatusException(HTTPStatus.internalServerError,
        format("No answer for the error %s.", typeid(cast(Object) error)));
}

/**
 * The HTTP error a lane error is answered with.
 *
 * Params:
 *   error = The error.
 *   lane = The lane that was being written, or null for none.
 */
HTTPStatusException toHTTPError(ILaneError error, LaneViewModel lane)
{
    if (auto laneCheck = laneCheckError(cast(Object) error))
    {
        return laneCheck;
    }

    if (cast(ProjectNotFoundError) error)
    {
        return new HTTPStatusException(HTTPStatus.notFound, "No project has that id.");
    }

    if (cast(LaneNotFoundError) error)
    {
        return new HTTPStatusException(HTTPStatus.notFound, "No lane has that id.");
    }

    if (cast(LanePositionTakenError) error)
    {
        return new HTTPStatusException(HTTPStatus.conflict,
            format("Another lane of the project is already at %s.", positionOf(lane.position)));
    }

    return unanswered(error);
}

/**
 * The HTTP error a task error is answered with.
 *
 * Params:
 *   error = The error.
 *   task = The task that was being written, or null for none.
 */
HTTPStatusException toHTTPError(ITaskError error, TaskViewModel task)
{
    if (cast(TaskDescriptionMissingError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "A task needs a description.");
    }

    if (cast(TaskPositionNegativeError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "A task's position is 0 or more.");
    }

    if (cast(ProjectNotFoundError) error)
    {
        return new HTTPStatusException(HTTPStatus.notFound, "No project has that id.");
    }

    if (cast(LaneNotFoundError) error)
    {
        return new HTTPStatusException(HTTPStatus.notFound, "No lane has that id.");
    }

    if (cast(TaskNotFoundError) error)
    {
        return new HTTPStatusException(HTTPStatus.notFound, "No task has that id.");
    }

    if (cast(LaneClosedToNewTasksError) error)
    {
        return new HTTPStatusException(HTTPStatus.conflict, "The project only takes new tasks in its first lane.");
    }

    if (cast(TaskLeavesProjectError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "A task can only move to a lane of its own project.");
    }

    if (cast(TaskBeforeItselfError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "A task cannot move before itself.");
    }

    if (cast(BeforeTaskNotFoundError) error)
    {
        return new HTTPStatusException(HTTPStatus.notFound, "No task has the beforeTaskId sent.");
    }

    if (cast(BeforeTaskNotInLaneError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "The beforeTaskId task is not in that lane.");
    }

    if (cast(TaskPositionTakenError) error)
    {
        return new HTTPStatusException(HTTPStatus.conflict,
            format("Another task of the lane is already at %s.", positionOf(task.position)));
    }

    if (cast(ProjectNotManagedByAiError) error)
    {
        return new HTTPStatusException(HTTPStatus.conflict,
            "The task's project is not managed by AI agents, so no agent works on its tasks.");
    }

    if (cast(TaskDoneError) error)
    {
        return new HTTPStatusException(HTTPStatus.conflict, "The task is in a done lane, so it is done.");
    }

    if (cast(TaskBeingScheduledError) error)
    {
        return new HTTPStatusException(HTTPStatus.conflict,
            "The task scheduler is choosing an agent for the task right now.");
    }

    if (cast(TaskBeingWorkedOnError) error)
    {
        return new HTTPStatusException(HTTPStatus.conflict, "An agent is working on the task right now.");
    }

    if (cast(TaskKeptMovingError) error)
    {
        return new HTTPStatusException(HTTPStatus.serviceUnavailable,
            "The task kept moving to other lanes meanwhile. Send the request again.");
    }

    return unanswered(error);
}

/**
 * The HTTP error an agent error is answered with. A runtime, model or effort level that does
 * not fit is a 400, as it would have been a failed foreign key.
 *
 * Params:
 *   error = The error.
 *   agent = The agent that was being written, or null for none.
 */
HTTPStatusException toHTTPError(IAgentError error, AgentViewModel agent)
{
    if (cast(AgentNameMissingError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "An agent needs a name.");
    }

    if (cast(AgentRuntimeMissingError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "An agent needs a runtime.");
    }

    if (cast(AgentModelMissingError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "An agent needs a model.");
    }

    if (cast(MaxParallelTasksInvalidError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest,
            "An agent's parallel tasks must be above 0, or null for no limit.");
    }

    if (cast(LabelBlankError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, "A label cannot be blank.");
    }

    if (auto repeated = cast(LabelRepeatedError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest,
            format("The label “%s” is given twice.", repeated.label));
    }

    if (cast(ProjectNotFoundError) error)
    {
        return new HTTPStatusException(HTTPStatus.notFound, "No project has that id.");
    }

    if (cast(AgentNotFoundError) error)
    {
        return new HTTPStatusException(HTTPStatus.notFound, "No agent has that id.");
    }

    if (cast(RuntimeNotFoundError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest, format("There is no runtime '%s'.", agent.runtime));
    }

    if (auto notOffered = cast(ModelNotOfferedError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest,
            format("%s offers no model '%s'.", notOffered.runtimeName, agent.model));
    }

    if (cast(EffortNotTakenError) error)
    {
        return new HTTPStatusException(HTTPStatus.badRequest,
            format("The model '%s' takes no effort level '%s'.", agent.model, agent.effort));
    }

    if (cast(AgentNameTakenError) error)
    {
        return new HTTPStatusException(HTTPStatus.conflict,
            format("An agent called “%s” already exists. Pick another name.", agent.name));
    }

    return unanswered(error);
}
