module repository;

import vibe.db.postgresql;

import std.datetime.systime : SysTime;
import std.format : format;
import std.typecons : Nullable, nullable;
import std.uuid : UUID;

import model : Agent, AgentLogEntry, Default, EffortLevel, Lane, Model, Project, Runtime, Task, TaskAddRule, TaskNote,
    toTaskAddRule;

/**
 * The assignment to ai_paused in an update that sets managed_by_ai to $6. A
 * project that stops being managed by AI has its agents paused, and one
 * that starts being managed has them running; otherwise they stay as they
 * were. On the right of a set, managed_by_ai is still the old value.
 */
private enum pausedOnceManaged =
    "ai_paused = case when managed_by_ai = $6 then ai_paused else not $6 end";

/// Reads and writes rows of the projects table.
class ProjectRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

    /**
     * Gets every project.
     *
     * Returns: Every project, by name.
     */
    Project[] all()
    {
        QueryParams query;
        query.sqlCommand = "select id, name, slug, description, task_add_rule, managed_by_ai, ai_paused from projects order by name";

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            Project[] projects;
            projects.reserve(answer.length);

            foreach (index; 0 .. answer.length)
            {
                projects ~= answer[index].toProject;
            }

            return projects;
        });
    }

    /**
     * Finds a project.
     *
     * Params:
     *   id = The project's id.
     *
     * Returns: The project with this id, or an empty Nullable when there is none.
     */
    Nullable!Project find(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "select id, name, slug, description, task_add_rule, managed_by_ai, ai_paused from projects where id = $1";
        query.argsVariadic(id);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            return answer.length == 0 ? Nullable!Project.init : answer[0].toProject.nullable;
        });
    }

    /**
     * Finds the project that already has a slug.
     *
     * Params:
     *   slug = The slug to look for.
     *   except = The id of the project not to count, or UUID.init to check against every
     *     project.
     *
     * Returns: The name of the project other than `except` that has this slug, or an empty
     *   Nullable when none has.
     */
    Nullable!string slugOwner(string slug, UUID except)
    {
        QueryParams query;
        query.sqlCommand = "select name from projects where slug = $1 and id <> $2";
        query.argsVariadic(slug, except);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            return answer.length == 0 ? Nullable!string.init : answer[0]["name"]
                .as!string.nullable;
        });
    }

    /**
     * Inserts a project.
     *
     * Fills in the id the database assigned it, and whether its AI agents are paused, which
     * they are unless it is managed by AI.
     *
     * Params:
     *   project = The project to insert.
     *
     * Returns: The same instance, so it can be used as an expression.
     */
    Project add(Project project)
    {
        QueryParams query;
        query.sqlCommand = "insert into projects (name, slug, description, task_add_rule, managed_by_ai, ai_paused) values ($1, $2, $3, $4, $5, not $5) returning id, ai_paused";
        query.argsVariadic(project.name, project.slug, project.description,
            cast(string) project.taskAddRule, project.managedByAi);

        client.pickConnection((scope connection) {
            auto row = connection.execParams(query)[0];
            project.id = row["id"].as!UUID;
            project.aiPaused = row["ai_paused"].as!bool;
        });

        return project;
    }

    /**
     * Writes a project back over the row with its id.
     *
     * Fills in whether its AI agents are paused now (see pausedOnceManaged); the aiPaused it
     * carries is not written.
     *
     * Params:
     *   project = The project to write.
     *
     * Returns: False when no row has that id, in which case nothing was written.
     */
    bool update(Project project)
    {
        QueryParams query;
        query.sqlCommand = "update projects set name = $2, slug = $3, description = $4, task_add_rule = $5, managed_by_ai = $6, "
            ~ pausedOnceManaged ~ " where id = $1 returning ai_paused";
        query.argsVariadic(project.id, project.name, project.slug, project.description,
            cast(string) project.taskAddRule, project.managedByAi);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);
            if (answer.length == 0)
            {
                return false;
            }

            project.aiPaused = answer[0]["ai_paused"].as!bool;
            return true;
        });
    }

    /**
     * Pauses or resumes a project's AI agents.
     *
     * Params:
     *   id = The project's id.
     *   paused = Whether its AI agents are to be paused.
     *
     * Returns: False when no row has that id, in which case nothing was written.
     */
    bool setAiPaused(UUID id, bool paused)
    {
        QueryParams query;
        query.sqlCommand = "update projects set ai_paused = $2 where id = $1 returning id";
        query.argsVariadic(id, paused);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    /**
     * Inserts a project and its lanes in one transaction.
     *
     * The lanes go in at the positions they carry. Fills in the ids the database assigned them
     * and, as add does, whether the project's AI agents are paused.
     *
     * Params:
     *   project = The project to insert.
     *   lanes = Its lanes.
     */
    void addWithLanes(Project project, Lane[] lanes)
    {
        client.pickConnection((scope connection) {
            connection.exec("begin");
            scope (failure)
            {
                connection.exec("rollback");
            }

            QueryParams insert;
            insert.sqlCommand = "insert into projects (name, slug, description, task_add_rule, managed_by_ai, ai_paused) values ($1, $2, $3, $4, $5, not $5) returning id, ai_paused";
            insert.argsVariadic(project.name, project.slug, project.description,
                cast(string) project.taskAddRule, project.managedByAi);
            auto row = connection.execParams(insert)[0];
            project.id = row["id"].as!UUID;
            project.aiPaused = row["ai_paused"].as!bool;

            foreach (lane; lanes)
            {
                lane.projectId = project.id;

                QueryParams add;
                add.sqlCommand = "insert into lanes (project_id, name, position, color, marks_done) values ($1, $2, $3, $4, $5) returning id";
                add.argsVariadic(lane.projectId, lane.name, lane.position.get, lane.color, lane
                    .marksDone);
                lane.id = connection.execParams(add)[0]["id"].as!UUID;
            }

            connection.exec("commit");
        });
    }

    /**
     * Writes a project back over its row and gives it exactly these lanes, in one transaction.
     *
     * The lanes in `removed` are deleted, tasks and all, the rest are written at the positions
     * they carry, and a lane with no id yet is inserted and given the one the database
     * assigned. The position constraint is deferred to the commit, since lanes trading places
     * briefly share one. Whether the project's AI agents are paused is written and filled in as
     * update does it.
     *
     * Params:
     *   project = The project to write.
     *   lanes = The lanes it keeps or gains.
     *   removed = The ids of the lanes it loses.
     */
    void replaceWithLanes(Project project, Lane[] lanes, UUID[] removed)
    {
        client.pickConnection((scope connection) {
            connection.exec("begin");
            scope (failure)
            {
                connection.exec("rollback");
            }
            connection.exec("set constraints all deferred");

            QueryParams update;
            update.sqlCommand = "update projects set name = $2, slug = $3, description = $4, task_add_rule = $5, managed_by_ai = $6, "
                ~ pausedOnceManaged ~ " where id = $1 returning ai_paused";
            update.argsVariadic(project.id, project.name, project.slug, project.description,
                cast(string) project.taskAddRule, project.managedByAi);
            project.aiPaused = connection.execParams(update)[0]["ai_paused"].as!bool;

            foreach (id; removed)
            {
                QueryParams remove;
                remove.sqlCommand = "delete from lanes where id = $1";
                remove.argsVariadic(id);
                connection.execParams(remove);
            }

            foreach (lane; lanes)
            {
                lane.projectId = project.id;

                QueryParams write;
                if (lane.id == UUID.init)
                {
                    write.sqlCommand = "insert into lanes (project_id, name, position, color, marks_done) values ($1, $2, $3, $4, $5) returning id";
                    write.argsVariadic(lane.projectId, lane.name, lane.position.get, lane.color, lane
                        .marksDone);
                    lane.id = connection.execParams(write)[0]["id"].as!UUID;
                }
                else
                {
                    write.sqlCommand = "update lanes set name = $2, position = $3, color = $4, marks_done = $5 where id = $1";
                    write.argsVariadic(lane.id, lane.name, lane.position.get, lane.color, lane
                        .marksDone);
                    connection.execParams(write);
                }
            }

            connection.exec("commit");
        });
    }

    /**
     * Deletes a project.
     *
     * Params:
     *   id = The project's id.
     *
     * Returns: False when no row had it.
     */
    bool remove(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "delete from projects where id = $1 returning id";
        query.argsVariadic(id);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }
}

