# fc-server

`fc-server` is the production server: the whole platform in one static binary. It has **no
subcommands and no flags**. Everything is configured through environment variables (see
[Configuration](../operate/configuration.md) and [Deployment](../operate/deployment.md)), and the
subsystems it runs are the ones you switch on.

```sh
FC_DATABASE_URL=postgresql://... \
FLOWCATALYST_APP_KEY=... \
FC_JWT_ISSUER=https://platform.example.com \
FC_STREAM_PROCESSOR_ENABLED=true FC_SCHEDULER_ENABLED=true \
  fc-server
```

## Get the binary

| How | Command |
|---|---|
| Build from source | `make frontend && make go-build`, then `bin/fc-server`. `make build-release` makes an optimised build (`-trimpath`, stripped). |
| Run from source | `make run-server` (runs `go run ./cmd/fc-server`). |
| Container image | `docker build -t flowcatalyst .` builds an image whose entrypoint is `fc-server`. See [Deployment](../operate/deployment.md#the-image). |

The web console is compiled into the binary, so build the frontend first (`make frontend`) or the
binary runs without a console. Only the `fcdev` binary is attached to the project's GitHub releases;
`fc-server` is built by you or by the container image.

## Start-up

On start, `fc-server`:

1. reads its environment and logs which subsystems are enabled;
2. applies the outbound delivery policy and tunes the Go runtime for its container limits
   ([Router tuning](../operate/router-tuning.md#runtime-tuning-at-start-up));
3. connects to PostgreSQL, **if** any database-backed subsystem is enabled (the platform, stream
   processor, scheduler, scheduled-job engine or outbox). A router-only or functions-only instance skips
   the database entirely. In AWS Secrets Manager mode it resolves credentials from the secret and polls
   for rotation;
4. applies the embedded migrations, then the idempotent seed (built-in roles, permissions, platform
   event types, and the bootstrap administrator when both bootstrap variables are set);
5. starts the enabled subsystems, serving the console only when the platform is enabled and the binary
   embeds one.

A fatal start-up error is logged and the process exits with status 1; a panic during start-up is logged
as a structured line and exits with status 2.

## Signals

| Signal | Effect |
|---|---|
| `SIGTERM`, `SIGINT` | Graceful shutdown: the router stops polling and drains in-flight work (up to `FC_DRAIN_TIMEOUT_SECONDS`, 60), then everything stops. |
| `SIGQUIT` | Writes a dump of every router worker and goroutine stack to standard error and **keeps running**. A second `SIGQUIT` within five seconds restores Go's default and exits. |

## Ports

| Port | Default | Variable |
|---|---|---|
| API and console | `8080` | `FC_API_PORT` (or `PORT`) |
| Metrics, `/health`, `/ready` | `9090` | `FC_METRICS_PORT` |
| MCP server (when enabled) | `127.0.0.1:8090` | `FC_MCP_PORT`, `FC_MCP_BIND` |
| Function runner private entry (when enabled) | `8095` | `FC_FUNCTIONS_PORT` |
| Function runner public entry (when enabled) | off | `FC_FUNCTIONS_PUBLIC_PORT` |

## fcdev versus fc-server

| | `fcdev` | `fc-server` |
|---|---|---|
| Purpose | Local development | Production |
| Database | Embedded PostgreSQL, or `--database-url` | Your PostgreSQL; required by most subsystems |
| Queue | Built-in PostgreSQL broker | PostgreSQL broker or SQS FIFO |
| Subsystems on by default | scheduler, stream, scheduled jobs, router, functions | platform only |
| Keys | Generated and persisted for you | You supply them, or tokens do not survive a restart |
| Bootstrap administrator | `admin@flowcatalyst.local` / `DevPassword123!` | None unless you set both bootstrap variables |
| Configuration | Flags, defaulting from the same environment variables | Environment only |

Both run the same code: `fcdev` wraps the same server run loop with an embedded database and development
defaults.
