module servicemodel;

import viewmodel : LaneViewModel, ProjectViewModel;

/// A project together with its lanes.
class ProjectWithLanes
{
    ProjectViewModel project;
    /// The project's lanes, in board order.
    LaneViewModel[] lanes;

    this() @safe
    {
    }

    this(ProjectViewModel project, LaneViewModel[] lanes) @safe
    {
        this.project = project;
        this.lanes = lanes;
    }
}
