# Roamorrow

Roamorrow is a map-first travel companion. Browse places and experiences, save
and revisit plans, and keep a personal journal of places you visit. The iOS app
can sync your Footprints to your Roamorrow account. With one OAuth connection,
Codex can read daily summaries through the Footprints MCP server.

## What's here

- `apps/ios` — the SwiftUI app, widget and native tests
- `apps/web` — the Next.js web app
- `apps/api` — the Go API, PostgreSQL migrations and Footprints MCP server
- `apps/bot` and `apps/worker` — the Telegram bot and data worker
- `packages` and `infra` — shared types, data sources and database tooling

## Web and TypeScript

Install Node.js 22.13 or later and the pnpm version pinned in
[`package.json`](package.json).

```sh
git clone https://github.com/getyak/roamorrow-open-source.git
cd roamorrow-open-source
pnpm install --frozen-lockfile
pnpm --filter @solo-compass/web dev
```

The web app normally runs at `http://localhost:3000`. For optional services,
use your own configuration based on [`.env.example`](.env.example) and
[`apps/web/.env.local.example`](apps/web/.env.local.example).

## iOS

Install Xcode with an iOS Simulator runtime and install XcodeGen. From the
repository root:

```sh
./scripts/generate_secrets.sh
cd apps/ios
xcodegen generate
open SoloCompass.xcodeproj
```

Select the **SoloCompass** scheme and an iPhone Simulator. Local exploration
can run with the generated empty configuration. Use your own Apple developer
team and bundle identifiers for device builds, and use your own provider values
in the root `.env` to enable account-backed features. Server credentials belong
on your backend.

## API and MCP

Install the Go version in [`apps/api/go.mod`](apps/api/go.mod). Start the API
with `make -C apps/api api-run`. The health check is available at
`http://localhost:8080/healthz`.

To enable cloud Footprints, configure your own PostgreSQL database with
`HARNESS_DATABASE_URL` and provide `SUPABASE_URL` and `SUPABASE_ANON_KEY` for
account authentication. The API applies its harness migrations at startup.
`HARNESS_FOOTPRINT_OAUTH_ORIGIN` is the canonical HTTPS API origin for Agent
login. Set `SOLO_HARNESS_BASE_URL` to that origin in the iOS configuration.

See [Footprints setup](docs/development/footprints.md) for the OAuth connection,
Codex commands and account-scoped test setup.

## Checks

```sh
pnpm typecheck
pnpm test
(cd apps/api && go test ./...)
```

Run the native tests from the SoloCompass scheme in Xcode.

## License

[MIT](LICENSE).
