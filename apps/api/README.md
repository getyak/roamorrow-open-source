# Roamorrow API

Go service that provides the RAG (retrieval-augmented generation) pipeline for Roamorrow. It aggregates real user reviews into Solo Score calculations and exposes them to the mobile app.

## Purpose

- Persist and query per-experience reviews from a PostgreSQL database.
- Compute aggregate Solo Scores from real review data.
- Extract structured solo metrics from review text via DeepSeek's
  OpenAI-compatible chat/completions API (`internal/reviews/extractor.go`).
- Read public travel sources and retain versioned account plans with separate
  previews, confirmations and operation receipts (`internal/travel`).

## Endpoints

| Method | Path                             | Description                                                                                                        |
| ------ | -------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| GET    | `/healthz`                       | Health check — always returns `{"status":"ok"}`, no DB dependency.                                                 |
| GET    | `/v1/experiences/:id/solo-score` | Returns the aggregate solo score and review count for an experience. Returns 503 when the database is unavailable. |

## DeepSeek onboarding harness

The same binary serves the onboarding harness (frozen wire contract):
`/v1/harness/*` and `/mcp` (MCP Streamable HTTP, 2025-11-25). It uses a
**separate private database** (`HARNESS_DATABASE_URL`, schema `harness`,
migrations in `migrations/harness`) and verified Supabase bearer auth.

- Footprint sync and authorization configuration: [Footprints](../../docs/development/footprints.md).
- `api-server migrate` applies the idempotent harness migrations and exits
  (they also run automatically at startup).

## Travel research and confirmed actions

The same binary also serves `/v1/travel/*`. `POST /v1/travel/public-source`
reads bounded public page/iframe content without an account bearer; it cannot
read or change account records. The remaining travel routes require the same
verified Supabase identity as the harness. Account plans, proposals, calendar
bindings and operation receipts use `HARNESS_DATABASE_URL`, including migrations
`0002_travel_plans.sql` and `0003_calendar_write_selection.sql`.

The native foreground research host exposes 14 domain tools. Its automatic
writes save research and independent drafts; existing plans and calendars need
the user's concrete preview confirmation. This does not expand the old `/mcp`
read-tool catalog: `/v1/travel/tools/call` only dispatches `read_source`, and
confirmation routes are not model tools.

## Environment variables

| Variable               | Default                       | Description                                                                                                                              |
| ---------------------- | ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `DATABASE_URL`         | _(none)_                      | Review PostgreSQL DSN (`postgres://user:pass@host/db`). When absent, the Solo Score route returns 503; Harness uses its independent DSN. |
| `PORT`                 | `8080`                        | TCP port the server listens on.                                                                                                          |
| `DEEPSEEK_API_KEY`     | _(none)_                      | DeepSeek key for review extraction. Without it, `Extract` returns an error and callers degrade gracefully.                               |
| `DEEPSEEK_BASE_URL`    | `https://api.deepseek.com/v1` | OpenAI-compatible base URL; the extractor appends `/chat/completions`.                                                                   |
| `DEEPSEEK_MODEL`       | `deepseek-flash`              | Model id. Legacy ids (`deepseek-chat`, `deepseek-reasoner`, `deepseek-v4-pro`, `deepseek-v4-flash`) normalize forward.                   |
| `HARNESS_DATABASE_URL` | _(none)_                      | Private harness database DSN. When absent, harness DB endpoints return 503 (`database` capability false).                                |
| `HARNESS_TOKEN_KEY`    | _(none)_                      | Base64 AES-256 key encrypting Google tokens at rest. Missing config disables the `google` capability.                                    |

## Running locally

```bash
# From the repo root:
make -C apps/api api-run

# Or from apps/api/:
make api-run
```

## Docker

```bash
docker build -t solo-compass-api apps/api
docker run -p 8080:8080 -e DATABASE_URL=postgres://... solo-compass-api
```

## Tests

```bash
cd apps/api
go test ./...
```
