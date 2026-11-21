-- v2 plans/proposals/receipts have one owner-locked authority. This private
-- aggregate never participates in the legacy itinerary timestamp/LWW path.
CREATE TABLE IF NOT EXISTS harness.travel_workspaces (
    user_id TEXT PRIMARY KEY,
    revision BIGINT NOT NULL DEFAULT 0,
    payload JSONB NOT NULL DEFAULT '{}',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

REVOKE ALL ON harness.travel_workspaces FROM PUBLIC;
ALTER TABLE harness.travel_workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE harness.travel_workspaces FORCE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname='harness' AND tablename='travel_workspaces'
          AND policyname='travel_workspace_owner'
    ) THEN
        CREATE POLICY travel_workspace_owner ON harness.travel_workspaces
          USING (user_id = current_setting('app.travel_owner', true))
          WITH CHECK (user_id = current_setting('app.travel_owner', true));
    END IF;
END
$$;
