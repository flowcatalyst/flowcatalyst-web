# fcdev CLI

`fcdev` is the local development binary. Run with no subcommand it behaves exactly like `fcdev start`.
Every subcommand and flag below is also available from `fcdev --help` and `fcdev <command> --help`.

```
fcdev [flags]                 same as fcdev start
fcdev start                   run the dev monolith
fcdev stop                    stop a running instance
fcdev init                    create an application, service account and .env
fcdev fresh                   truncate every table
fcdev db upgrade              move the embedded database to this build's PostgreSQL major
fcdev outbox                  run the outbox poller against an external database
fcdev outbox create-table     create the outbox table in an application's database
fcdev mcp                     run the MCP server
fcdev fn ...                  build, run and publish functions
fcdev upgrade                 update fcdev itself
fcdev version                 print the version
```

`fcdev --version` prints the same string as `fcdev version`: the version from the release, plus the
short git revision when the binary was built inside a checkout.

## Install and upgrade

Install with the script (macOS and Linux) or PowerShell (Windows):

```sh
curl -fsSL https://raw.githubusercontent.com/flowcatalyst/flowcatalyst/main/install.sh | sh
```

```powershell
irm https://raw.githubusercontent.com/flowcatalyst/flowcatalyst/main/install.ps1 | iex
```

Release assets are named with Go's `GOOS-GOARCH` convention: `darwin-arm64`, `darwin-amd64`,
`linux-amd64`, `linux-arm64` and `windows-amd64`. The installers verify the archive's SHA-256 checksum.
Both honour the same variables:

| Variable | Default | Purpose |
|---|---|---|
| `FC_DEV_VERSION` | latest stable | Pin a version, for example `0.5.0` (the leading `v` is optional). |
| `FC_DEV_INSTALL_DIR` | `/usr/local/bin` if writable, else `~/.local/bin` (Windows: `%LOCALAPPDATA%\Programs\fcdev`) | Where to put `fcdev`. |
| `FC_DEV_FORCE` | `0` | `1` reinstalls even when the version is already present. |

To install by hand, download the archive and its `.sha256` sidecar from the repository's releases page,
verify with `shasum -a 256 -c`, extract and put `fcdev` on your `PATH`. On macOS, remove the quarantine
attribute from a manually downloaded binary: `xattr -d com.apple.quarantine /usr/local/bin/fcdev`.
Linux archives are additionally signed with Sigstore cosign (keyless); each release's notes give the
exact `cosign verify-blob` identity to use. macOS and Windows archives are not yet code-signed.

