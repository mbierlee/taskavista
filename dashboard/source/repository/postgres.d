/**
 * Taskavista
 *
 * The repositories on postgres.
 *
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2026 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

module repository.postgres;

import vibe.core.task : TaskLocal, VibeTask = Task;
import vibe.db.postgresql;

import std.algorithm.iteration : map;
import std.array : join;
import std.datetime.systime : SysTime;
import std.format : format;
import std.typecons : Nullable, nullable;
import std.uuid : UUID;

import model : Agent, AgentLogEntry, AgentStatus, Default, EffortLevel, Lane, Model, Project, RunUsage, Runtime, Task,
    TaskNote, toAgentStatus;
import repository : Deadlock, ForeignKeyViolation, IAgentLogRepository, IAgentRepository, IDefaultRepository,
    ILaneRepository, IProjectRepository, IRuntimeRepository, ITaskRepository, ITransactional, PositionConflict,
    UniqueViolation;

/**
 * How every postgres repository reaches the database, and the transactions the services open.
 *
 * It is the only holder of the connection pool, so that no repository call can take a connection
 * of its own while its task has a transaction open on another: that call would wait on the
 * transaction's locks, and postgres, seeing two sessions rather than a circle, would let it wait
 * forever. The open transaction is kept per vibe.d task, which is one per HTTP request.
 */
class PostgresConnections : ITransactional
{
    private PostgresClient client;

    /// The transaction each task has open. Static, as a TaskLocal must be.
    private static TaskLocal!OpenSlot open;

    this(string connectionString, uint poolSize)
    {
        client = new PostgresClient(connectionString, poolSize);
    }

    void run(scope bool delegate() work)
    {
        auto outer = current();
        if (outer !is null)
        {
            if (!work())
            {
                outer.rollbackOnly = true;
            }

            return;
        }

        auto transaction = new OpenTransaction;
        const committed = client.pickConnection((scope connection) {
            return translated({
                connection.exec("begin");
                transaction.connection = connection.__conn;
                open = OpenSlot(transaction);
                scope (exit)
                {
                    open = OpenSlot.init;
                }
                scope (failure)
                {
                    connection.exec("rollback");
                }

                const commit = work() && !transaction.rollbackOnly;
                connection.exec(commit ? "commit" : "rollback");
                return commit;
            });
        });

        // Once the connection is back in the pool and the task has no transaction open, so that
        // what they run is a transaction of its own.
        if (committed)
        {
            foreach (dg; transaction.afterCommit)
            {
                dg();
            }
        }
    }

    void afterCommit(void delegate() dg)
    {
        auto transaction = current();
        if (transaction is null)
        {
            dg();
            return;
        }

        transaction.afterCommit ~= dg;
    }

    /**
     * Runs dg on a connection: the one of the transaction the task has open, or one from the pool.
     * For statements that need no transaction of their own.
     */
    T use(T)(scope T delegate(scope Connection connection) dg)
    {
        auto transaction = current();
        if (transaction !is null)
        {
            return translated(() => dg(transaction.connection));
        }

        return client.pickConnection((scope connection) {
            return translated(() => dg(connection.__conn));
        });
    }

    /**
     * Runs dg as one transaction: its own, or part of the one the task has open, in which case
     * it neither commits nor rolls back, and what it throws rolls back the whole. Either way, dg
     * returning early, with nothing written, needs no rollback.
     */
    T transaction(T)(scope T delegate(scope Connection connection) dg)
    {
        auto transaction = current();
        if (transaction !is null)
        {
            return translated(() => dg(transaction.connection));
        }

        return client.pickConnection((scope connection) {
            return translated({
                connection.exec("begin");
                scope (failure)
                {
                    connection.exec("rollback");
                }

                static if (is(T == void))
                {
                    dg(connection.__conn);
                    connection.exec("commit");
                }
                else
                {
                    auto result = dg(connection.__conn);
                    connection.exec("commit");
                    return result;
                }
            });
        });
    }