private Project toProject(immutable Row row)
{
    return new Project(
        row["id"].as!UUID,
        row["name"].as!string,
        row["slug"].as!string,
        row["description"].as!string,
        row["task_add_rule"].as!string.toTaskAddRule,
        row["managed_by_ai"].as!bool,
        row["ai_paused"].as!bool
    );
}

/// Reads and writes rows of the lanes table.
class LaneRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

    /**
     * Gets a project's lanes.
     *
     * Params:
     *   projectId = The project's id.
     *
     * Returns: Every lane of the project, in board order.
     */
    Lane[] ofProject(UUID projectId)
    {
        QueryParams query;
        query.sqlCommand = "select id, project_id, name, position, color, marks_done from lanes where project_id = $1 order by position";
        query.argsVariadic(projectId);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            Lane[] lanes;
            lanes.reserve(answer.length);

            foreach (index; 0 .. answer.length)
            {
                lanes ~= answer[index].toLane;
            }

            return lanes;
        });
    }

    /**
     * Finds a lane.
     *
     * Params:
     *   id = The lane's id.
     *
     * Returns: The lane with this id, or an empty Nullable when there is none.
     */
    Nullable!Lane find(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "select id, project_id, name, position, color, marks_done from lanes where id = $1";
        query.argsVariadic(id);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            return answer.length == 0 ? Nullable!Lane.init : answer[0].toLane.nullable;
        });
    }

    bool projectExists(UUID projectId)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from projects where id = $1";
        query.argsVariadic(projectId);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    /**
     * Gets the position just after a project's last lane.
     *
     * Params:
     *   projectId = The project's id.
     *   except = The id of the lane not to count, or UUID.init to count every lane of the
     *     project.
     *
     * Returns: The position just after the last lane other than `except`; 0 when there are no
     *   others.
     */
    int nextPosition(UUID projectId, UUID except)
    {
        QueryParams query;
        query.sqlCommand = "select coalesce(max(position) + 1, 0) as next from lanes where project_id = $1 and id <> $2";
        query.argsVariadic(projectId, except);

        return client.pickConnection((scope connection) {
            return connection.execParams(query)[0]["next"].as!int;
        });
    }

    /**
     * Checks whether a lane of a project already sits at a position.
     *
     * Params:
     *   projectId = The project's id.
     *   position = The position to check.
     *   except = The id of the lane not to count, or UUID.init to check against every lane of
     *     the project.
     *
     * Returns: Whether a lane other than `except` sits at this position.
     */
    bool positionTaken(UUID projectId, int position, UUID except)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from lanes where project_id = $1 and position = $2 and id <> $3";
        query.argsVariadic(projectId, position, except);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    /**
     * Inserts a lane.
     *
     * Fills in the id the database assigned it.
     *
     * Params:
     *   lane = The lane to insert.
     *
     * Returns: The same instance, so it can be used as an expression.
     */
    Lane add(Lane lane)
    {
        QueryParams query;
        query.sqlCommand = "insert into lanes (project_id, name, position, color, marks_done) values ($1, $2, $3, $4, $5) returning id";
        query.argsVariadic(lane.projectId, lane.name, lane.position.get, lane.color, lane.marksDone);

        lane.id = client.pickConnection((scope connection) {
            return connection.execParams(query)[0]["id"].as!UUID;
        });

        return lane;
    }

    /**
     * Writes a lane back over the row with its id, leaving its project as it is.
     *
     * Params:
     *   lane = The lane to write.
     *
     * Returns: False when no row has that id, in which case nothing was written.
     */
    bool update(Lane lane)
    {
        QueryParams query;
        query.sqlCommand = "update lanes set name = $2, position = $3, color = $4, marks_done = $5 where id = $1 returning id";
        query.argsVariadic(lane.id, lane.name, lane.position.get, lane.color, lane.marksDone);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    /**
     * Deletes a lane.
     *
     * Params:
     *   id = The lane's id.
     *
     * Returns: False when no row had it.
     */
    bool remove(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "delete from lanes where id = $1 returning id";
        query.argsVariadic(id);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }
}