Once installed, `fcdev` updates itself (see [`fcdev upgrade`](#fcdev-upgrade)).

## fcdev start

Runs the platform API, router, dispatch scheduler, stream processor, scheduled-job engine and function
runner in one process, against an embedded PostgreSQL 18 unless you give it a database. The embedded
database's binaries are downloaded on first use and cached.

| Flag | Default (env) | Purpose |
|---|---|---|
| `--api-port` | `8080` (`FC_API_PORT`) | API and console port. |
| `--metrics-port` | `9090` (`FC_METRICS_PORT`) | Metrics listener port. |
| `--embedded-db` | `true` (`FC_EMBEDDED_DB`) | Start an embedded PostgreSQL. |
| `--embedded-db-port` | `15432` (`FC_EMBEDDED_DB_PORT`) | Embedded PostgreSQL port. |
| `--embedded-db-path` | `<user-data-dir>/flowcatalyst/embedded-pg` (`FC_EMBEDDED_DB_PATH`) | Data directory. |
| `--embedded-db-reset` | `false` | Wipe the embedded data directory before starting. |
| `--database-url` | none (`FC_DATABASE_URL`) | Use this PostgreSQL instead of the embedded one. |
| `--scheduler` | `true` (`FC_SCHEDULER_ENABLED`) | Run the dispatch scheduler. |
| `--scheduled-job` | `true` (`FC_SCHEDULED_JOB_ENABLED`) | Run the scheduled-job engine. |
| `--stream` | `true` (`FC_STREAM_PROCESSOR_ENABLED`) | Run the stream processor. |
| `--router` | `true` (`FC_ROUTER_ENABLED`) | Run the message router, on the embedded PostgreSQL broker by default. |
| `--outbox` | `false` (`FC_OUTBOX_ENABLED`) | Run the outbox processor. |
| `--mcp` | `false` (`FC_MCP_ENABLED`) | Run the MCP HTTP server. |
| `--functions` | `true` (`FC_FUNCTIONS_ENABLED`) | Run the function runner in-process. |
| `--functions-port` | `8095` (`FC_FUNCTIONS_PORT`) | Function runner private entry (`/fn/...`). |
| `--functions-public-port` | `8096` (`FC_FUNCTIONS_PUBLIC_PORT`) | Function runner public entry (host routing). `0` turns it off. |
| `--functions-memory-mb` | `256` (`FC_FUNCTIONS_MEMORY_LIMIT_MB`) | Memory the runner may use. |
| `--pid-file` | `<user-data-dir>/flowcatalyst/fcdev.pid` (`FC_DEV_PID_FILE`) | PID file used by `fcdev stop`. |

What it does on every start, in order: starts the embedded database, applies migrations, creates
`admin@flowcatalyst.local` with the password `DevPassword123!` if no platform administrator exists
(`FLOWCATALYST_BOOTSTRAP_ADMIN_EMAIL`, `_PASSWORD` and `_NAME` override these), persists a JWT signing key
and a field-encryption key next to the data directory, bootstraps credentials for the MCP server, the
router and the function runner, and starts the subsystems. It serves the embedded web console when the
binary was built with one.

To run several `fcdev` instances side by side, give each its own `--api-port`, `--metrics-port`,
`--embedded-db-port`, `--embedded-db-path`, `--functions-port`, `--functions-public-port` and
`--pid-file`.

## fcdev stop

Sends `SIGTERM` to the instance recorded in the PID file so it drains and stops the embedded database,
and escalates to `SIGKILL` only if it overruns. Stopping when nothing is running is not an error.

| Flag | Default | Purpose |
|---|---|---|
| `--pid-file` | as for `start` | The PID file to read. |
| `--timeout` | `20s` | How long to wait before `SIGKILL`. |

## fcdev init

Scaffolds what an application needs, against a running platform's database: an administrator (only if
none exists), a default client, an application, an application-scoped service account, and a
confidential OAuth client for it. It writes the credentials to a `.env` file in `--root` and shows the
client secret **once**: the platform keeps only a hash and cannot show it again.

`fcdev init` connects to the database but does not start it, so run `fcdev start` first (it expects the
embedded database on port `15432` unless you pass `--database-url`).

| Flag | Default | Purpose |
|---|---|---|
| `--database-url` | embedded, port 15432 (`FC_DATABASE_URL`) | PostgreSQL to use. |
| `--yes` | `false` | Non-interactive: fail if a required value is missing. |
| `--root` | `.` | Directory to write `.env` into. |
| `--admin-email`, `--admin-password` | none (`FC_BOOTSTRAP_ADMIN_EMAIL`, `FC_BOOTSTRAP_ADMIN_PASSWORD`) | The administrator to create if none exists. |
| `--code` | prompted | The application code (a URL-safe slug, for example `orders`). |
| `--name` | prompted | The application name. |
| `--app-type` | `APPLICATION` | `APPLICATION` or `INTEGRATION`. |
| `--description`, `--default-base-url` | empty | Optional application fields. |
| `--client-identifier`, `--client-name` | `default`, `Default Client` | The default client. |
| `--api-base-url` | `http://localhost:8080` | Written to `FLOWCATALYST_BASE_URL`. |

It writes `FLOWCATALYST_BASE_URL`, `FLOWCATALYST_APP_CODE`, `FLOWCATALYST_CLIENT_ID`,
`FLOWCATALYST_CLIENT_SECRET` and `FLOWCATALYST_APP_KEY`.

> **The encryption key must match the running platform's.** The OAuth client secret is stored
> encrypted with the field-encryption key. `fcdev start` keeps its key in a file named `app-key` in the
> `flowcatalyst` directory under your data directory, but `fcdev init` takes `FLOWCATALYST_APP_KEY` from
> its own environment and generates a **new** key if it is unset. A secret created under a different key
> cannot be verified by the running platform, and the token request fails with `invalid_client`. Export the
> running instance's key before running `init`, for example
> `FLOWCATALYST_APP_KEY=$(cat <data-dir>/flowcatalyst/app-key) fcdev init`. Or skip `init` and create
> the service account in the console.

The service account `init` creates is confined to its application, but it starts with **no roles**: its
first calls (publishing events, syncing definitions) fail with `PERMISSION_REQUIRED`. In the console,
assign it the built-in **`platform:application-service`** role. That role covers publishing events and the
application's definition-sync endpoints (event types, subscriptions, connections, roles, scheduled
jobs, processes, OpenAPI and documentation) plus the outbox batch endpoints, all confined to its own
application. It does not open the administrative endpoints such as `POST /api/event-types`; register
definitions through sync, or as an administrator.

