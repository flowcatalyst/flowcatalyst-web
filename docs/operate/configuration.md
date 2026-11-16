# Configuration

`fc-server` is configured **only** through environment variables; there are no config files. `fcdev`
reads the same variable names as flag defaults, and a flag always wins over the environment.

This page covers the settings you will actually change, grouped by purpose. The repository's
`docs/environment-variables.md` is the exhaustive list, with the source location of every read.

Conventions:

- Where two names exist, the `FC_*` name is canonical and the other is a compatibility alias. If both
  are set, the first listed here wins.
- Booleans accept `1/true/yes/on` and `0/false/no/off`, case-insensitively. Anything else falls back
  to the default.
- A number that does not parse silently falls back to the default.

## Subsystems and ports

| Variable | Default | Purpose |
|---|---|---|
| `FC_API_PORT` (alias `PORT`) | `8080` | The API and web console listener. |
| `FC_METRICS_PORT` | `9090` | The `/metrics`, `/health` and `/ready` listener. |
| `FC_PLATFORM_ENABLED` | `true` | The platform API: IAM, events, dispatch, console. |
| `FC_ROUTER_ENABLED` | `false` | The message router. |
| `FC_SCHEDULER_ENABLED` | `false` | The dispatch scheduler. |
| `FC_SCHEDULED_JOB_ENABLED` | `false` | The scheduled-job engine. |
| `FC_STREAM_PROCESSOR_ENABLED` | `false` | Projections, fan-out and partition management. |
| `FC_OUTBOX_ENABLED` | `false` | The outbox processor. |
| `FC_MCP_ENABLED` | `false` | The MCP server (`FC_MCP_PORT` `8090`, bound to `127.0.0.1` unless `FC_MCP_BIND` says otherwise). |
| `FC_FUNCTIONS_ENABLED` | `false` | The function runner. |
| `FC_ROUTER_HTTP_PREFIX` | `/router` | Where the router's API and dashboard are mounted on the API listener. |
| `FC_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error`. Logs are structured JSON. |

## Database

Precedence: a full URL, then AWS Secrets Manager, then explicit `DB_*` credentials, then a local
development default (`postgresql://postgres@localhost:5432/flowcatalyst`).

| Variable | Default | Purpose |
|---|---|---|
| `FC_DATABASE_URL` (alias `DATABASE_URL`) | local default | A full connection string. When set, the others are ignored. |
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USERNAME`, `DB_PASSWORD` | port `5432`, name `flowcatalyst`, user `postgres` | Explicit credentials. `DB_HOST` is required to activate this mode. |
| `DB_SECRET_ARN` | none | An AWS Secrets Manager secret (RDS-style JSON: username, password, port). With `DB_HOST`, enables secret mode; the region comes from the ARN. |
| `DB_SECRET_REFRESH_INTERVAL_MS` | `300000` | How often to poll for rotated credentials. `0` disables rotation. |

The dispatch scheduler opens its own connection pool, sized by `FC_SCHEDULER_DB_MAX_CONNECTIONS`
(default: the number of dispatcher lanes plus two), so it never competes with API requests.

## Authentication and keys

| Variable | Default | Purpose |
|---|---|---|
| `FC_JWT_ISSUER` (aliases `FC_EXTERNAL_BASE_URL`, `EXTERNAL_BASE_URL`) | `http://localhost:8080` | Token issuer and audience, and the platform's external base URL. |
| `FLOWCATALYST_JWT_PRIVATE_KEY`, `FC_JWT_SIGNING_KEY_PEM`, `FC_JWT_SIGNING_KEY_PATH` | none | The RSA signing key, inline PEM (the first two) or a file path. An ephemeral key is generated if none is set. |
| `FLOWCATALYST_JWT_PREVIOUS_PUBLIC_KEY` | none | A previous public key, for validation only, during key rotation. |
| `FC_JWT_ACCESS_TOKEN_TTL_SECS` (alias `OIDC_ACCESS_TOKEN_TTL`) | `3600` | Access-token lifetime. |
| `OIDC_SESSION_TTL` | `86400` | Console session lifetime, seconds. |
| `OIDC_REFRESH_TOKEN_TTL` | `604800` | Refresh-token family lifetime, seconds. It is an absolute cap. |
| `FLOWCATALYST_APP_KEY` | none | The field-encryption key. Required in practice; see [Deployment](deployment.md). |
| `FLOWCATALYST_APP_KEY_PREVIOUS` | none | The previous key, for decryption during rotation. |
| `FLOWCATALYST_BOOTSTRAP_ADMIN_EMAIL`, `_PASSWORD`, `_NAME` | none | Seed the first administrator. Both email and password are required; the name defaults to `Bootstrap Admin`. |
| `FC_WEBAUTHN_RP_ID`, `FC_WEBAUTHN_ORIGINS` | `localhost`, `http://localhost:8080` | Passkey relying-party id and the exact allowed origins, comma-separated. |
| `FC_AUTH_ALLOW_TEST_HEADERS` | `false` | Enables a development header fallback. `fcdev` turns it on. **Never set it in production.** |

