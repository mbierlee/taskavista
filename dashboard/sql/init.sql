-- Taskavista — initial schema.

create table if not exists projects (
	id            uuid primary key default gen_random_uuid(),
	-- A letter or digit, in any script, to make a slug from, which also rules
	-- out a blank name.
	name          text not null check (name ~ '[[:alnum:]]'),
	-- The project's name in its URL, /projects/<slug>, percent-encoded there.
	-- Words in any script joined by single hyphens. The regex classes count
	-- combining marks as punctuation, so which characters make a word is left
	-- to the application; this only rules out whitespace and ASCII punctuation.
	slug          text not null unique
					   check (slug ~ '^[^-[:space:]]+(-[^-[:space:]]+)*$'
							  and slug !~ '[\x21-\x2c\x2e\x2f\x3a-\x40\x5b-\x60\x7b-\x7e]'
							  and slug = lower(slug)
							  and slug is nfc normalized),
	task_add_rule text not null default 'first_lane'
					   check (task_add_rule in ('first_lane', 'any_lane')),
	managed_by_ai boolean not null default false,
	ai_paused     boolean not null default false,
	check (managed_by_ai or ai_paused)
);

create table if not exists lanes (
	id         uuid primary key default gen_random_uuid(),
	project_id uuid not null references projects (id) on delete cascade,
	name       text not null check (length(trim(name)) > 0),
	position   integer not null check (position >= 0),
	color      text not null check (color ~ '^#[0-9a-f]{6}$'),
	-- Whether the tasks in this lane count as done.
	marks_done boolean not null default false,
	-- Deferrable so lanes can swap positions inside one transaction.
	unique (project_id, position) deferrable initially immediate
);

create table if not exists tasks (
	id          uuid primary key default gen_random_uuid(),
	lane_id     uuid not null references lanes (id) on delete cascade,
	description text not null check (length(trim(description)) > 0),
	position    integer not null check (position >= 0),
	created_at  timestamptz not null default now(),
	-- Set by the application rather than a trigger, so that the tasks shifted
	-- to make room for a moved one do not count as updated.
	updated_at  timestamptz not null default now(),
	-- Deferrable so tasks can swap positions inside one transaction.
	unique (lane_id, position) deferrable initially immediate
);

create table if not exists task_history (
	id         uuid primary key default gen_random_uuid(),
	task_id    uuid not null references tasks (id) on delete cascade,
	changed_at timestamptz not null default now(),
	change     text not null check (length(trim(change)) > 0),
	-- The colour the task's lane had when the change put it there, copied like
	-- the lane names in change. Null for a change that left the task in its lane.
	lane_color text check (lane_color ~ '^#[0-9a-f]{6}$')
);

create index if not exists task_history_task_id on task_history (task_id, changed_at);

create table if not exists runtimes (
	id   text primary key check (length(trim(id)) > 0),
	name text not null unique check (length(trim(name)) > 0)
);

create table if not exists models (
	-- The name the runtime itself knows the model by.
	id      text primary key check (length(trim(id)) > 0),
	name    text not null check (length(trim(name)) > 0),
	runtime text not null references runtimes (id),
	unique (runtime, name),
	-- The target of agents' foreign key, which keeps an agent's model in its runtime.
	unique (id, runtime)
);

create table if not exists effort_levels (
	id       text primary key check (length(trim(id)) > 0),
	name     text not null unique check (length(trim(name)) > 0),
	-- Lowest effort first.
	position integer not null unique check (position >= 0)
);

create table if not exists model_effort_levels (
	model        text not null references models (id) on delete cascade,
	effort_level text not null references effort_levels (id) on delete cascade,
	primary key (model, effort_level)
);

create table if not exists agents (
	id             uuid primary key default gen_random_uuid(),
	name           text not null unique check (length(trim(name)) > 0),
	runtime        text not null references runtimes (id),
	model          text not null,
	effort         text not null default 'default',
	task_scheduler boolean not null default false,
	foreign key (model, runtime) references models (id, runtime),
	foreign key (model, effort) references model_effort_levels (model, effort_level)
);

create table if not exists agent_labels (
	agent_id uuid not null references agents (id) on delete cascade,
	label    text not null check (length(trim(label)) > 0 and label = lower(label)),
	primary key (agent_id, label)
);

create table if not exists agent_log (
	id         uuid primary key default gen_random_uuid(),
	agent_id   uuid not null references agents (id) on delete cascade,
	created_at timestamptz not null default now(),
	prompt     text not null check (length(trim(prompt)) > 0),
	-- Null until the agent has finished.
	result     text
);

create index if not exists agent_log_agent_id on agent_log (agent_id, created_at);

create table if not exists defaults (
	key   text primary key check (length(trim(key)) > 0),
	-- Text, and no foreign key, since a value may be an id from any table or
	-- not an id at all.
	value text not null
);

-- Fixed data, not sample rows, so it belongs with the schema.

insert into runtimes (id, name) values ('claude-code', 'Claude Code') on conflict (id) do nothing;

insert into models (id, name, runtime) values
	('claude-fable-5-1',          'Claude Fable 5.1',       'claude-code'),
	('claude-opus-5-5',           'Claude Opus 5.5',        'claude-code'),
	('claude-sonnet-5-5',         'Claude Sonnet 5.5',      'claude-code'),
	('claude-haiku-5-5',          'Claude Haiku 5.5',       'claude-code'),
	('fable',                     'Claude Fable (latest)',  'claude-code'),
	('opus',                      'Claude Opus (latest)',   'claude-code'),
	('sonnet',                    'Claude Sonnet (latest)', 'claude-code'),
	('haiku',                     'Claude Haiku (latest)',  'claude-code')
	on conflict (id) do nothing;

insert into effort_levels (id, name, position) values
	('default',   'Default',    0),
	('low',       'Low',        1),
	('medium',    'Medium',     2),
	('high',      'High',       3),
	('xhigh',     'Extra high', 4),
	('max',       'Max',        5),
	('ultracode', 'Ultracode',  6)
	on conflict (id) do nothing;

insert into model_effort_levels (model, effort_level)
	select m.model, e.effort_level
	from (values ('claude-fable-5-1'), ('claude-opus-5-5'), ('claude-sonnet-5-5'), ('claude-haiku-5-5'),
				 ('fable'), ('opus'), ('sonnet'), ('haiku')) as m (model)
	cross join (values ('low'), ('medium'), ('high'), ('xhigh'), ('max')) as e (effort_level)
	on conflict (model, effort_level) do nothing;

-- Whatever the runtime picks for the model, so every model takes it.
insert into model_effort_levels (model, effort_level)
	select id, 'default' from models
	on conflict (model, effort_level) do nothing;

insert into model_effort_levels (model, effort_level)
	select model, 'ultracode' from model_effort_levels where effort_level = 'xhigh'
	on conflict (model, effort_level) do nothing;

insert into agents (name, runtime, model, task_scheduler)
	values ('Task Scheduler', 'claude-code', 'sonnet', true)
	on conflict (name) do nothing;

insert into defaults (key, value) values
	('runtime', 'claude-code'),
	('model',   'sonnet'),
	('effort',  'default')
	on conflict (key) do nothing;
