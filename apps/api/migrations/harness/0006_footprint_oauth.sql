CREATE TABLE IF NOT EXISTS harness.footprint_oauth_clients (
    id text PRIMARY KEY,
    redirect_uris jsonb NOT NULL,
    expires_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS footprint_oauth_clients_expiry
    ON harness.footprint_oauth_clients (expires_at);

CREATE TABLE IF NOT EXISTS harness.footprint_oauth_sessions (
    id bytea PRIMARY KEY,
    client_id text NOT NULL,
    resource text NOT NULL,
    user_id uuid NOT NULL,
    access_digest bytea UNIQUE,
    access_expires_at timestamptz,
    refresh_digest bytea UNIQUE,
    refresh_expires_at timestamptz NOT NULL,
    revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS footprint_oauth_sessions_owner
    ON harness.footprint_oauth_sessions (user_id);
CREATE INDEX IF NOT EXISTS footprint_oauth_sessions_expiry
    ON harness.footprint_oauth_sessions (refresh_expires_at);

CREATE TABLE IF NOT EXISTS harness.footprint_oauth_attempts (
    id bytea PRIMARY KEY,
    browser_digest bytea NOT NULL,
    client_id text NOT NULL,
    resource text NOT NULL,
    redirect_uri text NOT NULL,
    client_state text NOT NULL,
    code_challenge text NOT NULL,
    expires_at timestamptz NOT NULL,
    email text,
    user_id uuid,
    code_digest bytea UNIQUE,
    code_expires_at timestamptz,
    session_id bytea REFERENCES harness.footprint_oauth_sessions(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS footprint_oauth_attempts_expiry
    ON harness.footprint_oauth_attempts (expires_at);

CREATE TABLE IF NOT EXISTS harness.footprint_oauth_refresh_history (
    digest bytea PRIMARY KEY,
    session_id bytea NOT NULL REFERENCES harness.footprint_oauth_sessions(id) ON DELETE CASCADE
);
