/**
 * Taskavista
 *
 * What a service takes and returns that is more than one resource.
 *
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2026 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

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
