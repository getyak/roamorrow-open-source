ALTER TABLE harness.footprint_grants ALTER COLUMN expires_at DROP NOT NULL;

CREATE SEQUENCE IF NOT EXISTS harness.footprint_change_seq;
ALTER TABLE harness.footprints ADD COLUMN IF NOT EXISTS change_id bigint;
UPDATE harness.footprints SET change_id = nextval('harness.footprint_change_seq') WHERE change_id IS NULL;
ALTER TABLE harness.footprints ALTER COLUMN change_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS footprints_changes ON harness.footprints (user_id, change_id);
