module schema;

import vibe.core.file : existsFile, readFileUTF8;
import vibe.core.log;

import dpq2.connection : Connection;

/// The DDL that creates the schema from scratch, relative to the working directory.
enum schemaPath = "sql/init.sql";

/**
 * Anything of ours in the database shows up as a schema of its own, or as
 * something inside `public` — which exists in an untouched database, so it only
 * counts once it holds an object. A row means the database is not empty.
 */
private enum userSchemaQuery = `
    select 1
    from pg_catalog.pg_namespace
    where nspname not like 'pg\_%'
        and nspname <> 'information_schema'
        and (nspname <> 'public'
            or exists (select 1 from pg_catalog.pg_class
                where relnamespace = pg_namespace.oid))
    limit 1`;

/**
 * Creates the schema when the database is still completely empty, and leaves a
 * database that already has one untouched.
 *
 * Problems are logged rather than thrown: the server has always started with
 * postgres down and fails on the first query instead, and that stays true.
 */
void installSchemaWhenEmpty(string connectionString)
{
    if (!existsFile(schemaPath))
    {
        logWarn("No %s found, so an empty database would stay empty.", schemaPath);
        return;
    }

    try
    {
        // A connection of its own rather than the pool's: init.sql is several
        // statements in one string, which postgres only accepts over the simple
        // query protocol, while the pooled connections send everything through
        // the extended one. Blocking costs nothing here, as the event loop has
        // not started yet.
        auto connection = new Connection(connectionString);
        scope (exit)
        {
            connection.destroy();
        }

        if (connection.exec(userSchemaQuery).length > 0)
        {
            return;
        }

        logInfo("Database is empty, applying %s.", schemaPath);
        // The statements go over in one go, which postgres runs as a single
        // transaction, so a failure part-way leaves the database as it was.
        connection.exec(readFileUTF8(schemaPath));
        logInfo("Schema created.");
    }
    catch (Exception exception)
    {
        logError("Could not apply %s: %s", schemaPath, exception.msg);
    }
}
