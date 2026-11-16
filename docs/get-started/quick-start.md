# Quick start

This page gets a complete FlowCatalyst platform running on your machine in a few minutes. You use
**`fcdev`**, the local development binary: the platform API, router, dispatch scheduler, stream
processor, scheduled-job engine, function runner and web console in one process, backed by an
embedded PostgreSQL 18. You need no Docker, no queue service and no Redis.

## Install fcdev

`fcdev` ships pre-built for macOS (Apple Silicon and Intel), Linux (x86_64 and arm64) and Windows
(x86_64).

macOS or Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/flowcatalyst/flowcatalyst/main/install.sh | sh
```

Windows (PowerShell 5.1 or later):

```powershell
irm https://raw.githubusercontent.com/flowcatalyst/flowcatalyst/main/install.ps1 | iex
```

The script detects your platform, downloads the matching release archive, verifies its SHA-256
checksum, and installs `fcdev` to `/usr/local/bin` if that is writable, otherwise to `~/.local/bin`.
On Windows it installs to `%LOCALAPPDATA%\Programs\fcdev` and adds that directory to your user
`PATH`; open a new terminal afterwards. Check it worked:

```sh
fcdev version
```

To pin a version or choose the directory, set `FC_DEV_VERSION` or `FC_DEV_INSTALL_DIR` for the
installer. To install by hand, verify signatures, or upgrade later (`fcdev upgrade`), see the
[fcdev CLI reference](../reference/fcdev.md#install-and-upgrade).

## Run it

```sh
fcdev
```

That is identical to `fcdev start`. The first start downloads a platform-specific PostgreSQL bundle, so
it needs network access and takes longer than later starts. After that it applies the database
migrations, seeds the platform's built-in data, creates a bootstrap administrator, and starts every
subsystem. When you see `api server listening` in the log, open
<http://localhost:8080>.

Sign in with the development administrator that `fcdev` creates on first start:

| Field | Value |
|---|---|
| Email | `admin@flowcatalyst.local` |
| Password | `DevPassword123!` |

This account is created only if no platform administrator exists yet, and only by `fcdev`.
`fc-server` never creates one unless you give it explicit credentials, which is deliberate.
These credentials are for a local machine only.

## What is running

| What | Where |
|---|---|
| Web console and API | `http://localhost:8080` |
| Health | `http://localhost:8080/health` |
| Process metrics (Prometheus) | `http://localhost:9090/metrics` |
| Router dashboard | `http://localhost:8080/router/monitoring/dashboard` |
| OpenAPI document | `http://localhost:8080/api/openapi.json`, with a Swagger UI at `/swagger-ui` |
| Embedded PostgreSQL | `localhost:15432`, user `postgres`, password `postgres`, database `flowcatalyst` |
| Function runner | `127.0.0.1:8095` (private entry), `8096` (public entry) |

Every port is a flag: `fcdev --api-port 8081 --metrics-port 9091 --embedded-db-port 15433`. Flags
default from the same environment variables `fc-server` reads (`FC_API_PORT`, `FC_METRICS_PORT`,
and so on), and a flag always wins. The full list is in the [fcdev CLI reference](../reference/fcdev.md).

Press Ctrl-C to stop it, or run `fcdev stop` from another terminal. Both shut the platform down
gracefully and stop the embedded database.

## Where your data lives

The embedded database keeps its data in `flowcatalyst/embedded-pg` under your per-user data
directory (`$XDG_DATA_HOME` if set, otherwise `~/Library/Application Support` on macOS,
`~/.config` on Linux, `%AppData%` on Windows). Next to it `fcdev` keeps the JWT signing key
(`jwt-signing-key.pem`) and the field-encryption key (`app-key`), so tokens and OAuth client secrets
survive restarts. Never in `/tmp`.

To start again with an empty database:

```sh
fcdev start --embedded-db-reset
```

To keep the schema but empty every table, run `fcdev fresh --yes`.

## Build from source instead

Building needs Go 1.27, Node.js and `pnpm`. The web console is a Vue application that is embedded
into the Go binary at compile time, so build it first. If you skip this step the binary still runs
but warns that no console is embedded.

```sh
git clone https://github.com/flowcatalyst/flowcatalyst.git
cd flowcatalyst
make frontend && make go-build
bin/fcdev
```

`make build` does both steps in one go. `make run` runs `fcdev start` through `go run`,
and `make dev` runs it with live reload (it needs [`air`](https://github.com/air-verse/air); `make
install-tools` installs it). When you change frontend code, run `make frontend && make go-build` again,
otherwise the old console is still embedded.

## Next

[Publish your first event](first-event.md).