### Rate limits and login protection

Cluster-wide limits (`FC_RL_*`) sit behind per-instance in-memory limits (`FC_OAUTH_TOKEN_*`,
`FC_OIDC_*`) as defence in depth. Out of the box: `/oauth/token` at 600 requests per minute per IP and
300 per client id, `/oauth/authorize` the same, and password reset at 20 per IP and 5 per email per
hour. The cluster-wide store is Redis when `FC_REDIS_URL` is set and reachable, otherwise PostgreSQL.
`FC_RATE_LIMIT_DISABLE=1` turns the distributed limits off.

Login backoff is tuned by `FC_LOGIN_BACKOFF_FREE_ATTEMPTS` (3), `FC_LOGIN_BACKOFF_BASE_SECS` (2),
`FC_LOGIN_BACKOFF_MAX_SECS` (300), `FC_LOGIN_GLOBAL_WINDOW_SECS` (3600), `FC_LOGIN_GLOBAL_CEILING`
(100) and `FC_LOGIN_GLOBAL_LOCK_SECS` (900).

## Email

| Variable | Default | Purpose |
|---|---|---|
| `FC_SMTP_HOST` | none | The SMTP server. **Unset means emails are logged instead of sent.** |
| `FC_SMTP_PORT` | `587` | SMTP port. |
| `FC_SMTP_USERNAME`, `FC_SMTP_PASSWORD` | empty | Credentials. Empty username means unauthenticated. |
| `FC_SMTP_FROM` | `noreply@flowcatalyst.local` | The From address. |
| `FC_SMTP_SECURE` | `false` | `true` for implicit TLS (port 465); `false` for STARTTLS. |

Each has a `SMTP_*` alias.

## Dispatch and the router

| Variable | Default | Purpose |
|---|---|---|
| `FC_DISPATCH_QUEUE_TYPE` | empty (PostgreSQL) | `SQS` for SQS FIFO queues; anything else uses the platform's database. |
| `FC_DISPATCH_QUEUE_URL`, `FC_DISPATCH_QUEUE_REGION` | none | Used to derive the AWS account and region for SQS. |
| `FC_DISPATCH_QUEUE_PREFIX` | none | The queue-name prefix (`FC-{env}`). Required for SQS. |
| `FC_DISPATCH_PROCESSING_ENDPOINT` | `http://localhost:<port>/api/dispatch/process` | The delivery callback the router calls. |
| `FC_SCHEDULER_DISPATCHERS` | `10` | Dispatcher lanes that publish claimed jobs. A message group always uses one lane. |
| `FC_SCHEDULER_BATCH_SIZE` | `500` | Most rows one claim asks for. |
| `FC_SCHEDULER_BUFFER_CAPACITY` | `1000` | Most jobs between a claim and a dispatcher finishing them. |
| `FLOWCATALYST_CONFIG_URL` | none | Where the router fetches pools and queues. Unset means no queues and no pools. |
| `FC_ROUTER_PLATFORM_URL`, `FC_ROUTER_CLIENT_ID`, `FC_ROUTER_CLIENT_SECRET` | none | The platform the router authenticates to, with a service-account credential. The pair must be set together. |
| `FC_ROUTER_AUTH_USER`, `FC_ROUTER_AUTH_PASS` | none | HTTP Basic auth on the router surface. Empty disables it. |
| `FC_DRAIN_TIMEOUT_SECONDS` | `60` | The longest the router drains in-flight work on shutdown. |
| `FC_ROUTER_STRICT_ROUTING` | `false` | Treat a message with no pool code, mode or ordered group as malformed. |
| `FC_NOTIFY_WEBHOOK_URL` | none | Where the router posts stall and backlog warnings. Unset means log only. |
| `FC_NOTIFY_MIN_SEVERITY` | `WARNING` | Lowest severity to send: `INFO`, `WARNING`, `ERROR` or `CRITICAL`. |