private Lane toLane(immutable Row row)
{
    return new Lane(
        row["id"].as!UUID,
        row["project_id"].as!UUID,
        row["name"].as!string,
        row["position"].as!int,
        row["color"].as!string,
        row["marks_done"].as!bool
    );
}

/// Reads and writes rows of the tasks table.
class TaskRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

    /**
     * Gets a lane's tasks.
     *
     * Params:
     *   laneId = The lane's id.
     *
     * Returns: Every task of the lane, in lane order.
     */
    Task[] ofLane(UUID laneId)
    {
        QueryParams query;
        query.sqlCommand = "select id, lane_id, description, position from tasks where lane_id = $1 order by position";
        query.argsVariadic(laneId);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).toTasks;
        });
    }

    /**
     * Gets a project's tasks.
     *
     * Params:
     *   projectId = The project's id.
     *
     * Returns: Every task of the project, lane by lane in board order, and in lane order within
     *   each lane.
     */
    Task[] ofProject(UUID projectId)
    {
        QueryParams query;
        query.sqlCommand = "select t.id, t.lane_id, t.description, t.position from tasks t"
            ~ " join lanes l on l.id = t.lane_id where l.project_id = $1 order by l.position, t.position";
        query.argsVariadic(projectId);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).toTasks;
        });
    }

    /**
     * Finds a task.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: The task with this id, or an empty Nullable when there is none.
     */
    Nullable!Task find(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "select id, lane_id, description, position from tasks where id = $1";
        query.argsVariadic(id);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            return answer.length == 0 ? Nullable!Task.init : answer[0].toTask.nullable;
        });
    }

    /**
     * Gets a task's notes.
     *
     * Params:
     *   taskId = The task's id.
     *
     * Returns: The task's notes, newest first. Empty both for a task with none and for no task
     *   at all.
     */
    TaskNote[] notes(UUID taskId)
    {
        QueryParams query;
        query.sqlCommand = "select id, inserted_at, note, lane_color from task_notes"
            ~ " where task_id = $1 order by inserted_at desc";
        query.argsVariadic(taskId);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            TaskNote[] entries;
            entries.reserve(answer.length);

            foreach (index; 0 .. answer.length)
            {
                auto row = answer[index];
                auto color = row["lane_color"];
                entries ~= new TaskNote(
                    row["id"].as!UUID,
                    row["inserted_at"].as!SysTime,
                    row["note"].as!string,
                    color.isNull ? Nullable!string.init : color.as!string.nullable
                );
            }

            return entries;
        });
    }

    bool projectExists(UUID projectId)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from projects where id = $1";
        query.argsVariadic(projectId);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    /**
     * Finds the project a lane belongs to.
     *
     * Params:
     *   laneId = The lane's id.
     *
     * Returns: The project's id, or an empty Nullable when no lane has that id.
     */
    Nullable!UUID projectOfLane(UUID laneId)
    {
        QueryParams query;
        query.sqlCommand = "select project_id from lanes where id = $1";
        query.argsVariadic(laneId);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            return answer.length == 0 ? Nullable!UUID.init
                : answer[0]["project_id"].as!UUID.nullable;
        });
    }

    /**
     * Checks whether a lane's project lets a new task be added to it.
     *
     * Any lane does when the project's rule is any_lane, otherwise only its first lane does.
     *
     * Params:
     *   laneId = The lane's id.
     *
     * Returns: Whether a new task may be added to the lane. False when no lane has that id.
     */
    bool acceptsNewTasks(UUID laneId)
    {
        QueryParams query;
        query.sqlCommand = "select p.task_add_rule = $2"
            ~ " or l.position = (select min(position) from lanes where project_id = p.id) as accepts"
            ~ " from lanes l join projects p on p.id = l.project_id where l.id = $1";
        query.argsVariadic(laneId, cast(string) TaskAddRule.anyLane);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            return answer.length > 0 && answer[0]["accepts"].as!bool;
        });
    }

    /**
     * Inserts a task, with its creation in its notes.
     *
     * Fills in the id the database assigned it, and its position when it carries none.
     *
     * Params:
     *   task = The task to insert.
     *
     * Returns: The same instance, so it can be used as an expression.
     *
     * Throws: `PositionConflict` when another task of the lane is at its position.
     */
    Task add(Task task)
    {
        client.pickConnection((scope connection) {
            connection.exec("begin");
            scope (failure)
            {
                connection.exec("rollback");
            }
            connection.lockLane(task.laneId);
            connection.placeTask(task);

            QueryParams insert;
            insert.sqlCommand = "insert into tasks (lane_id, description, position) values ($1, $2, $3) returning id";
            insert.argsVariadic(task.laneId, task.description, task.position.get);
            task.id = connection.execParams(insert)[0]["id"].as!UUID;

            QueryParams created;
            created.sqlCommand = recordCreated;
            created.argsVariadic(task.id);
            connection.execParams(created);

            connection.exec("commit");
        });

        return task;
    }

    /**
     * Writes a task back over the row with its id, lane included.
     *
     * Adds a change of lane or description to its notes. A task carrying no position goes to
     * the bottom of its lane, and is given that position.
     *
     * Params:
     *   task = The task to write.
     *
     * Returns: False when no row has that id, in which case nothing was written.
     *
     * Throws: `PositionConflict` when another task of the lane is at its position.
     */
    bool update(Task task)
    {
        return client.pickConnection((scope connection) {
            connection.exec("begin");
            scope (failure)
            {
                connection.exec("rollback");
            }
            connection.lockLane(task.laneId);

            QueryParams current;
            current.sqlCommand = "select lane_id, description from tasks where id = $1 for update";
            current.argsVariadic(task.id);
            auto answer = connection.execParams(current);
            if (answer.length == 0)
            {
                connection.exec("rollback");
                return false;
            }
            const oldLaneId = answer[0]["lane_id"].as!UUID;
            const oldDescription = answer[0]["description"].as!string;
            connection.placeTask(task);

            QueryParams write;
            write.sqlCommand = "update tasks set lane_id = $2, description = $3, position = $4, updated_at = now() where id = $1";
            write.argsVariadic(task.id, task.laneId, task.description, task.position.get);
            connection.execParams(write);

            if (oldLaneId != task.laneId)
            {
                QueryParams moved;
                moved.sqlCommand = recordLaneChange;
                moved.argsVariadic(task.id, oldLaneId, task.laneId);
                connection.execParams(moved);
            }
            if (oldDescription != task.description)
            {
                QueryParams changed;
                changed.sqlCommand = recordDescriptionChange;
                changed.argsVariadic(task.id);
                connection.execParams(changed);
            }

            connection.exec("commit");
            return true;
        });
    }

    /**
     * Moves a task, and adds a change of lane to its notes.
     *
     * The position constraint is deferred to the commit, since the shift can briefly give two
     * tasks the same position.
     *
     * Params:
     *   id = The task's id.
     *   laneId = The lane it moves to.
     *   before = The task it goes just above, or UUID.init for the bottom of the lane.
     *
     * Throws: `PositionConflict` when `before` is no longer in the lane.
     */
    void move(UUID id, UUID laneId, UUID before)
    {
        client.pickConnection((scope connection) {
            connection.exec("begin");
            scope (failure)
            {
                connection.exec("rollback");
            }
            connection.exec("set constraints all deferred");
            connection.lockLane(laneId);

            QueryParams from;
            from.sqlCommand = "select lane_id from tasks where id = $1 for update";
            from.argsVariadic(id);
            const oldLaneId = connection.execParams(from)[0]["lane_id"].as!UUID;

            int position;
            if (before == UUID.init)
            {
                QueryParams next;
                next.sqlCommand = "select coalesce(max(position) + 1, 0) as next from tasks where lane_id = $1 and id <> $2";
                next.argsVariadic(laneId, id);
                position = connection.execParams(next)[0]["next"].as!int;
            }
            else
            {
                // Checked again here, since the caller's check came before the lock.
                QueryParams current;
                current.sqlCommand = "select position from tasks where id = $1 and lane_id = $2";
                current.argsVariadic(before, laneId);
                auto answer = connection.execParams(current);
                if (answer.length == 0)
                {
                    throw new PositionConflict("The beforeTaskId task is not in that lane.");
                }
                position = answer[0]["position"].as!int;

                QueryParams shift;
                shift.sqlCommand = "update tasks set position = position + 1 where lane_id = $1 and id <> $2 and position >= $3";
                shift.argsVariadic(laneId, id, position);
                connection.execParams(shift);
            }

            QueryParams place;
            place.sqlCommand = "update tasks set lane_id = $2, position = $3, updated_at = now() where id = $1";
            place.argsVariadic(id, laneId, position);
            connection.execParams(place);

            if (oldLaneId != laneId)
            {
                QueryParams moved;
                moved.sqlCommand = recordLaneChange;
                moved.argsVariadic(id, oldLaneId, laneId);
                connection.execParams(moved);
            }

            connection.exec("commit");
        });
    }

    /**
     * Finds the AI agent a task is assigned to.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: The agent's id, or an empty Nullable when the task is assigned to none or there
     *   is no such task.
     */
    Nullable!UUID assignedAiAgent(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "select assigned_ai_agent_id from tasks where id = $1";
        query.argsVariadic(id);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);
            if (answer.length == 0 || answer[0]["assigned_ai_agent_id"].isNull)
            {
                return Nullable!UUID.init;
            }

            return answer[0]["assigned_ai_agent_id"].as!UUID.nullable;
        });
    }

    /**
     * Assigns a task to an AI agent.
     *
     * Adds the assignment to its notes when it puts the task with another agent.
     *
     * Params:
     *   id = The task's id.
     *   agentId = The agent's id, or null to assign the task to none.
     *
     * Returns: False when no row has that id.
     */
    bool assignAiAgent(UUID id, Nullable!UUID agentId)
    {
        return client.pickConnection((scope connection) {
            connection.exec("begin");
            scope (failure)
            {
                connection.exec("rollback");
            }

            QueryParams current;
            current.sqlCommand = "select assigned_ai_agent_id from tasks where id = $1 for update";
            current.argsVariadic(id);
            auto answer = connection.execParams(current);
            if (answer.length == 0)
            {
                connection.exec("rollback");
                return false;
            }
            auto old = answer[0]["assigned_ai_agent_id"];
            const unchanged = old.isNull ? agentId.isNull : !agentId.isNull && old.as!UUID == agentId.get;

            QueryParams write;
            if (agentId.isNull)
            {
                write.sqlCommand = "update tasks set assigned_ai_agent_id = null, updated_at = now() where id = $1";
                write.argsVariadic(id);
            }
            else
            {
                write.sqlCommand = "update tasks set assigned_ai_agent_id = $2, updated_at = now() where id = $1";
                write.argsVariadic(id, agentId.get);
            }
            connection.execParams(write);

            if (!unchanged && !agentId.isNull)
            {
                QueryParams assigned;
                assigned.sqlCommand = recordAssignment;
                assigned.argsVariadic(id, agentId.get);
                connection.execParams(assigned);
            }

            connection.exec("commit");
            return true;
        });
    }

    /**
     * Adds to a task's notes that its scheduler failed to assign it to an agent.
     *
     * Params:
     *   id = The task's id.
     *   schedulerId = The scheduler's id.
     *
     * Returns: False, with nothing added, when the task or the scheduler is gone.
     */
    bool recordSchedulingFailure(UUID id, UUID schedulerId)
    {
        return recordAgentOutcome(id, schedulerId, `Scheduling by "%s" failed`);
    }

    /**
     * Adds to a task's notes that its scheduler found no agent for it.
     *
     * Params:
     *   id = The task's id.
     *   schedulerId = The scheduler's id.
     *
     * Returns: False, with nothing added, when the task or the scheduler is gone.
     */
    bool recordNoAgentFound(UUID id, UUID schedulerId)
    {
        return recordAgentOutcome(id, schedulerId, `Not assigned, since "%s" found no agent for it`);
    }

    /**
     * Adds to a task's notes that the agent it is assigned to failed to work on it.
     *
     * Params:
     *   id = The task's id.
     *   agentId = The agent's id.
     *
     * Returns: False, with nothing added, when the task or the agent is gone.
     */
    bool recordExecutionFailure(UUID id, UUID agentId)
    {
        return recordAgentOutcome(id, agentId, `Working on it failed for "%s"`);
    }

    /**
     * Adds a note of any text to a task.
     *
     * Params:
     *   id = The task's id.
     *   note = The note's text.
     *
     * Returns: False, with nothing added, when the task is gone.
     */
    bool addNote(UUID id, string note)
    {
        QueryParams query;
        query.sqlCommand = "insert into task_notes (task_id, note) select id, $2 from tasks where id = $1 returning id";
        query.argsVariadic(id, note);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    /**
     * Adds to a task's notes that there was no task scheduler agent to assign it.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: False, with nothing added, when the task is gone.
     */
    bool recordNoScheduler(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "insert into task_notes (task_id, note)"
            ~ " select id, 'Not assigned, since there is no task scheduler agent' from tasks where id = $1 returning id";
        query.argsVariadic(id);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    /// `note` is a format for SQL's format(), with the agent's name as its one %s.
    private bool recordAgentOutcome(UUID id, UUID agentId, string note)
    {
        QueryParams query;
        query.sqlCommand = recordAgentOutcomeNote;
        query.argsVariadic(id, agentId, note);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    /**
     * Deletes a task.
     *
     * Params:
     *   id = The task's id.
     *
     * Returns: False when no row had it.
     */
    bool remove(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "delete from tasks where id = $1 returning id";
        query.argsVariadic(id);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }
}

/* The task_notes rows, written in the same transaction as the change.
   The lane and agent names are copied into the text, and the colour of the
   lane the task went into alongside it, so a note still reads right after a
   lane or agent is renamed, recoloured or deleted. A move within a lane is not recorded. */

/// $1 is the task, which must already be stored.
private enum recordCreated = "insert into task_notes (task_id, note, lane_color)"
    ~ " select t.id, format('Created in \"%s\"', l.name), l.color from tasks t join lanes l on l.id = t.lane_id where t.id = $1";

/// $1 is the task, $2 the lane it left and $3 the lane it is now in.
private enum recordLaneChange = "insert into task_notes (task_id, note, lane_color)"
    ~ " select $1, format('Moved from \"%s\" to \"%s\"', f.name, t.name), t.color from lanes f, lanes t where f.id = $2 and t.id = $3";

/// $1 is the task.
private enum recordDescriptionChange = "insert into task_notes (task_id, note) values ($1, 'Description changed')";

/// $1 is the task and $2 the AI agent it is now assigned to.
private enum recordAssignment = "insert into task_notes (task_id, note)"
    ~ " select $1, format('Assigned to \"%s\"', name) from agents where id = $2";

/**
 * $1 is the task, $2 the agent that scheduled it or worked on it, and $3 the
 * note, a format with the agent's name as its one %s. A join rather than
 * values, so a task deleted while the agent was at it gets nothing.
 */
private enum recordAgentOutcomeNote = "insert into task_notes (task_id, note)"
    ~ " select t.id, format($3, a.name) from tasks t, agents a where t.id = $1 and a.id = $2 returning id";

/**
 * Thrown by a task write whose place in its lane clashes with the lane as it stands once
 * locked.
 *
 * A check made before the write cannot rule this out.
 */
class PositionConflict : Exception
{
    this(string message) @safe pure nothrow
    {
        super(message);
    }
}

/**
 * Locks the lane's row until the transaction ends. Every write that picks or
 * checks a task's position in the lane takes this lock first, so that writes
 * arriving together run one after the other instead of all reading the same
 * free position and failing on the unique constraint at commit.
 */
private void lockLane(Connection)(scope Connection connection, UUID laneId)
{
    QueryParams query;
    query.sqlCommand = "select 1 from lanes where id = $1 for update";
    query.argsVariadic(laneId);
    connection.execParams(query);
}

/**
 * Gives a task carrying no position the one just after its lane's last other
 * task, and throws `PositionConflict` when another task of the lane already
 * has the one it carries. The lane must be locked.
 */
private void placeTask(Connection)(scope Connection connection, Task task)
{
    if (task.position.isNull)
    {
        QueryParams next;
        next.sqlCommand = "select coalesce(max(position) + 1, 0) as next from tasks where lane_id = $1 and id <> $2";
        next.argsVariadic(task.laneId, task.id);
        task.position = connection.execParams(next)[0]["next"].as!int;
        return;
    }

    QueryParams taken;
    taken.sqlCommand = "select 1 from tasks where lane_id = $1 and position = $2 and id <> $3";
    taken.argsVariadic(task.laneId, task.position.get, task.id);
    if (connection.execParams(taken).length > 0)
    {
        throw new PositionConflict(format("Another task of the lane is already at position %s.", task.position.get));
    }
}

private Task[] toTasks(Answer answer)
{
    Task[] tasks;
    tasks.reserve(answer.length);

    foreach (index; 0 .. answer.length)
    {
        tasks ~= answer[index].toTask;
    }

    return tasks;
}

private Task toTask(immutable Row row)
{
    return new Task(
        row["id"].as!UUID,
        row["lane_id"].as!UUID,
        row["description"].as!string,
        row["position"].as!int
    );
}

/**
 * Reads the runtimes and models tables.
 *
 * They hold fixed data: they are written only by the schema, never through the application.
 */
class RuntimeRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

    /**
     * Gets every runtime.
     *
     * Returns: Every runtime, by name.
     */
    Runtime[] all()
    {
        QueryParams query;
        query.sqlCommand = "select id, name from runtimes order by name";

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            Runtime[] runtimes;
            runtimes.reserve(answer.length);

            foreach (index; 0 .. answer.length)
            {
                runtimes ~= new Runtime(answer[index]["id"].as!string, answer[index]["name"]
                    .as!string);
            }

            return runtimes;
        });
    }

    /**
     * Gets every model.
     *
     * Returns: Every model, by runtime and then by name, with the effort levels it takes.
     */
    Model[] models()
    {
        QueryParams query;
        query.sqlCommand = "select id, name, runtime from models order by runtime, name";

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            Model[] models;
            models.reserve(answer.length);
            Model[string] byId;

            foreach (index; 0 .. answer.length)
            {
                auto row = answer[index];
                auto model = new Model(row["id"].as!string, row["name"].as!string, row["runtime"]
                    .as!string);
                models ~= model;
                byId[model.id] = model;
            }

            QueryParams levels;
            levels.sqlCommand = "select me.model, e.id, e.name from model_effort_levels me"
                ~ " join effort_levels e on e.id = me.effort_level order by e.position";
            auto levelAnswer = connection.execParams(levels);

            foreach (index; 0 .. levelAnswer.length)
            {
                auto row = levelAnswer[index];
                byId[row["model"].as!string].effortLevels ~= new EffortLevel(row["id"].as!string, row["name"]
                    .as!string);
            }

            return models;
        });
    }

    /**
     * Finds a runtime's name.
     *
     * Params:
     *   id = The runtime's id.
     *
     * Returns: The name of the runtime with this id, or an empty Nullable when there is none.
     */
    Nullable!string name(string id)
    {
        QueryParams query;
        query.sqlCommand = "select name from runtimes where id = $1";
        query.argsVariadic(id);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            return answer.length == 0 ? Nullable!string.init : answer[0]["name"]
                .as!string.nullable;
        });
    }

    /**
     * Checks whether a runtime offers a model.
     *
     * Params:
     *   runtime = The runtime's id.
     *   model = The model's id.
     *
     * Returns: Whether the runtime offers the model.
     */
    bool offers(string runtime, string model)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from models where runtime = $1 and id = $2";
        query.argsVariadic(runtime, model);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    /**
     * Checks whether a model takes an effort level.
     *
     * Params:
     *   model = The model's id.
     *   effort = The effort level's id.
     *
     * Returns: Whether the model takes the effort level.
     */
    bool takes(string model, string effort)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from model_effort_levels where model = $1 and effort_level = $2";
        query.argsVariadic(model, effort);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }
}

