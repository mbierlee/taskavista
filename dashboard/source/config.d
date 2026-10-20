module config;

import vibe.core.args : readOption;
import vibe.core.file : existsFile, readFileUTF8;
import vibe.core.log : logInfo;
import vibe.data.json : deserializeJson;
import vibe.data.serialization : optional;

import std.exception : enforce;
import std.format : format;

import helpers : quoted;

/**
 * Config is a class rather than a struct so the container can hand it out;
 * Poodinis resolves by class type.
 */
class Config
{
    @optional string[] bindAddresses = ["::1", "127.0.0.1"];
    @optional ushort port = 8080;
    @optional DatabaseConfig database;

    /**
     * The directory under which each project gets its own working directory,
     * the one its agents work in. Outside the repository, since Claude Code
     * also reads the settings and CLAUDE.md of the directories above the one
     * it runs in. Not used yet.
     */
    @optional string projectWorkingDirRoot = "~/taskavista-projects";
}

struct DatabaseConfig
{
    @optional string host = "localhost";
    @optional ushort port = 5432;
    @optional string name = "taskavista-dev";
    @optional string user = "taskavista";
    @optional string password = "taskavista";
    @optional uint connectionPoolSize = 10;
}

enum configPath = "config.json";

/**
 * Reads the config file given with `--config`, or else config.json, falling
 * back to defaults when config.json is not present. Fields left out of the file
 * keep their default as well.
 *
 * Throws: `Exception` when the file given with `--config` does not exist, since
 * a server quietly started on defaults could be pointed at the wrong database.
 */
Config loadConfig()
{
    string path;
    if (readOption("config", &path, "The config file to use instead of " ~ configPath ~ "."))
    {
        enforce(existsFile(path), format("Config file %s not found.", path));
    }
    else if (existsFile(configPath))
    {
        path = configPath;
    }
    else
    {
        logInfo("No %s found, using defaults.", configPath);
        return new Config;
    }

    logInfo("Using config %s.", path);
    return deserializeJson!Config(readFileUTF8(path));
}

/**
 * Builds the libpq connection string. Values are quoted, since a password is
 * free to contain spaces or quotes.
 */
string connectionString(DatabaseConfig database)
{
    return format("host=%s port=%s dbname=%s user=%s password=%s",
        database.host.quoted, database.port, database.name.quoted,
        database.user.quoted, database.password.quoted);
}

/**
 * Where agents reach the API, without a trailing slash. Localhost, since agents
 * run on the same machine as the server, and the default bind addresses are
 * both of localhost's.
 */
string apiUrl(Config config)
{
    return format("http://localhost:%s", config.port);
}