Deferral and HTTP/2 settings are in [Router tuning](router-tuning.md).

### Stream processor

`FC_STREAM_EVENTS_ENABLED`, `FC_STREAM_DISPATCH_JOBS_ENABLED`, `FC_STREAM_FAN_OUT_ENABLED` and
`FC_STREAM_PARTITION_MANAGER_ENABLED` (all default `true`) switch the parts of the stream processor.
Batch sizes default to 100 (events and dispatch jobs) and 200 (fan-out); `FC_STREAM_BATCH_SIZE`
overrides all, and a per-projection variable overrides that. The fan-out subscription cache refreshes
every 5 seconds (`FC_STREAM_FAN_OUT_SUBS_REFRESH_SECS`).

Partitions are pre-created 3 months ahead (`FC_STREAM_PARTITION_MONTHS_FORWARD`) and dropped after 90
days (`FC_STREAM_PARTITION_RETENTION_DAYS`), except scheduled-job history, which is kept 30 days
(`FC_STREAM_PARTITION_RETENTION_DAYS_SCHEDULED_JOBS`). Partitions are monthly, so the on-disk window
floats between the retention and the retention plus one month.

### Outbox processor

| Variable | Default | Purpose |
|---|---|---|
| `FC_OUTBOX_PLATFORM_URL` | none | **Required.** The platform the outbox delivers to. Aliases `FC_OUTBOX_API_URL`, `FC_API_BASE_URL`, `FLOWCATALYST_URL`. |
| `FC_OUTBOX_PLATFORM_AUTH_TOKEN` | empty | A bearer token for the platform. |
| `FC_OUTBOX_BATCH_SIZE` | 100 | Rows per poll. |
| `FC_OUTBOX_MAX_IN_FLIGHT` | 1000 | Cap on outstanding HTTP requests. |
| `FC_OUTBOX_POLL_INTERVAL_MS` | 1000 | Sleep between empty polls. |
| `FC_OUTBOX_MAX_CONCURRENT_GROUPS` | 10 | Message groups processed at once. |
| `FC_OUTBOX_BLOCK_ON_ERROR` | `true` | Stop a group at a failing row so the rest re-run in order behind it. |
| `FC_OUTBOX_BACKEND` | `postgres` | `postgres` (the shared pool) or `mongo`. |
| `FC_OUTBOX_ADMIN_PORT` | `0` (off) | Serves the group-control API on `127.0.0.1:<port>`. |

### Scheduled jobs

`FC_SCHEDULED_JOB_POLL_SECONDS` (30), `FC_SCHEDULED_JOB_DISPATCH_SECONDS` (5),
`FC_SCHEDULED_JOB_DISPATCH_BATCH` (32) and `FC_SCHEDULED_JOB_HTTP_TIMEOUT_SECONDS` (10).

### Leader election

