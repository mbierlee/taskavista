module api.checks;

import vibe.http.common : enforceHTTP;
import vibe.http.status : HTTPStatus;

import std.algorithm : canFind;
import std.format : format;
import std.string : strip;
import std.uni : toLower;

import helpers : hasLetterOrDigit, isHexColor, isSlug, slugify;
import model : Agent, Lane, Project, Task;
import repository : ProjectRepository;

/// The same rules as the name check constraints, applied early so that a bad
/// name comes back as a 400 rather than as a failed insert. A letter or digit
/// is asked for so that a slug can always be made from the name.
void enforceNamed(Project project) @safe
{
    enforceHTTP(project !is null && project.name.strip.length > 0,
        HTTPStatus.badRequest, "A project needs a name.");
    enforceHTTP(hasLetterOrDigit(project.name), HTTPStatus.badRequest,
        "That name is not allowed. A name needs at least one letter or digit.");
}

/// Slugs the web UI's routes use for screens of their own under /projects/,
/// which a project's URL would collide with.
immutable string[] reservedSlugs = ["new"];

/// Checked before the write so that a bad slug comes back as a 400 or 409, not
/// as a failed insert. Sets `project.slug` when the client sent none, which
/// needs the name to have passed `enforceNamed`. A clash of a slug the client
/// never chose is reported against the name, since the name is all a person
/// in the UI can change.
void enforceSlug(Project project, ProjectRepository repository)
{
    const derived = project.slug.length == 0;
    if (derived)
    {
        project.slug = slugify(project.name);
    }

    enforceHTTP(isSlug(project.slug), HTTPStatus.badRequest,
        "A slug is lowercase letters and digits, in any script, in words joined by single hyphens.");
    enforceHTTP(!reservedSlugs.canFind(project.slug), HTTPStatus.conflict, derived
        ? format("A project cannot be called “%s”. Pick another name.", project.name.strip)
        : format("The slug '%s' is reserved for a page of the web UI.", project.slug));

    const owner = repository.slugOwner(project.slug, project.id);
    enforceHTTP(owner.isNull, HTTPStatus.conflict, derived
        ? format("A project called “%s” already exists. Pick another name.", owner.get)
        : format("Another project already has the slug '%s'.", project.slug));
}

/// The lane check constraints in sql/init.sql, applied early so that a bad
/// field comes back as a 400 rather than as a failed write. The colour is
/// lowercased first, since the column only takes lowercase hex.
void enforceValid(Lane lane) @safe
{
    enforceHTTP(lane !is null && lane.name.strip.length > 0,
        HTTPStatus.badRequest, "A lane needs a name.");
    enforceHTTP(lane.position.isNull || lane.position.get >= 0, HTTPStatus.badRequest,
        "A lane's position is 0 or more.");

    lane.color = lane.color.toLower;
    enforceHTTP(isHexColor(lane.color), HTTPStatus.badRequest,
        "A lane's color is '#' and six hex digits, like #8fa6ff.");
}

/// The task check constraints in sql/init.sql, applied early so that a bad
/// field comes back as a 400 rather than as a failed write.
void enforceValid(Task task) @safe
{
    enforceHTTP(task !is null && task.description.strip.length > 0,
        HTTPStatus.badRequest, "A task needs a description.");
    enforceHTTP(task.position.isNull || task.position.get >= 0, HTTPStatus.badRequest,
        "A task's position is 0 or more.");
}

/// The agent check constraints in sql/init.sql, applied early so that a bad
/// field comes back as a 400 rather than as a failed write. The labels are
/// lowercased first, since the column only takes lowercase.
void enforceValid(Agent agent) @safe
{
    enforceHTTP(agent !is null && agent.name.strip.length > 0,
        HTTPStatus.badRequest, "An agent needs a name.");
    enforceHTTP(agent.runtime.strip.length > 0, HTTPStatus.badRequest, "An agent needs a runtime.");
    enforceHTTP(agent.model.strip.length > 0, HTTPStatus.badRequest, "An agent needs a model.");
    foreach (ref label; agent.labels)
    {
        label = label.toLower;
    }
    foreach (index, label; agent.labels)
    {
        enforceHTTP(label.strip.length > 0, HTTPStatus.badRequest, "A label cannot be blank.");
        enforceHTTP(!agent.labels[0 .. index].canFind(label), HTTPStatus.badRequest,
            format("The label “%s” is given twice.", label));
    }
}
