module config;

import vibe.core.file : existsFile, readFileUTF8;
import vibe.core.log : logInfo;
import vibe.data.json : deserializeJson;
import vibe.data.serialization : optional;

import std.format : format;

import helpers : quoted;

/// Config is a class rather than a struct so the container can hand it out;
/// Poodinis resolves by class type.
class Config
{
    @optional string[] bindAddresses = ["::1", "127.0.0.1"];
    @optional ushort port = 8080;
    @optional DatabaseConfig database;
}

struct DatabaseConfig
{
    @optional string host = "localhost";
    @optional ushort port = 5432;
    @optional string name = "taskavista-dev";
    @optional string user = "taskavista";
    @optional string password = "taskavista";
    @optional uint connectionPoolSize = 4;
}

enum configPath = "config.json";

/// Reads the config file, falling back to defaults when it is not present.
/// Fields left out of the file keep their default as well.
Config loadConfig()
{
    if (!existsFile(configPath))
    {
        logInfo("No %s found, using defaults.", configPath);
        return new Config;
    }

    return deserializeJson!Config(readFileUTF8(configPath));
}

/// Builds the libpq connection string. Values are quoted, since a password is
/// free to contain spaces or quotes.
string connectionString(DatabaseConfig database)
{
    return format("host=%s port=%s dbname=%s user=%s password=%s",
        database.host.quoted, database.port, database.name.quoted,
        database.user.quoted, database.password.quoted);
}

/// Where agents reach the API, without a trailing slash. Localhost, since agents
/// run on the same machine as the server, and the default bind addresses are
/// both of localhost's.
string apiUrl(Config config)
{
    return format("http://localhost:%s", config.port);
}