| Variable | Default | Purpose |
|---|---|---|
| `FC_STANDBY_ENABLED` | `false` | Enable Redis leader election for HA. |
| `FC_STANDBY_REDIS_URL` | `redis://127.0.0.1:6379` | The Redis to elect on. |
| `FC_STANDBY_LOCK_KEY` | `fc:server:leader` | The lock key. Each subsystem elects on a suffixed key. |

## Outbound delivery guard

A subscription endpoint, a scheduled-job target or a direct dispatch-job `targetUrl` is customer input
that the platform `POST`s to from inside your network. The guard refuses destinations that could
expose the cluster: at write time (a `400` with `INVALID_ENDPOINT` or `INVALID_TARGET_URL`) and again at
dial time, after DNS resolution, so a hostname that resolves to a forbidden address is refused too.
Cloud metadata addresses (`169.254.169.254`, `fd00:ec2::254`), link-local, unspecified and multicast
addresses are **always** refused.

| Variable | Default | Effect |
|---|---|---|
| `FC_DELIVERY_ALLOW_LOOPBACK` | `false` | Permit `127.0.0.0/8`, `::1` and `localhost`. Development only. |
| `FC_DELIVERY_ALLOW_PRIVATE` | `false` | Permit RFC 1918, `fc00::/7` and CGNAT (`100.64.0.0/10`). Off, because these are your pods, services and internal APIs. |
| `FC_DELIVERY_ALLOW_HOSTS` | none | Comma-separated `host:port` patterns (`*` wildcard) exempt from the checks, for a specific private target, for example `partner-gw.example.net:443`. |

The guard applies to platform deliveries (subscription webhooks, direct dispatch jobs and scheduled
jobs). The platform's own endpoints are exempted automatically. `fcdev` allows loopback and private
targets.

## Function runner

| Variable | Default | Purpose |
|---|---|---|
| `FC_FUNCTIONS_ENABLED` | `false` (`fcdev`: `true`) | Run the runner. |
| `FC_FUNCTIONS_PORT` | `8095` | The private entry (`/fn/...`). |
| `FC_FUNCTIONS_PUBLIC_PORT` | `0` off (`fcdev`: `8096`) | The public entry, with host-based routing. |
| `FC_FUNCTIONS_BIND` | `0.0.0.0` | Listen address for both entries. |
| `FC_FUNCTIONS_POOL` | `default` | The runner pool this process serves. |
| `FC_FUNCTIONS_PLATFORM_URL` | the local API when the platform runs here | Where the control plane and token endpoint live. |
| `FC_FUNCTIONS_CLIENT_ID`, `FC_FUNCTIONS_CLIENT_SECRET` | none | The runner's service-account credential (`platform:function-runner`). |
| `FC_FUNCTIONS_MEMORY_LIMIT_MB`, `FC_FUNCTIONS_MEMORY_RESERVE_MB` | detected from the container | The memory budget and the runner's own reserve. |
| `FC_FUNCTIONS_CACHE_DIR` | none | Where compiled artifacts are cached. |
| `FC_FUNCTIONS_IDLE_EVICT_SECONDS` | `1800` | Idle time before a loaded function is evicted. |
| `FC_FUNCTIONS_TRUSTED_PROXIES` | none | CIDRs or addresses of proxies whose forwarded host is trusted. |
| `FC_FUNCTIONS_ARTIFACT_STORE` | a local directory | `file:///abs/path` or `s3://bucket/prefix`. Use S3 in any deployed environment. |
| `FC_FUNCTIONS_RUNNER_URL` | `http://127.0.0.1:8095` | On the platform: the runner's base URL, templated with `{pool}`. |

## Debugging

`FC_DEBUG_ENDPOINTS_ENABLED=true` mounts `pprof`, `expvar` and a router dump under
`<FC_ROUTER_HTTP_PREFIX>/debug/`. It is never anonymous: it requires the router's Basic auth when that is
configured, otherwise an anchor principal's bearer token or session. Independently of the flag,
`SIGQUIT` writes the same dump to stderr and keeps the process running; a second `SIGQUIT` within five
seconds restores Go's default of dump and exit.
