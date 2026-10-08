CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS tasks (
	id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	client_id text UNIQUE NOT NULL,
	title text NOT NULL,
	description text NOT NULL DEFAULT '',
	completed boolean NOT NULL DEFAULT false,
	version integer NOT NULL DEFAULT 1,
	created_at timestamptz NOT NULL,
	updated_at timestamptz NOT NULL,
	deleted_at timestamptz NULL,
	CONSTRAINT tasks_title_not_empty CHECK (length(trim(title)) > 0),
	CONSTRAINT tasks_version_positive CHECK (version > 0)
);

CREATE INDEX IF NOT EXISTS tasks_updated_at_idx ON tasks (updated_at);
CREATE INDEX IF NOT EXISTS tasks_deleted_at_idx ON tasks (deleted_at);