/// Reads and writes rows of the agents table.
class AgentRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

    /**
     * Gets every agent.
     *
     * There can be any number of task schedulers.
     *
     * Returns: Every agent, the task schedulers first, since they direct the others, and by
     *   name within each group.
     */
    Agent[] all()
    {
        QueryParams query;
        query.sqlCommand = "select id, name, runtime, model, effort, task_scheduler, instructions from agents order by task_scheduler desc, name";

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            Agent[] agents;
            agents.reserve(answer.length);
            Agent[UUID] byId;

            foreach (index; 0 .. answer.length)
            {
                auto agent = answer[index].toAgent;
                agents ~= agent;
                byId[agent.id] = agent;
            }

            QueryParams labels;
            labels.sqlCommand = "select agent_id, label from agent_labels order by label";
            auto labelAnswer = connection.execParams(labels);

            foreach (index; 0 .. labelAnswer.length)
            {
                byId[labelAnswer[index]["agent_id"].as!UUID].labels ~= labelAnswer[index]["label"]
                    .as!string;
            }

            return agents;
        });
    }

    /**
     * Finds an agent.
     *
     * Params:
     *   id = The agent's id.
     *
     * Returns: The agent with this id, or an empty Nullable when there is none.
     */
    Nullable!Agent find(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "select id, name, runtime, model, effort, task_scheduler, instructions from agents where id = $1";
        query.argsVariadic(id);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            if (answer.length == 0)
            {
                return Nullable!Agent.init;
            }

            auto agent = answer[0].toAgent;
            agent.labels = connection.labelsOf(id);

            return agent.nullable;
        });
    }

    /**
     * Checks whether an agent already has a name.
     *
     * Params:
     *   name = The name to look for.
     *   except = The id of the agent not to count, or UUID.init to check against every agent.
     *
     * Returns: Whether an agent other than `except` has this name.
     */
    bool nameTaken(string name, UUID except)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from agents where name = $1 and id <> $2";
        query.argsVariadic(name, except);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    /**
     * Inserts an agent and its labels in one transaction.
     *
     * Fills in the id the database assigned it.
     *
     * Params:
     *   agent = The agent to insert.
     *
     * Returns: The same instance, so it can be used as an expression.
     */
    Agent add(Agent agent)
    {
        QueryParams query;
        query.sqlCommand = "insert into agents (name, runtime, model, effort, task_scheduler, instructions) values ($1, $2, $3, $4, $5, $6) returning id";
        query.argsVariadic(agent.name, agent.runtime, agent.model, agent.effort, agent.taskScheduler, agent.instructions);

        client.pickConnection((scope connection) {
            connection.exec("begin");
            scope (failure)
            {
                connection.exec("rollback");
            }

            agent.id = connection.execParams(query)[0]["id"].as!UUID;
            connection.insertLabels(agent.id, agent.labels);

            connection.exec("commit");
        });

        return agent;
    }

    /**
     * Writes an agent back over the row with its id, and gives it exactly its labels, in one
     * transaction.
     *
     * Params:
     *   agent = The agent to write.
     *
     * Returns: False when no row has that id, in which case nothing was written.
     */
    bool update(Agent agent)
    {
        QueryParams query;
        query.sqlCommand = "update agents set name = $2, runtime = $3, model = $4, effort = $5, task_scheduler = $6, instructions = $7 where id = $1 returning id";
        query.argsVariadic(agent.id, agent.name, agent.runtime, agent.model, agent.effort, agent.taskScheduler, agent.instructions);

        return client.pickConnection((scope connection) {
            connection.exec("begin");
            scope (failure)
            {
                connection.exec("rollback");
            }

            if (connection.execParams(query).length == 0)
            {
                connection.exec("rollback");
                return false;
            }

            QueryParams clear;
            clear.sqlCommand = "delete from agent_labels where agent_id = $1";
            clear.argsVariadic(agent.id);
            connection.execParams(clear);
            connection.insertLabels(agent.id, agent.labels);

            connection.exec("commit");
            return true;
        });
    }

    /**
     * Deletes an agent.
     *
     * Params:
     *   id = The agent's id.
     *
     * Returns: False when no row has that id.
     */
    bool remove(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "delete from agents where id = $1 returning id";
        query.argsVariadic(id);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }
}

