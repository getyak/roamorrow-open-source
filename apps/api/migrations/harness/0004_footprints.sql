CREATE TABLE IF NOT EXISTS harness.footprints (
    user_id uuid NOT NULL,
    id uuid NOT NULL,
    kind text NOT NULL,
    captured_at timestamptz NOT NULL,
    version bigint NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    payload jsonb NOT NULL,
    PRIMARY KEY (user_id, id)
);
CREATE INDEX IF NOT EXISTS footprints_history
    ON harness.footprints (user_id, kind, captured_at, id);
CREATE TABLE IF NOT EXISTS harness.footprint_grants (
    user_id uuid PRIMARY KEY,
    digest bytea NOT NULL UNIQUE,
    raw_tracks boolean NOT NULL,
    photo_previews boolean NOT NULL,
    expires_at timestamptz NOT NULL
);
