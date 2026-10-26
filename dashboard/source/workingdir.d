/**
 * Taskavista
 *
 * The projects' working directories, where their agents work.
 *
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2026 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

module workingdir;

import vibe.core.log : logError;
import vibe.http.fileserver : HTTPFileServerSettings, serveStaticFiles;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

import std.file : exists, isDir, isFile, mkdir;
import std.path : buildPath, dirName, expandTilde;
import std.uuid : UUID;

import config : Config;
import eventing : Event, IEventPublisher;
import repository : IProjectRepository;

/**
 * The projects' working directories, the ones their agents work in. Each project keeps the path
 * it was given when it was created, which is named after its slug then, under the root in the
 * config. The root is never made here, since where it goes is up to whoever runs the server.
 */
class ProjectWorkingDirs
{
    /// The directory new projects' working directories go in, whether it is there or not.
    public immutable string root;

    this(Config config)
    {
        root = expandTilde(config.projectWorkingDirRoot);
    }

    /// The path a project created with this slug is given, whether it is there or not.
    public string path(string slug)
    {
        return buildPath(root, slug);
    }

    /**
     * Makes a project's working directory if it is not there, for an agent to work in, or along
     * with the project. A working directory is optional: when the directory it goes in is not
     * there, there is none, and an agent works in its scratch space instead.
     *
     * Params:
     *   workingDir = The project's working directory, as stored.
     *
     * Returns: The working directory's path, or null when the directory it goes in is not there or
     *   it cannot be made, which is logged.
     */
    public string ensure(string workingDir) nothrow
    {
        try
        {
            auto dir = expandTilde(workingDir);
            if (exists(dir))
            {
                return dir;
            }

            const parent = dirName(dir);
            if (!exists(parent) || !isDir(parent))
            {
                return null;
            }

            mkdir(dir);
            return dir;
        }
        catch (Exception exception)
        {
            logError("Could not create the working directory %s: %s", workingDir, exception.msg);
            return null;
        }
    }

    /**
     * Whether a project's working directory has an index.html, the page the web UI offers to open,
     * as served under /working-dirs/.
     */
    public bool hasIndexPage(string workingDir) nothrow
    {
        try
        {
            auto page = buildPath(expandTilde(workingDir), "index.html");
            return exists(page) && isFile(page);
        }
        catch (Exception exception)
        {
            logError("Could not look for the index.html in %s: %s", workingDir, exception.msg);
            return false;
        }
    }
}

/**
 * Serves the files in the projects' working directories under /working-dirs/<slug>/, for the page
 * an agent may have made in one, which the UI's "Open project" button opens. The URL follows the
 * slug, while the directory stays where it was made.
 */
class WorkingDirFiles
{
    private IProjectRepository projects;

    this(IProjectRepository projects)
    {
        this.projects = projects;
    }

    /// Answers a request routed as /working-dirs/:slug/*, leaving one for no project or file unanswered.
    public void serve(scope HTTPServerRequest req, scope HTTPServerResponse res)
    {
        const slug = req.params["slug"];
        auto project = projects.findBySlug(slug);
        if (project.isNull)
        {
            return;
        }

        auto settings = new HTTPFileServerSettings("/working-dirs/" ~ slug);
        settings.cacheControl = "no-cache";
        serveStaticFiles(expandTilde(project.get.workingDir) ~ "/", settings)(req, res);
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

            const has = workingDirs.hasIndexPage(project.get.workingDir);
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