    /// The transaction the task has open, or null, as code outside any task never has one.
    private static OpenTransaction current()
    {
        return VibeTask.getThis() == VibeTask.init ? null : open.storage.transaction;
    }
}

/**
 * Where PostgresConnections keeps a task's open transaction. A struct, since a TaskLocal of a
 * class type would build an object in its slot, which only has room for a reference.
 */
private struct OpenSlot
{
    /// The transaction, or null when none is open.
    OpenTransaction transaction;
}

/// A transaction run by PostgresConnections.run, while it is open.
private class OpenTransaction
{
    Connection connection;
    /// What to run once it has committed.
    void delegate()[] afterCommit;
    /// Set by a run inside it whose work asked for a rollback, which can only be of the whole.
    bool rollbackOnly;
}

/**
 * Runs dg, turning the errors a caller is meant to tell apart into the exceptions the repository
 * interfaces name, by their SQLSTATE.
 */
private T translated(T)(scope T delegate() dg)
{
    try
    {
        return dg();
    }
    catch (ResponseException exception)
    {
        switch (exception.resultErrorField(PG_DIAG_SQLSTATE))
        {
            case "23505":
                throw new UniqueViolation(exception.resultErrorField(PG_DIAG_CONSTRAINT_NAME),
                    exception.msg);
            case "23503":
                throw new ForeignKeyViolation(exception.resultErrorField(PG_DIAG_CONSTRAINT_NAME),
                    exception.msg);
            case "40P01":
                throw new Deadlock(exception.msg);
            default:
                throw exception;
        }
    }
}

/// A project's columns, for a select from projects p.
private enum projectColumns = "p.id, p.name, p.slug, p.description, p.ai_paused, p.working_dir";

/// IProjectRepository over postgres.
class PostgresProjectRepository : IProjectRepository
{
    private PostgresConnections connections;

    this(PostgresConnections connections)
    {
        this.connections = connections;
    }

