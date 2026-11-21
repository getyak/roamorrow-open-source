# Footprints

The nearby map opens Footprints. Travelers can enable background recording and
favorite-photo import, review a day, name a stop, or pause recording. Location
delivery depends on iOS authorization and runtime. The journal preserves capture
gaps and displays estimated dwell times of at least ten minutes.

## Sign in and sync

Email verification uses the same screen for first-time and returning accounts.
The app returns to the previous screen as soon as the verified session is
saved. When eligible local history exists, the email form says it will sync to
the account. The app binds and queues the eligible journal automatically. The
cloud icon in Footprints opens details about the queue for this iPhone.
Network recovery and app activation allow an interrupted upload to continue.

A new account defaults to cloud sync. An existing device preference to pause
sync carries forward. History already bound to another account stays in that
account's local partition. A guest journal whose earlier ownership cannot be
established remains local. The account-scoped journal retains pending entries
across restarts. Stable IDs and monotone versions make repeat uploads safe;
removed favorites use versions and tombstones. An authenticated device can
restore its account's cloud history using the history cursor.

## Connect Codex

Use the HTTPS backend origin configured in the app and append `/mcp/footprints`.
Add it to Codex as a remote Streamable HTTP server and sign in with the same
Roamorrow account. With the CLI:

```sh
codex mcp add roamorrow --url 'https://YOUR-API-ORIGIN/mcp/footprints'
```

If adding the server does not open a browser, run `codex mcp login roamorrow`.
The login opens a Roamorrow authorization page. Browser sign-in verifies a
Roamorrow account, and approval grants read-only access to visit summaries.
Use **Connected apps** in Footprints settings to check and revoke this access.
The day query only returns timestamps and any available city or district
metadata. It omits the journal label, coordinates, photos and raw tracks.
If the backend confirms some visits, the query reports partial coverage. If no
visits are available, it reports unknown coverage. A receipt timestamp alone
never establishes that the iPhone captured or uploaded a complete day.

The backend advertises OAuth authorization server and protected resource
metadata when `HARNESS_FOOTPRINT_OAUTH_ORIGIN` is configured with your backend's
canonical HTTPS origin. The iPhone and Codex client both require network access
to that origin.

Existing clients using an explicitly created legacy bearer can continue to
send it in `Authorization`. The legacy permissions and the OAuth connection
can be revoked independently. Legacy `list_footprint_changes` follows uploads
using `next_cursor`, including favorite-photo tombstones. Call once without a
cursor to start at the current position, or use `"0"` for existing history.
Drain `has_more`, persist the new cursor, and upsert by record ID and version.

## Acceptance

Run the harness migrations against a disposable PostgreSQL database and pass
its URL as `FOOTPRINTS_TEST_DATABASE_URL` when running Go tests. The integration test exercises account isolation, duplicate uploads,
yesterday queries, restoration and deletion markers using synthetic inputs.
For local execution set `FOOTPRINTS_TEST_DATABASE_URL` only to a dedicated test
database with the migrations applied.

For device acceptance, use the Roamorrow test account and a dedicated backend
database. Capture or prepare a labeled set of test visits on the iPhone before
sign-in, verify that signing in closes the form and starts sync without an
extra action, and read the same day in a freshly connected Codex session.
Verify a second query after a new upload, recovery after offline capture, and
loss of access after revocation. Verify that switching accounts cannot expose
or upload the original journal. Keep device evidence separate from local API,
simulator and TestFlight upload results.

Use the following scorecard for the requested 95-point experience target.
Award points only after an observed pass. A failure in account isolation,
deletion, revocation or device installation blocks release at any score.

| Points | Observe on the candidate build |
| ---: | --- |
| 20 | Invalid and expired codes recover in place. A successful verification returns to the same date or map without a setup detour. |
| 25 | Pre-login visits appear in the correct account. The first sync starts without a tap. The cloud icon and detail agree after an interrupted upload, relaunch and Wi-Fi recovery. |
| 25 | A fresh Codex client completes one authorization, reads the fixture, reads new data with the same grant, and loses access after revoke. Empty or partial data is labeled accurately. |
| 15 | No stale records or location callbacks cross accounts. Limited photo visibility preserves hidden favorites. |
| 15 | Light and dark appearance, large text and VoiceOver retain readable text and accessible controls. Default success shows a cloud icon without pushing the journal down. |
