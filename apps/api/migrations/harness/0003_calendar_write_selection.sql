-- Existing read-only states stay false. Only the separate explicit travel
-- calendar-write OAuth flow can set this field before the one-use callback.
ALTER TABLE harness.oauth_states
    ADD COLUMN IF NOT EXISTS want_calendar_write BOOLEAN NOT NULL DEFAULT FALSE;
