module api.errors;

import vibe.http.common : HTTPStatusException;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
import vibe.http.status : HTTPStatus;
import vibe.web.rest : RestErrorInformation;

import std.algorithm : canFind, findSplit, map, startsWith, uniq;
import std.array : join, split;
import std.conv : to;
import std.string : stripRight;
import std.uuid : UUIDParsingException;

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
