#!/usr/bin/env bash
# Build Taskavista and install it on this machine as a systemd service.
#
# Run it as yourself, not as root: it builds with your dub and uses sudo for the
# steps that need it. Running it again upgrades the install in place, keeping
# the config, the database and the projects' working directories.
#
# Where things go:
#   /opt/taskavista             the binary, public/ and sql/, which it reads at runtime
#   /etc/taskavista/config.json the config, a copy of dashboard/config-default.json
#                               made only when there is none yet
#   /var/lib/taskavista         the service user's home, where its claude login lives
#   /var/lib/taskavista/projects the projects' working directories
#
# The sample rows in mock-data.sql are not installed.
set -euo pipefail

service=taskavista
user=taskavista
app_dir=/opt/taskavista
config_dir=/etc/taskavista
config_file="$config_dir/config.json"
data_dir=/var/lib/taskavista
projects_dir="$data_dir/projects"
unit_file=/etc/systemd/system/$service.service
# The container docker/run.sh starts, which the database is created in when it is running.
postgres_container=taskavista-postgres

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dashboard_dir="$repo_dir/dashboard"

if [[ $EUID -eq 0 ]]; then
    echo "Run this as yourself rather than as root; it uses sudo where it needs to." >&2
    exit 1
fi

for tool in dub jq rsync; do
    if ! command -v "$tool" > /dev/null; then
        echo "$tool is not on the PATH, and the install needs it." >&2
        exit 1
    fi
done

# LDC when there is one, since it optimises far better than DMD, which is only the fallback.
if command -v ldc2 > /dev/null; then
    compiler=ldc2
else
    compiler=dmd
fi

echo "==> Building the dashboard with $compiler"
(cd "$dashboard_dir" && dub build --build=release --compiler="$compiler")

echo "==> Creating the $user user"
if ! id "$user" > /dev/null 2>&1; then
    # A real home, since the claude CLI the agents run keeps its login and settings there.
    sudo useradd --system --home-dir "$data_dir" --create-home --shell /usr/sbin/nologin "$user"
fi
sudo install -d -o "$user" -g "$user" -m 0750 "$data_dir" "$projects_dir"

echo "==> Installing into $app_dir"
sudo install -d -m 0755 "$app_dir" "$app_dir/bin"
sudo install -m 0755 "$dashboard_dir/bin/release/taskavista-dashboard" "$app_dir/bin/taskavista-dashboard"
# --delete, so a file removed from the repo does not go on being served.
sudo rsync -a --delete --chown=root:root "$dashboard_dir/public/" "$app_dir/public/"
# Only the schema, so sample data put next to it is never applied to this database.
sudo install -D -m 0644 "$dashboard_dir/sql/init.sql" "$app_dir/sql/init.sql"

echo "==> Writing the config"
sudo install -d -m 0755 "$config_dir"
if sudo test -e "$config_file"; then
    echo "$config_file already exists, leaving it as it is."
else
    # Readable by the service user only, since it holds the database password.
    sudo install -m 0640 -o root -g "$user" "$dashboard_dir/config-default.json" "$config_file"
fi

# Read back from the installed config rather than the default, since it may have been edited since.
config="$(sudo cat "$config_file")"
port="$(jq -r '.port' <<< "$config")"
db_name="$(jq -r '.database.name' <<< "$config")"
db_user="$(jq -r '.database.user' <<< "$config")"

echo "==> Creating the database"
# The server fills in the schema itself on start-up, but only once the database exists.
# Docker is optional, since the database may be a postgres of its own rather than the container.
if ! command -v docker > /dev/null; then
    echo "Docker is not installed, so database $db_name was not created." >&2
    echo "Create it, owned by $db_user, before starting the service." >&2
elif docker inspect --format '{{.State.Running}}' "$postgres_container" 2> /dev/null | grep -q true; then
    exists="$(docker exec "$postgres_container" psql -U "$db_user" -d postgres -tAc \
        "select 1 from pg_database where datname = '$db_name'")"
    if [[ "$exists" == 1 ]]; then
        echo "Database $db_name already exists."
    else
        docker exec "$postgres_container" createdb -U "$db_user" "$db_name"
    fi
else
    echo "The $postgres_container container is not running, so database $db_name was not created." >&2
    echo "Create it, owned by $db_user, before starting the service." >&2
fi

echo "==> Installing the $service service"
sudo install -m 0644 /dev/stdin "$unit_file" << EOF
[Unit]
Description=Taskavista dashboard
Wants=network-online.target
# After docker, since the database may be the container docker/run.sh starts.
After=network-online.target docker.service

[Service]
User=$user
Group=$user
# The server reads public/ and sql/ relative to where it runs.
WorkingDirectory=$app_dir
ExecStart=$app_dir/bin/taskavista-dashboard --config=$config_file
# Agents run the claude CLI from the PATH, as installed for the service user.
Environment=HOME=$data_dir
Environment=PATH=$data_dir/.local/bin:/usr/local/bin:/usr/bin:/bin
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=full
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable "$service"
sudo systemctl restart "$service"

echo
echo "Taskavista is installed and running at http://localhost:$port"
echo "Logs: journalctl -u $service -f"

if ! sudo -u "$user" env PATH="$data_dir/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    sh -c 'command -v claude' > /dev/null; then
    echo
    echo "The $user user has no claude CLI yet, so its agents cannot run. Install it and log in as that user:"
    echo "  sudo -u $user -H bash -c 'cd && curl -fsSL https://claude.ai/install.sh | bash'"
    echo "  sudo -u $user -H $data_dir/.local/bin/claude"
fi