/// The labels of the agent with this id, in alphabetical order.
private string[] labelsOf(Connection)(scope Connection connection, UUID agentId)
{
    QueryParams query;
    query.sqlCommand = "select label from agent_labels where agent_id = $1 order by label";
    query.argsVariadic(agentId);
    auto answer = connection.execParams(query);

    string[] labels;
    labels.reserve(answer.length);

    foreach (index; 0 .. answer.length)
    {
        labels ~= answer[index]["label"].as!string;
    }

    return labels;
}

private void insertLabels(Connection)(scope Connection connection, UUID agentId, string[] labels)
{
    foreach (label; labels)
    {
        QueryParams query;
        query.sqlCommand = "insert into agent_labels (agent_id, label) values ($1, $2)";
        query.argsVariadic(agentId, label);
        connection.execParams(query);
    }
}

private Agent toAgent(immutable Row row)
{
    return new Agent(
        row["id"].as!UUID,
        row["name"].as!string,
        row["runtime"].as!string,
        row["model"].as!string,
        row["effort"].as!string,
        row["task_scheduler"].as!bool,
        row["instructions"].as!string
    );
}

/// Reads and writes rows of the agent_log table.
class AgentLogRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

    /**
     * Gets an agent's log.
     *
     * Params:
     *   agentId = The agent's id.
     *
     * Returns: The agent's log, newest first. Empty both for an agent with none and for no agent
     *   at all.
     */
    AgentLogEntry[] ofAgent(UUID agentId)
    {
        QueryParams query;
        query.sqlCommand = "select id, agent_id, created_at, prompt, result from agent_log"
            ~ " where agent_id = $1 order by created_at desc";
        query.argsVariadic(agentId);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            AgentLogEntry[] entries;
            entries.reserve(answer.length);

            foreach (index; 0 .. answer.length)
            {
                auto row = answer[index];
                auto result = row["result"];
                entries ~= new AgentLogEntry(
                    row["id"].as!UUID,
                    row["agent_id"].as!UUID,
                    row["created_at"].as!SysTime,
                    row["prompt"].as!string,
                    result.isNull ? Nullable!string.init : result.as!string.nullable
                );
            }

            return entries;
        });
    }

    /**
     * Inserts a log entry.
     *
     * Fills in the id and time the database assigned it.
     *
     * Params:
     *   entry = The entry to insert.
     *
     * Returns: The same instance, so it can be used as an expression.
     */
    AgentLogEntry add(AgentLogEntry entry)
    {
        QueryParams query;
        query.sqlCommand = "insert into agent_log (agent_id, prompt, result) values ($1, $2, $3) returning id, created_at";
        query.argsVariadic(entry.agentId, entry.prompt, entry.result);

        client.pickConnection((scope connection) {
            auto row = connection.execParams(query)[0];
            entry.id = row["id"].as!UUID;
            entry.createdAt = row["created_at"].as!SysTime;
        });

        return entry;
    }

    /**
     * Records an agent's answer to a log entry's prompt.
     *
     * Params:
     *   id = The entry's id.
     *   result = The agent's answer.
     *
     * Returns: False when no row has that id, in which case nothing was written.
     */
    bool setResult(UUID id, string result)
    {
        QueryParams query;
        query.sqlCommand = "update agent_log set result = $2 where id = $1 returning id";
        query.argsVariadic(id, result);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }
}

/**
 * Reads the defaults table, a value per key.
 *
 * Written only by the schema for now: nothing in the UI changes a default yet.
 */
class DefaultRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

    /**
     * Gets every default.
     *
     * Returns: Every default, by key.
     */
    Default[] all()
    {
        QueryParams query;
        query.sqlCommand = "select key, value from defaults order by key";

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);

            Default[] defaults;
            defaults.reserve(answer.length);

            foreach (index; 0 .. answer.length)
            {
                defaults ~= new Default(answer[index]["key"].as!string, answer[index]["value"]
                    .as!string);
            }

            return defaults;
        });
    }
}
