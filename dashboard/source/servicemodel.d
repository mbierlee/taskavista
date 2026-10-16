module servicemodel;

import model : Lane, Project;

/// A project together with its lanes.
class ProjectWithLanes
{
    Project project;
    /// The project's lanes, in board order.
    Lane[] lanes;

    this() @safe
    {
    }

    this(Project project, Lane[] lanes) @safe
    {
        this.project = project;
        this.lanes = lanes;
    }
}
