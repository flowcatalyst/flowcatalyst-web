# Deployment

Production runs **`fc-server`**, one binary whose subsystems are switched on and off by environment
variables. The same image is the API tier, a worker tier, or everything at once. There are no config
files: configuration is environment-first (see [Configuration](configuration.md)).

## What you need

- **PostgreSQL.** The platform's only required dependency. It needs no extensions: partitioning is
  managed in-process, with no `pg_partman` or `pg_cron`. Migrations are embedded in the binary and
  run at start-up.
- **A queue**, for dispatch jobs. Either the platform's own PostgreSQL (the default, and what `fcdev`
  uses) or **SQS FIFO** queues. Choose with `FC_DISPATCH_QUEUE_TYPE`.
- **Redis**, only if you run more than one instance of a subsystem and want leader election
  (`FC_STANDBY_ENABLED`).
- Optionally: SMTP for email, an S3 bucket for function artifacts, AWS Secrets Manager for database
  credentials, an ALB for router self-registration.

## The image

The repository's `Dockerfile` builds a minimal image: a static `fc-server` with the web console and the
SQL migrations embedded, running as a non-root user (uid 10001).

```sh
docker build -t flowcatalyst --build-arg VERSION=$(git rev-parse --short HEAD) .
docker run -p 8080:8080 -e FC_DATABASE_URL=postgresql://... flowcatalyst
```

It exposes `8080` (API and console) and `9090` (Prometheus metrics), and declares a health check
against `GET /health` on port 8080. `docker-compose.yml` in the repository is an example stack with
PostgreSQL, Redis and `fc-server`. It is a deployment scaffold, not the development loop; use
[`fcdev`](../reference/fcdev.md) for that.

## The minimum production configuration

Out of the box `fc-server` will start, but several defaults exist for convenience and are not safe to
keep:

| Setting | Why it matters |
|---|---|
| `FC_DATABASE_URL` (or `DB_HOST` and friends) | Without it the server uses a local-development connection string. |
| A JWT signing key: `FLOWCATALYST_JWT_PRIVATE_KEY` or `FC_JWT_SIGNING_KEY_PEM` (inline PEM), or `FC_JWT_SIGNING_KEY_PATH` | If none is set, an **ephemeral** key is generated: tokens do not survive a restart, and replicas reject each other's tokens. |
| `FLOWCATALYST_APP_KEY` | The field-encryption key (32 random bytes, base64: `openssl rand -base64 32`). Without it, minting confidential OAuth client secrets fails, and the dispatch scheduler **refuses to start**, because its dispatch-auth secret is derived from this key. |
| `FC_JWT_ISSUER` | The issuer and audience for tokens and the platform's external base URL, for example `https://platform.example.com`. The default is `http://localhost:8080`. |
| `FLOWCATALYST_BOOTSTRAP_ADMIN_EMAIL` and `FLOWCATALYST_BOOTSTRAP_ADMIN_PASSWORD` | Creates the first platform administrator, only if none exists and only when **both** are set. Without them production starts with no administrator, by design. |
| `FC_WEBAUTHN_RP_ID`, `FC_WEBAUTHN_ORIGINS` | Passkeys. Defaults are `localhost`. |
| `FC_SMTP_HOST` and related | Without it password-reset and 2FA emails are logged, not sent. |

Keep the encryption key and the signing key across restarts and across replicas. Rotation is supported:
set `FLOWCATALYST_APP_KEY_PREVIOUS` (decryption falls back to it while new writes use the current key),
and `FLOWCATALYST_JWT_PREVIOUS_PUBLIC_KEY` for zero-downtime signing-key rotation.

## Deployment shapes

### One instance, everything on

The simplest production shape. Enable the subsystems you use on a single `fc-server`:

```sh
FC_PLATFORM_ENABLED=true
FC_STREAM_PROCESSOR_ENABLED=true
FC_SCHEDULER_ENABLED=true
FC_ROUTER_ENABLED=true
FC_SCHEDULED_JOB_ENABLED=true
```

