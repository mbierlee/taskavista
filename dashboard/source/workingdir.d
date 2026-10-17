module workingdir;

import vibe.core.log : logError;

import std.file : exists, isDir, isFile, mkdir, rename;
import std.path : buildPath, expandTilde;
import std.uuid : UUID;

import config : Config;
import eventing : Event, IEventPublisher;
import repository : IProjectRepository;

/**
 * The projects' working directories, the ones their agents work in, each
 * named after its project's slug under the root in the config. The root is
 * never made here, since where it goes is up to whoever runs the server.
 */
class ProjectWorkingDirs
{
    /// The directory the working directories are in, whether it is there or not.
    public immutable string root;

    this(Config config)
    {
        root = expandTilde(config.projectWorkingDirRoot);
    }

    /// The path of the project's working directory, whether it is there or not.
    public string path(string slug)
    {
        return buildPath(root, slug);
    }

    /**
     * Makes the working directory of a project that was just created, when
     * the root is there. Logs rather than throws, since the project has been
     * created by then, and the directory is made anyway once an agent needs it.
     */
    public void createIfRootExists(string slug) nothrow
    {
        try
        {
            if (rootExists() && !exists(path(slug)))
            {
                mkdir(path(slug));
            }
        }
        catch (Exception exception)
        {
            logError("Could not create the working directory of project %s: %s", slug, exception.msg);
        }
    }

    /**
     * Makes the project's working directory if it is not there, for an agent
     * to work in. A working directory is optional: with no root there is none,
     * and an agent works in its scratch space instead.
     *
     * Returns: The working directory's path, or null when the root is not
     *   there or the directory cannot be made, which is logged.
     */
    public string ensure(string slug) nothrow
    {
        try
        {
            auto dir = path(slug);
            if (exists(dir))
            {
                return dir;
            }

            if (!rootExists())
            {
                return null;
            }

            mkdir(dir);
            return dir;
        }
        catch (Exception exception)
        {
            logError("Could not create the working directory of project %s: %s", slug, exception.msg);
            return null;
        }
    }

    /**
     * Moves the working directory along with a project whose slug changed.
     * Logs rather than throws, since the project has been saved by then.
     */
    public void rename(string oldSlug, string newSlug) nothrow
    {
        if (oldSlug == newSlug)
        {
            return;
        }

        try
        {
            // A project that never had one gets one once an agent needs it.
            if (!exists(path(oldSlug)))
            {
                return;
            }

            .rename(path(oldSlug), path(newSlug));
        }
        catch (Exception exception)
        {
            logError("Could not rename the working directory of project %s to %s: %s", oldSlug, newSlug,
                exception.msg);
        }
    }

    /**
     * Whether the project's working directory has an index.html, the page the
     * web UI offers to open, as served under /working-dirs/.
     */
    public bool hasIndexPage(string slug) nothrow
    {
        try
        {
            auto page = buildPath(path(slug), "index.html");
            return exists(page) && isFile(page);
        }
        catch (Exception exception)
        {
            logError("Could not look for the index.html of project %s: %s", slug, exception.msg);
            return false;
        }
    }

    private bool rootExists()
    {
        return exists(root) && isDir(root);
    }
}

/**
 * Tells the open web UIs when a project's working directory gains or loses
 * its index.html, which the UI offers to open. An agent writes it straight
 * into the directory, not through the API, so nothing would report it.
 * Rather than watch the directory, it is checked after each move of a task,
 * since an agent moves its task on once it is done with it.
 */
class IndexPages
{
    private ProjectWorkingDirs workingDirs;
    private IProjectRepository projects;
    private IEventPublisher events;
    /**
     * What each project's last check found. A project not checked yet counts
     * as having none: a UI that connected since the server started has read
     * the projects since, which says whether each one has one, so the worst
     * this costs is a change reported that a UI already knew of.
     */
    private bool[UUID] found;

    this(ProjectWorkingDirs workingDirs, IProjectRepository projects, IEventPublisher events)
    {
        this.workingDirs = workingDirs;
        this.projects = projects;
        this.events = events;
    }

    /**
     * Reports the project changed when its working directory has gained or
     * lost its index.html since the last check. Logs rather than throws, since
     * the move it follows has been made by then.
     */
    public void check(UUID projectId) nothrow
    {
        try
        {
            auto project = projects.find(projectId);
            if (project.isNull)
            {
                return;
            }

            const has = workingDirs.hasIndexPage(project.get.slug);
            const had = found.get(projectId, false);
            found[projectId] = has;
            if (has != had)
            {
                events.project(Event.changed, projectId);
            }
        }
        catch (Exception exception)
        {
            logError("Could not check the index.html of project %s: %s", projectId, exception.msg);
        }
    }
}