    Project[] all()
    {
        QueryParams query;
        query.sqlCommand = "select " ~ projectColumns ~ " from projects p order by p.name";

        return connections.use((scope connection) {
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
        query.sqlCommand = "select " ~ projectColumns ~ " from projects p where p.id = $1";
        query.argsVariadic(id);

        return connections.use((scope connection) {
            auto answer = connection.execParams(query);

            return answer.length == 0 ? Nullable!Project.init : answer[0].toProject.nullable;
        });
    }

    Nullable!Project findBySlug(string slug)
    {
        QueryParams query;
        query.sqlCommand = "select " ~ projectColumns ~ " from projects p where p.slug = $1";
        query.argsVariadic(slug);

        return connections.use((scope connection) {
            auto answer = connection.execParams(query);

            return answer.length == 0 ? Nullable!Project.init : answer[0].toProject.nullable;
        });
    }

    bool lock(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from projects where id = $1 for update";
        query.argsVariadic(id);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    Nullable!string slugOwner(string slug, UUID except)
    {
        QueryParams query;
        query.sqlCommand = "select name from projects where slug = $1 and id <> $2";
        query.argsVariadic(slug, except);

        return connections.use((scope connection) {
            auto answer = connection.execParams(query);

            return answer.length == 0 ? Nullable!string.init : answer[0]["name"]
                .as!string.nullable;
        });
    }

    bool workingDirTaken(string workingDir, UUID except)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from projects where working_dir = $1 and id <> $2";
        query.argsVariadic(workingDir, except);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    Project add(Project project)
    {
        QueryParams query;
        query.sqlCommand = "insert into projects (name, slug, description, ai_paused, working_dir) values ($1, $2, $3, $4, $5)"
            ~ " returning id";
        query.argsVariadic(project.name, project.slug, project.description, project.aiPaused, project.workingDir);

        connections.use((scope connection) {
            project.id = connection.execParams(query)[0]["id"].as!UUID;
        });

        return project;
    }

    bool update(Project project)
    {
        QueryParams query;
        query.sqlCommand = "update projects set name = $2, slug = $3, description = $4, working_dir = $5 where id = $1"
            ~ " returning id";
        query.argsVariadic(project.id, project.name, project.slug, project.description, project.workingDir);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    bool setAiPaused(UUID id, bool paused)
    {
        QueryParams query;
        query.sqlCommand = "update projects set ai_paused = $2 where id = $1 returning id";
        query.argsVariadic(id, paused);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    void addWithLanes(Project project, Lane[] lanes)
    {
        connections.transaction((scope connection) {
            QueryParams insert;
            insert.sqlCommand = "insert into projects (name, slug, description, ai_paused, working_dir) values ($1, $2, $3, $4, $5)"
                ~ " returning id";
            insert.argsVariadic(project.name, project.slug, project.description, project.aiPaused, project.workingDir);
            project.id = connection.execParams(insert)[0]["id"].as!UUID;

            foreach (lane; lanes)
            {
                lane.projectId = project.id;

                QueryParams add;
                add.sqlCommand = "insert into lanes (project_id, name, position, color, marks_done, accepts_new_tasks, agents_pick_up) values ($1, $2, $3, $4, $5, $6, $7) returning id";
                add.argsVariadic(lane.projectId, lane.name, lane.position.get, lane.color, lane
                    .marksDone, lane.acceptsNewTasks, lane.agentsPickUp);
                lane.id = connection.execParams(add)[0]["id"].as!UUID;
            }
        });
    }

    bool replaceWithLanes(Project project, Lane[] lanes, UUID[] removed)
    {
        return connections.transaction((scope connection) {
            connection.exec("set constraints all deferred");

            QueryParams update;
            update.sqlCommand = "update projects set name = $2, slug = $3, description = $4, working_dir = $5 where id = $1"
                ~ " returning id";
            update.argsVariadic(project.id, project.name, project.slug, project.description, project.workingDir);
            if (connection.execParams(update).length == 0)
            {
                return false;
            }

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
                    write.sqlCommand = "insert into lanes (project_id, name, position, color, marks_done, accepts_new_tasks, agents_pick_up) values ($1, $2, $3, $4, $5, $6, $7) returning id";
                    write.argsVariadic(lane.projectId, lane.name, lane.position.get, lane.color, lane
                        .marksDone, lane.acceptsNewTasks, lane.agentsPickUp);
                    lane.id = connection.execParams(write)[0]["id"].as!UUID;
                }
                else
                {
                    write.sqlCommand = "update lanes set name = $2, position = $3, color = $4, marks_done = $5, accepts_new_tasks = $6,"
                        ~ " agents_pick_up = $7 where id = $1";
                    write.argsVariadic(lane.id, lane.name, lane.position.get, lane.color, lane
                        .marksDone, lane.acceptsNewTasks, lane.agentsPickUp);
                    connection.execParams(write);
                }
            }

            return true;
        });
    }

    bool remove(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "delete from projects where id = $1 returning id";
        query.argsVariadic(id);

        return connections.use((scope connection) {
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
        row["ai_paused"].as!bool,
        row["working_dir"].as!string
    );
}

/// ILaneRepository over postgres.
class PostgresLaneRepository : ILaneRepository
{
    private PostgresConnections connections;

    this(PostgresConnections connections)
    {
        this.connections = connections;
    }

    Lane[] ofProject(UUID projectId)
    {
        QueryParams query;
        query.sqlCommand = "select id, project_id, name, position, color, marks_done, accepts_new_tasks, agents_pick_up from lanes where project_id = $1 order by position";
        query.argsVariadic(projectId);

        return connections.use((scope connection) {
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
        query.sqlCommand = "select id, project_id, name, position, color, marks_done, accepts_new_tasks, agents_pick_up from lanes where id = $1";
        query.argsVariadic(id);

        return connections.use((scope connection) {
            auto answer = connection.execParams(query);

            return answer.length == 0 ? Nullable!Lane.init : answer[0].toLane.nullable;
        });
    }

    bool lock(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from lanes where id = $1 for update";
        query.argsVariadic(id);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    bool projectExists(UUID projectId)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from projects where id = $1";
        query.argsVariadic(projectId);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    int nextPosition(UUID projectId, UUID except)
    {
        QueryParams query;
        query.sqlCommand = "select coalesce(max(position) + 1, 0) as next from lanes where project_id = $1 and id <> $2";
        query.argsVariadic(projectId, except);

        return connections.use((scope connection) {
            return connection.execParams(query)[0]["next"].as!int;
        });
    }

    bool positionTaken(UUID projectId, int position, UUID except)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from lanes where project_id = $1 and position = $2 and id <> $3";
        query.argsVariadic(projectId, position, except);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    Lane add(Lane lane)
    {
        QueryParams query;
        query.sqlCommand = "insert into lanes (project_id, name, position, color, marks_done, accepts_new_tasks, agents_pick_up) values ($1, $2, $3, $4, $5, $6, $7) returning id";
        query.argsVariadic(lane.projectId, lane.name, lane.position.get, lane.color, lane.marksDone,
            lane.acceptsNewTasks, lane.agentsPickUp);

        lane.id = connections.use((scope connection) {
            return connection.execParams(query)[0]["id"].as!UUID;
        });

        return lane;
    }

    bool update(Lane lane)
    {
        QueryParams query;
        query.sqlCommand = "update lanes set name = $2, position = $3, color = $4, marks_done = $5, accepts_new_tasks = $6,"
            ~ " agents_pick_up = $7 where id = $1 returning id";
        query.argsVariadic(lane.id, lane.name, lane.position.get, lane.color, lane.marksDone, lane.acceptsNewTasks,
            lane.agentsPickUp);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    bool remove(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "delete from lanes where id = $1 returning id";
        query.argsVariadic(id);

        return connections.use((scope connection) {
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
        row["marks_done"].as!bool,
        row["accepts_new_tasks"].as!bool,
        row["agents_pick_up"].as!bool
    );
}

/// ITaskRepository over postgres.
class PostgresTaskRepository : ITaskRepository
{
    private PostgresConnections connections;

    this(PostgresConnections connections)
    {
        this.connections = connections;
    }

    Task[] ofLane(UUID laneId)
    {
        QueryParams query;
        query.sqlCommand = "select " ~ taskColumns ~ " from tasks t where t.lane_id = $1 order by t.position";
        query.argsVariadic(laneId);

        return connections.use((scope connection) {
            return connection.execParams(query).toTasks;
        });
    }

    Task[] ofProject(UUID projectId)
    {
        QueryParams query;
        query.sqlCommand = "select " ~ taskColumns ~ " from tasks t"
            ~ " join lanes l on l.id = t.lane_id where l.project_id = $1 order by l.position, t.position";
        query.argsVariadic(projectId);

        return connections.use((scope connection) {
            return connection.execParams(query).toTasks;
        });
    }

    Nullable!Task find(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "select " ~ taskColumns ~ " from tasks t where t.id = $1";
        query.argsVariadic(id);

        return connections.use((scope connection) {
            auto answer = connection.execParams(query);

            return answer.length == 0 ? Nullable!Task.init : answer[0].toTask.nullable;
        });
    }

    bool lock(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from tasks where id = $1 for update";
        query.argsVariadic(id);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    Task[] awaitingScheduling()
    {
        QueryParams query;
        query.sqlCommand = "select " ~ taskColumns ~ " from tasks t"
            ~ " join lanes l on l.id = t.lane_id join projects p on p.id = l.project_id"
            ~ " where t.agent_status = 'to_be_scheduled' and t.assigned_ai_agent_id is null and not l.marks_done"
            ~ " and l.agents_pick_up and not p.ai_paused order by t.created_at";

        return connections.use((scope connection) {
            return connection.execParams(query).toTasks;
        });
    }

    Task[] awaitingExecution()
    {
        QueryParams query;
        query.sqlCommand = "select " ~ taskColumns ~ " from tasks t"
            ~ " join lanes l on l.id = t.lane_id join projects p on p.id = l.project_id"
            ~ " where t.agent_status = 'scheduled' and not l.marks_done and l.agents_pick_up and not p.ai_paused"
            ~ " order by t.created_at";

        return connections.use((scope connection) {
            return connection.execParams(query).toTasks;
        });
    }

    bool changeAgentStatus(UUID id, AgentStatus from, AgentStatus to)
    {
        QueryParams query;
        query.sqlCommand = "update tasks set agent_status = $3, updated_at = now()"
            ~ " where id = $1 and agent_status = $2 returning id";
        query.argsVariadic(id, cast(string) from, cast(string) to);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    ulong changeAgentStatuses(AgentStatus from, AgentStatus to)
    {
        QueryParams query;
        query.sqlCommand = "update tasks set agent_status = $2, updated_at = now() where agent_status = $1 returning id";
        query.argsVariadic(cast(string) from, cast(string) to);

        return connections.use((scope connection) {
            return connection.execParams(query).length;
        });
    }

    TaskNote[] notes(UUID taskId)
    {
        QueryParams query;
        query.sqlCommand = "select id, task_id, inserted_at, note, lane_color from task_notes"
            ~ " where task_id = $1 order by inserted_at desc";
        query.argsVariadic(taskId);

        return connections.use((scope connection) {
            auto answer = connection.execParams(query);

            TaskNote[] entries;
            entries.reserve(answer.length);

            foreach (index; 0 .. answer.length)
            {
                auto row = answer[index];
                auto color = row["lane_color"];
                entries ~= new TaskNote(
                    row["id"].as!UUID,
                    row["task_id"].as!UUID,
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

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    Nullable!UUID projectOfLane(UUID laneId)
    {
        QueryParams query;
        query.sqlCommand = "select project_id from lanes where id = $1";
        query.argsVariadic(laneId);

        return connections.use((scope connection) {
            auto answer = connection.execParams(query);

            return answer.length == 0 ? Nullable!UUID.init
                : answer[0]["project_id"].as!UUID.nullable;
        });
    }

    Task add(Task task)
    {
        connections.transaction((scope connection) {
            connection.lockLane(task.laneId);
            connection.placeTask(task);

            QueryParams insert;
            insert.sqlCommand = "insert into tasks (lane_id, description, position, agent_status)"
                ~ " values ($1, $2, $3, $4) returning id, created_at, updated_at";
            auto status = task.agentStatus.isNull ? Nullable!string.init : (cast(string) task.agentStatus.get)
                .nullable;
            insert.argsVariadic(task.laneId, task.description, task.position.get, status);
            auto row = connection.execParams(insert)[0];
            task.id = row["id"].as!UUID;
            task.createdAt = row["created_at"].as!SysTime;
            task.updatedAt = row["updated_at"].as!SysTime;
            task.assignedAiAgentId = Nullable!UUID.init;

            QueryParams created;
            created.sqlCommand = recordCreated;
            created.argsVariadic(task.id);
            connection.execParams(created);
        });

        return task;
    }

    bool update(Task task)
    {
        return connections.transaction((scope connection) {
            connection.lockLane(task.laneId);

            QueryParams current;
            current.sqlCommand = "select lane_id, description from tasks where id = $1 for update";
            current.argsVariadic(task.id);
            auto answer = connection.execParams(current);
            if (answer.length == 0)
            {
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

            return true;
        });
    }

    void move(UUID id, UUID laneId, UUID before)
    {
        connections.transaction((scope connection) {
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
        });
    }

    Nullable!UUID assignedAiAgent(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "select assigned_ai_agent_id from tasks where id = $1";
        query.argsVariadic(id);

        return connections.use((scope connection) {
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
        return connections.transaction((scope connection) {
            QueryParams current;
            current.sqlCommand = "select assigned_ai_agent_id from tasks where id = $1 for update";
            current.argsVariadic(id);
            auto answer = connection.execParams(current);
            if (answer.length == 0)
            {
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

            return true;
        });
    }

    bool recordSchedulingFailure(UUID id, UUID schedulerId)
    {
        return recordAgentOutcome(id, schedulerId, `Scheduling by "%s" failed`);
    }

    bool recordNoAgentFound(UUID id, UUID schedulerId)
    {
        return recordAgentOutcome(id, schedulerId, `Left where it is, since "%s" found no agent for its next step`);
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

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    Nullable!AgentStatus agentStatus(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "select agent_status from tasks where id = $1";
        query.argsVariadic(id);

        return connections.use((scope connection) {
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
        return connections.transaction((scope connection) {
            QueryParams update;
            update.sqlCommand = "update tasks set assigned_ai_agent_id = null, agent_status = 'to_be_scheduled', updated_at = now()"
                ~ " where id = $1 and agent_status is distinct from 'scheduling' and agent_status is distinct from 'executing'"
                ~ " returning id";
            update.argsVariadic(id);
            if (connection.execParams(update).length == 0)
            {
                return false;
            }

            QueryParams note;
            note.sqlCommand = "insert into task_notes (task_id, note) values ($1, 'Handed back to the task scheduler')";
            note.argsVariadic(id);
            connection.execParams(note);

            return true;
        });
    }

    bool[UUID] agentsAtWork(UUID[] ids)
    {
        bool[UUID] atWork;
        if (ids.length == 0)
        {
            return atWork;
        }

        // Given as one text, since the ids go in no other array parameter.
        QueryParams query;
        query.sqlCommand = "select t.id, not p.ai_paused"
            ~ " and exists (select 1 from lanes m where m.project_id = p.id and m.agents_pick_up) as at_work from tasks t"
            ~ " join lanes l on l.id = t.lane_id join projects p on p.id = l.project_id"
            ~ " where t.id = any(string_to_array($1, ',')::uuid[])";
        query.argsVariadic(ids.map!(id => id.toString).join(","));

        return connections.use((scope connection) {
            auto answer = connection.execParams(query);
            foreach (index; 0 .. answer.length)
            {
                atWork[answer[index]["id"].as!UUID] = answer[index]["at_work"].as!bool;
            }

            return atWork;
        });
    }

    bool endStoppedRun(UUID id, AgentStatus from, AgentStatus to, bool unassign, string note)
    {
        return connections.transaction((scope connection) {
            QueryParams update;
            update.sqlCommand = "update tasks set agent_status = $3,"
                ~ " assigned_ai_agent_id = case when $4 then null else assigned_ai_agent_id end, updated_at = now()"
                ~ " where id = $1 and agent_status = $2 returning id";
            update.argsVariadic(id, cast(string) from, cast(string) to, unassign);
            if (connection.execParams(update).length == 0)
            {
                return false;
            }

            QueryParams insert;
            insert.sqlCommand = "insert into task_notes (task_id, note) values ($1, $2)";
            insert.argsVariadic(id, note);
            connection.execParams(insert);

            return true;
        });
    }

    bool recordNoScheduler(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "insert into task_notes (task_id, note)"
            ~ " select id, 'Not assigned, since there is no enabled task scheduler agent' from tasks where id = $1 returning id";
        query.argsVariadic(id);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    /// `note` is a format for SQL's format(), with the agent's name as its one %s.
    private bool recordAgentOutcome(UUID id, UUID agentId, string note)
    {
        QueryParams query;
        query.sqlCommand = recordAgentOutcomeNote;
        query.argsVariadic(id, agentId, note);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    bool remove(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "delete from tasks where id = $1 returning id";
        query.argsVariadic(id);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    ulong removeOfLane(UUID laneId)
    {
        QueryParams query;
        query.sqlCommand = "delete from tasks where lane_id = $1 returning id";
        query.argsVariadic(laneId);

        return connections.use((scope connection) {
            return cast(ulong) connection.execParams(query).length;
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

/// The columns a task is read from, as `t`.
private enum taskColumns = "t.id, t.lane_id, t.description, t.position, t.created_at, t.updated_at,"
    ~ " t.assigned_ai_agent_id, t.agent_status";

private Task toTask(immutable Row row)
{
    auto agentId = row["assigned_ai_agent_id"];
    auto status = row["agent_status"];
    return new Task(
        row["id"].as!UUID,
        row["lane_id"].as!UUID,
        row["description"].as!string,
        row["position"].as!int,
        row["created_at"].as!SysTime,
        row["updated_at"].as!SysTime,
        agentId.isNull ? Nullable!UUID.init : agentId.as!UUID.nullable,
        status.isNull ? Nullable!AgentStatus.init : status.as!string.toAgentStatus.nullable
    );
}

/// IRuntimeRepository over postgres.
class PostgresRuntimeRepository : IRuntimeRepository
{
    private PostgresConnections connections;

    this(PostgresConnections connections)
    {
        this.connections = connections;
    }

    Runtime[] all()
    {
        QueryParams query;
        query.sqlCommand = "select id, name from runtimes order by name";

        return connections.use((scope connection) {
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

        return connections.use((scope connection) {
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

        return connections.use((scope connection) {
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

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    bool takes(string model, string effort)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from model_effort_levels where model = $1 and effort_level = $2";
        query.argsVariadic(model, effort);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }
}

/// IAgentRepository over postgres.
class PostgresAgentRepository : IAgentRepository
{
    private PostgresConnections connections;

    this(PostgresConnections connections)
    {
        this.connections = connections;
    }

    Agent[] all()
    {
        QueryParams query;
        query.sqlCommand = "select id, name, runtime, model, effort, task_scheduler, enabled, instructions, max_parallel_tasks from agents order by task_scheduler desc, name";

        return connections.use((scope connection) {
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
        query.sqlCommand = "select id, name, runtime, model, effort, task_scheduler, enabled, instructions, max_parallel_tasks from agents where id = $1";
        query.argsVariadic(id);

        return connections.use((scope connection) {
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

    bool setEnabled(UUID id, bool enabled)
    {
        QueryParams query;
        query.sqlCommand = "update agents set enabled = $2 where id = $1 returning id";
        query.argsVariadic(id, enabled);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    UUID[] setAllEnabled(bool enabled)
    {
        QueryParams query;
        query.sqlCommand = "update agents set enabled = $1 where enabled <> $1 returning id";
        query.argsVariadic(enabled);

        return connections.use((scope connection) {
            auto answer = connection.execParams(query);

            UUID[] ids;
            ids.reserve(answer.length);

            foreach (index; 0 .. answer.length)
            {
                ids ~= answer[index]["id"].as!UUID;
            }

            return ids;
        });
    }

    bool nameTaken(string name, UUID except)
    {
        QueryParams query;
        query.sqlCommand = "select 1 from agents where name = $1 and id <> $2";
        query.argsVariadic(name, except);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    Agent add(Agent agent)
    {
        QueryParams query;
        query.sqlCommand = "insert into agents (name, runtime, model, effort, task_scheduler, instructions, max_parallel_tasks) values ($1, $2, $3, $4, $5, $6, $7) returning id, enabled";
        query.argsVariadic(agent.name, agent.runtime, agent.model, agent.effort, agent.taskScheduler, agent.instructions,
            agent.maxParallelTasks);

        connections.transaction((scope connection) {
            auto row = connection.execParams(query)[0];
            agent.id = row["id"].as!UUID;
            agent.enabled = row["enabled"].as!bool;
            connection.insertLabels(agent.id, agent.labels);
        });

        return agent;
    }

    bool update(Agent agent)
    {
        QueryParams query;
        query.sqlCommand = "update agents set name = $2, runtime = $3, model = $4, effort = $5, task_scheduler = $6, instructions = $7, max_parallel_tasks = $8 where id = $1 returning enabled";
        query.argsVariadic(agent.id, agent.name, agent.runtime, agent.model, agent.effort, agent.taskScheduler, agent.instructions,
            agent.maxParallelTasks);

        return connections.transaction((scope connection) {
            auto answer = connection.execParams(query);
            if (answer.length == 0)
            {
                return false;
            }

            agent.enabled = answer[0]["enabled"].as!bool;

            QueryParams clear;
            clear.sqlCommand = "delete from agent_labels where agent_id = $1";
            clear.argsVariadic(agent.id);
            connection.execParams(clear);
            connection.insertLabels(agent.id, agent.labels);

            return true;
        });
    }

    bool remove(UUID id)
    {
        QueryParams query;
        query.sqlCommand = "delete from agents where id = $1 returning id";
        query.argsVariadic(id);

        return connections.use((scope connection) {
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
        row["instructions"].as!string,
        null,
        row["max_parallel_tasks"].isNull ? Nullable!int.init : row["max_parallel_tasks"].as!int.nullable,
        row["enabled"].as!bool
    );
}

/// IAgentLogRepository over postgres.
class PostgresAgentLogRepository : IAgentLogRepository
{
    private PostgresConnections connections;

    this(PostgresConnections connections)
    {
        this.connections = connections;
    }

    AgentLogEntry[] ofAgent(UUID agentId)
    {
        QueryParams query;
        // The cost as a double, since dpq2 reads a numeric only as text.
        query.sqlCommand = "select id, agent_id, created_at, prompt, result, input_tokens, output_tokens,"
            ~ " cache_creation_input_tokens, cache_read_input_tokens, cost_usd::float8 as cost_usd"
            ~ " from agent_log where agent_id = $1 order by created_at desc";
        query.argsVariadic(agentId);

        return connections.use((scope connection) {
            auto answer = connection.execParams(query);

            AgentLogEntry[] entries;
            entries.reserve(answer.length);

            foreach (index; 0 .. answer.length)
            {
                auto row = answer[index];
                auto result = row["result"];
                // The usage columns are null together, which the table checks.
                auto usage = row["cost_usd"].isNull ? Nullable!RunUsage.init : RunUsage(
                    row["input_tokens"].as!long,
                    row["output_tokens"].as!long,
                    row["cache_creation_input_tokens"].as!long,
                    row["cache_read_input_tokens"].as!long,
                    row["cost_usd"].as!double
                ).nullable;
                entries ~= new AgentLogEntry(
                    row["id"].as!UUID,
                    row["agent_id"].as!UUID,
                    row["created_at"].as!SysTime,
                    row["prompt"].as!string,
                    result.isNull ? Nullable!string.init : result.as!string.nullable,
                    usage
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

        connections.use((scope connection) {
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

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }

    bool setUsage(UUID id, RunUsage usage)
    {
        QueryParams query;
        query.sqlCommand = "update agent_log set input_tokens = $2, output_tokens = $3,"
            ~ " cache_creation_input_tokens = $4, cache_read_input_tokens = $5, cost_usd = $6"
            ~ " where id = $1 returning id";
        query.argsVariadic(id, usage.inputTokens, usage.outputTokens, usage.cacheCreationInputTokens,
            usage.cacheReadInputTokens, usage.costUsd);

        return connections.use((scope connection) {
            return connection.execParams(query).length > 0;
        });
    }
}

/// IDefaultRepository over postgres.
class PostgresDefaultRepository : IDefaultRepository
{
    private PostgresConnections connections;

    this(PostgresConnections connections)
    {
        this.connections = connections;
    }

    Default[] all()
    {
        QueryParams query;
        query.sqlCommand = "select key, value from defaults order by key";

        return connections.use((scope connection) {
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