## fcdev fresh

Removes every row from every FlowCatalyst table, returning the database to a post-migration state, and
keeps the schema and migration tracker. It refuses to run without `--yes`. If you give no
`--database-url` it starts the embedded database itself (same data directory as `start`), so you do not
need `fcdev start` running.

Flags: `--yes` (required), `--database-url`, `--embedded-db-port`, `--embedded-db-path`.

## fcdev db upgrade

A PostgreSQL major-version upgrade is not in place, and the bundled distribution carries no `pg_dump` or
`pg_upgrade`. `fcdev db upgrade` re-initialises the embedded cluster on the major version this build
embeds: it moves the old data directory aside to a timestamped backup (unless `--no-backup`), initialises
a fresh cluster, and re-runs migrations and seeding. A development database is reproducible from
those, so this is the intended path. Stop `fcdev start` first.

Flags: `--embedded-db-port`, `--embedded-db-path`, `--no-backup`, `--yes` (skip the confirmation).

## fcdev outbox

A standalone [outbox](../concepts/outbox.md) poller: it reads the `outbox_messages` table in **your
application's** PostgreSQL and forwards rows to a platform. Use it when your application's database
cannot be the embedded one. It loads `./.env` first (existing environment variables win).

```sh
fcdev outbox --source-db-url postgres://user:pass@localhost:5432/app \
  --target-url http://localhost:8080 \
  --client-id "$FLOWCATALYST_CLIENT_ID" --client-secret "$FLOWCATALYST_CLIENT_SECRET"
```

| Flag | Default (env) | Purpose |
|---|---|---|
| `--source-db-url` | none (`FC_OUTBOX_SOURCE_DB_URL`) | **Required.** The application's database. |
| `--target-url` | `http://localhost:8080` (`FC_OUTBOX_PLATFORM_URL`) | The platform. |
| `--auth-token` | none (`FC_OUTBOX_PLATFORM_AUTH_TOKEN`) | A static bearer token, used when there is no client id and secret. |
| `--client-id`, `--client-secret` | none (`FC_OUTBOX_CLIENT_ID`, `FC_OUTBOX_CLIENT_SECRET`; fall back to `FLOWCATALYST_CLIENT_ID`, `FLOWCATALYST_CLIENT_SECRET`) | Mint and refresh a token with `client_credentials`. Preferred. |
| `--token-url` | `<target-url>/oauth/token` (`FC_OUTBOX_TOKEN_URL`) | The token endpoint. |
| `--scope` | none (`FC_OUTBOX_SCOPE`) | Optionally narrow the minted token. |
| `--batch-size` | library default 100 (`FC_OUTBOX_BATCH_SIZE`) | Rows per poll. |
| `--max-in-flight` | library default 1000 (`FC_OUTBOX_MAX_IN_FLIGHT`) | Outstanding HTTP requests. |
| `--poll-interval-ms` | library default 1000 (`FC_OUTBOX_POLL_INTERVAL_MS`) | Sleep between empty polls. |
| `--env-file` | `.env` | Dotenv file to load. |

It creates the `outbox_messages` table in the source database if it does not exist.

### fcdev outbox create-table

