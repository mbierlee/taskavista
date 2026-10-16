module workingdir;

import vibe.core.log : logError;

import std.file : exists, isDir, mkdir, rename;
import std.path : buildPath, expandTilde;

import config : Config;

/**
 * The projects' working directories, the ones their agents work in, each
 * named after its project's slug under the root in the config. The root is
 * never made here, since where it goes is up to whoever runs the server.
 */
class ProjectWorkingDirs
{
    private string root;

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

    private bool rootExists()
    {
        return exists(root) && isDir(root);
    }
}