With the default `FC_DISPATCH_QUEUE_TYPE` (empty) the dispatch queue is the platform's own
PostgreSQL, so this needs nothing but a database. The router fetches its pool and queue configuration from
the platform it runs beside: set `FLOWCATALYST_CONFIG_URL` to the platform's
`/api/dispatch/router-config` and give the router a client credential
(`FC_ROUTER_PLATFORM_URL`, `FC_ROUTER_CLIENT_ID`, `FC_ROUTER_CLIENT_SECRET`); the `fcdev` bootstrap does
this for you locally. The router's own service account needs the built-in `platform:router` role.
Unset `FLOWCATALYST_CONFIG_URL` and the router starts with **no queues and no pools**.

### Split tiers

Run several `fc-server` instances with different subsystems enabled, for example:

| Tier | Enabled | Needs a database |
|---|---|---|
| API | `FC_PLATFORM_ENABLED` | yes |
| Workers | `FC_STREAM_PROCESSOR_ENABLED`, `FC_SCHEDULER_ENABLED`, `FC_SCHEDULED_JOB_ENABLED` | yes |
| Router | `FC_ROUTER_ENABLED` only | **no**: it reads its configuration from the platform's API and processes the queue |
| Outbox | `FC_OUTBOX_ENABLED` | yes (the outbox backend) |
| Functions | `FC_FUNCTIONS_ENABLED` only | no |

When the router runs in a separate task from the platform, point `FC_DISPATCH_PROCESSING_ENDPOINT` at
the platform so the router knows where to send each delivery callback, for example
`http://fc-platform:8080/api/dispatch/process`.

The web console is served only by an instance with the platform enabled. A router-only or
worker-only instance does not serve it; the router's own dashboard and API live under `/router` there.

### SQS FIFO queues

For SQS, set `FC_DISPATCH_QUEUE_TYPE=SQS`, `FC_DISPATCH_QUEUE_URL` (used only to derive the AWS account
id and region) and `FC_DISPATCH_QUEUE_PREFIX` (the `FC-{env}` prefix every queue name starts with, for
example `FC-staging`; **required** for SQS, and a blank prefix is a start-up error). The platform
composes one queue per tenant and priority, for instance `FC-staging-acme-DEFAULT.fifo`, and advertises
them to the router in the served configuration document. Ordered delivery needs FIFO queues; a
non-FIFO queue would reorder when a message is released.

### High availability

Run two or more instances and set `FC_STANDBY_ENABLED=true` with `FC_STANDBY_REDIS_URL`. Subsystems
that must have a single active instance take a Redis lock: the router's pools, the dispatch scheduler,
the scheduled-job engine, the stream processor and the outbox processor. Each elects independently on a
subsystem-suffixed key, and an election failure **fails closed**, meaning that node sits out rather than
risk running twice. The platform API tier does not need an election: run several instances behind a load balancer (the
cluster-wide rate limits use a shared Redis or PostgreSQL store, see `FC_REDIS_URL`).

## Rolling out

- Migrations run at start-up and are idempotent; start one instance first on an upgrade if you want to
  watch them apply.
- On shutdown the router stops polling, drains in-flight work (up to
  `FC_DRAIN_TIMEOUT_SECONDS`, 60 by default), then exits. Give your orchestrator a termination grace
  period at least that long. If it deregisters from a load balancer first
  (`FC_ALB_ENABLED`), no new traffic arrives during the drain.
- Check `GET /health` for liveness. The metrics listener serves `/ready` and `/metrics`
  ([Health and metrics](monitoring.md)).

## Functions in production

The function runner is a subsystem of `fc-server`. A runner-only deployment authenticates to the
platform with `FC_FUNCTIONS_PLATFORM_URL`, `FC_FUNCTIONS_CLIENT_ID` and `FC_FUNCTIONS_CLIENT_SECRET`
for a service account holding `platform:function-runner`. Set `FC_FUNCTIONS_ARTIFACT_STORE` to an
`s3://bucket/prefix` URL in any deployed environment; the default is a local directory.
See [Configuration](configuration.md#function-runner).