Creates the `outbox_messages` table (or, for MongoDB, its indexes) in an application's database. The
shape is identical to every SDK's migration, and the command is idempotent.

```sh
fcdev outbox create-table --db-type pg --db-url postgres://user:pass@localhost:5432/app
fcdev outbox create-table --db-type mysql --db-url 'user:pass@tcp(localhost:3306)/app'
fcdev outbox create-table --db-type mongodb --db-url mongodb://localhost:27017 --db-name app
```

Flags: `--db-type` (`postgres`, `mysql` or `mongodb`; default `postgres`; env `FC_OUTBOX_BACKEND`),
`--db-url` (required; env `FC_OUTBOX_SOURCE_DB_URL`), `--db-name` (MongoDB only; default
`flowcatalyst`).

## fcdev mcp

Runs the read-only Model Context Protocol server so an AI assistant can inspect the platform. It speaks
JSON-RPC over standard input and output by default, which is how an MCP client launches it as a
subprocess. `--http 127.0.0.1:8090` listens for streamable HTTP instead (at `/mcp`). `fcdev start --mcp`
runs the HTTP server alongside everything else. `fcdev` bootstraps local MCP credentials automatically.

Flags: `--http`, `--platform-url` (overrides `FLOWCATALYST_URL`), `--client-id` (overrides
`FLOWCATALYST_CLIENT_ID`), `--client-secret` (overrides `FLOWCATALYST_CLIENT_SECRET`).

## fcdev fn

Builds, checks, runs and publishes [functions](../concepts/functions.md).

| Command | Purpose |
|---|---|
| `fcdev fn init <dir> --lang go\|rust\|ts --app <code> [--sdk-path <clients dir>]` | Scaffold a project. The directory name is the function name. |
| `fcdev fn build [dir]` | Build with the project's toolchain, then read and validate its declarations. |
| `fcdev fn describe <artifact> [--runtime wasm\|js] [--json]` | Print and validate an artifact's declarations as publishing reads them. |
| `fcdev fn run <artifact> [--port 8099] [--address local.fn] [--config K=V] [--secret K=V] [--db NAME=DSN] [--permission P] [--webhook-secret S] [--memory-mb 256] [--watch]` | Serve one function on the real runner with no platform. |
| `fcdev fn publish <address> <artifact> [--create] [--client <id>] [--pool <p>] [--runtime ...]` | Upload an artifact as a new version (changes nothing that is running). |
| `fcdev fn promote <address> <version> [--alias live]` | Point an alias at a ready version. |
| `fcdev fn deploy <address> [dir\|artifact] [--create] [--client <id>] [--pool <p>] [--wait 1m]` | Build, publish, wait until a runner has loaded it, and promote to `live`. |
| `fcdev fn set <address> [--config K=V] [--secret K=V] [--db NAME=DSN]` | Set config values, secrets and database DSNs. |
| `fcdev fn invoke <address>[@alias\|@vN] [path] [-X method] [-d data\|@file] [-H header] [--anonymous]` | Call a function through a runner. |
| `fcdev fn status <address>` | Show a function's versions and aliases. |

The platform commands (`publish`, `promote`, `deploy`, `set`, `invoke`, `status`) share
`--platform` (env `FC_PLATFORM_URL`), `--runner` (env `FC_RUNNER_URL`), `--client-id` (env
`FC_CLIENT_ID`) and `--client-secret` (env `FC_CLIENT_SECRET`). Against a local `fcdev` they sign in
by themselves; elsewhere supply a service account that holds `platform:function-publisher` (and
`platform:function:function:manage` to create functions).

## fcdev upgrade

Updates `fcdev` to the latest GitHub release: it downloads the archive for your platform, verifies its
SHA-256 checksum, and atomically replaces the running binary.

| Flag | Purpose |
|---|---|
| `--check` | Only report whether a newer release exists. |
| `--force` | Reinstall even when already on the latest version. |

`FC_DEV_UPGRADE_REPO` (default `flowcatalyst/flowcatalyst`) points it at a different repository, for
example a fork.

## fcdev version

Prints `fcdev <version>`, with the short git revision appended when the binary was built from a
checkout.
