module repository.postgres;

import vibe.db.postgresql;

import std.datetime.systime : SysTime;
import std.format : format;
import std.typecons : Nullable, nullable;
import std.uuid : UUID;

import model : Agent, AgentLogEntry, AgentStatus, Default, EffortLevel, Lane, Model, Project, Runtime, Task, TaskAddRule,
    TaskNote, toAgentStatus, toTaskAddRule;
import repository : IAgentLogRepository, IAgentRepository, IDefaultRepository, ILaneRepository, IProjectRepository,
    IRuntimeRepository, ITaskRepository, PositionConflict;

/**
 * The assignment to ai_paused in an update that sets managed_by_ai to $6. A
 * project that stops being managed by AI has its agents paused, and one
 * that starts being managed has them running; otherwise they stay as they
 * were. On the right of a set, managed_by_ai is still the old value.
 */
private enum pausedOnceManaged =
    "ai_paused = case when managed_by_ai = $6 then ai_paused else not $6 end";

/// IProjectRepository over postgres.
class PostgresProjectRepository : IProjectRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

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

    bool setAiPaused(UUID id, bool paused)
    {
        QueryParams query;
        query.sqlCommand = "update projects set ai_paused = $2 where id = $1 returning id";
        query.argsVariadic(id, paused);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

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

/// ILaneRepository over postgres.
class PostgresLaneRepository : ILaneRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

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

    int nextPosition(UUID projectId, UUID except)
    {
        QueryParams query;
        query.sqlCommand = "select coalesce(max(position) + 1, 0) as next from lanes where project_id = $1 and id <> $2";
        query.argsVariadic(projectId, except);

        return client.pickConnection((scope connection) {
            return connection.execParams(query)[0]["next"].as!int;
        });
    }

    bool positionTaken(UUID projectId, int position, UUID except)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from lanes where project_id = $1 and position = $2 and id <> $3";
        query.argsVariadic(projectId, position, except);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

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

    bool update(Lane lane)
    {
        QueryParams query;
        query.sqlCommand = "update lanes set name = $2, position = $3, color = $4, marks_done = $5 where id = $1 returning id";
        query.argsVariadic(lane.id, lane.name, lane.position.get, lane.color, lane.marksDone);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

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

/// ITaskRepository over postgres.
class PostgresTaskRepository : ITaskRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

    Task[] ofLane(UUID laneId)
    {
        QueryParams query;
        query.sqlCommand = "select id, lane_id, description, position from tasks where lane_id = $1 order by position";
        query.argsVariadic(laneId);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).toTasks;
        });
    }

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

    Task[] awaitingScheduling()
    {
        QueryParams query;
        query.sqlCommand = "select t.id, t.lane_id, t.description, t.position from tasks t"
            ~ " join lanes l on l.id = t.lane_id join projects p on p.id = l.project_id"
            ~ " where t.agent_status = 'to_be_scheduled' and t.assigned_ai_agent_id is null and not l.marks_done"
            ~ " and p.managed_by_ai and not p.ai_paused order by t.created_at";

        return client.pickConnection((scope connection) {
            return connection.execParams(query).toTasks;
        });
    }

    Task[] awaitingExecution()
    {
        QueryParams query;
        query.sqlCommand = "select t.id, t.lane_id, t.description, t.position from tasks t"
            ~ " join lanes l on l.id = t.lane_id join projects p on p.id = l.project_id"
            ~ " where t.agent_status = 'scheduled' and not l.marks_done and p.managed_by_ai and not p.ai_paused"
            ~ " order by t.created_at";

        return client.pickConnection((scope connection) {
            return connection.execParams(query).toTasks;
        });
    }

    bool changeAgentStatus(UUID id, AgentStatus from, AgentStatus to)
    {
        QueryParams query;
        query.sqlCommand = "update tasks set agent_status = $3, updated_at = now()"
            ~ " where id = $1 and agent_status = $2 returning id";
        query.argsVariadic(id, cast(string) from, cast(string) to);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    ulong changeAgentStatuses(AgentStatus from, AgentStatus to)
    {
        QueryParams query;
        query.sqlCommand = "update tasks set agent_status = $2, updated_at = now() where agent_status = $1 returning id";
        query.argsVariadic(cast(string) from, cast(string) to);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length;
        });
    }

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

    Task add(Task task, Nullable!AgentStatus agentStatus)
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
            insert.sqlCommand = "insert into tasks (lane_id, description, position, agent_status)"
                ~ " values ($1, $2, $3, $4) returning id";
            auto status = agentStatus.isNull ? Nullable!string.init : (cast(string) agentStatus.get).nullable;
            insert.argsVariadic(task.laneId, task.description, task.position.get, status);
            task.id = connection.execParams(insert)[0]["id"].as!UUID;

            QueryParams created;
            created.sqlCommand = recordCreated;
            created.argsVariadic(task.id);
            connection.execParams(created);

            connection.exec("commit");
        });

        return task;
    }

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

    bool recordSchedulingFailure(UUID id, UUID schedulerId)
    {
        return recordAgentOutcome(id, schedulerId, `Scheduling by "%s" failed`);
    }

    bool recordNoAgentFound(UUID id, UUID schedulerId)
    {
        return recordAgentOutcome(id, schedulerId, `Not assigned, since "%s" found no agent for it`);
    }

    bool recordExecutionFailure(UUID id, UUID agentId)
    {
        return recordAgentOutcome(id, agentId, `Working on it failed for "%s"`);
    }

    bool addNote(UUID id, string note)
    {
        QueryParams query;
        query.sqlCommand = "insert into task_notes (task_id, note) select id, $2 from tasks where id = $1 returning id";
        query.argsVariadic(id, note);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    Nullable!AgentStatus agentStatus(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "select agent_status from tasks where id = $1";
        query.argsVariadic(id);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);
            if (answer.length == 0 || answer[0]["agent_status"].isNull)
            {
                return Nullable!AgentStatus.init;
            }

            return answer[0]["agent_status"].as!string.toAgentStatus.nullable;
        });
    }

    bool reschedule(UUID id)
    {
        return client.pickConnection((scope connection) {
            connection.exec("begin");
            scope (failure)
            {
                connection.exec("rollback");
            }

            QueryParams update;
            update.sqlCommand = "update tasks set assigned_ai_agent_id = null, agent_status = 'to_be_scheduled', updated_at = now()"
                ~ " where id = $1 and agent_status is distinct from 'scheduling' and agent_status is distinct from 'executing'"
                ~ " returning id";
            update.argsVariadic(id);
            if (connection.execParams(update).length == 0)
            {
                connection.exec("rollback");
                return false;
            }

            QueryParams note;
            note.sqlCommand = "insert into task_notes (task_id, note) values ($1, 'Handed back to the task scheduler')";
            note.argsVariadic(id);
            connection.execParams(note);

            connection.exec("commit");
            return true;
        });
    }

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

/// IRuntimeRepository over postgres.
class PostgresRuntimeRepository : IRuntimeRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

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

    bool offers(string runtime, string model)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from models where runtime = $1 and id = $2";
        query.argsVariadic(runtime, model);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

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

/// IAgentRepository over postgres.
class PostgresAgentRepository : IAgentRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

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

    Nullable!int maxParallelTasks(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "select max_parallel_tasks from agents where id = $1";
        query.argsVariadic(id);

        return client.pickConnection((scope connection) {
            auto answer = connection.execParams(query);
            if (answer.length == 0 || answer[0]["max_parallel_tasks"].isNull)
            {
                return Nullable!int.init;
            }

            return answer[0]["max_parallel_tasks"].as!int.nullable;
        });
    }

    bool nameTaken(string name, UUID except)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from agents where name = $1 and id <> $2";
        query.argsVariadic(name, except);

        return client.pickConnection((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

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

/// IAgentLogRepository over postgres.
class PostgresAgentLogRepository : IAgentLogRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

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

/// IDefaultRepository over postgres.
class PostgresDefaultRepository : IDefaultRepository
{
    private PostgresClient client;

    this(PostgresClient client)
    {
        this.client = client;
    }

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
