# Health and metrics

FlowCatalyst exposes liveness and readiness endpoints, Prometheus metrics, a router dashboard with a
JSON API behind it, structured logs, and the console itself. This page lists what is where.

## Two listeners

| Listener | Default port | Serves |
|---|---|---|
| **API** (`FC_API_PORT`) | `8080` | The platform API and console, `GET /health`, and the router's surface under `/router`. |
| **Metrics** (`FC_METRICS_PORT`) | `9090` | `GET /health`, `GET /ready`, `GET /metrics`. No application endpoints. |

Keep the metrics listener on an internal network. It is unauthenticated.

## Health

| Endpoint | Answers |
|---|---|
| `GET /health` (API or metrics listener) | `{"status":"UP","version":"..."}` while the process is serving. Use it for a liveness probe or load-balancer check. The container image's health check calls it on port 8080. |
| `GET /ready` (metrics listener) | `{"status":"ready", ...}` plus a boolean for each subsystem this process runs: `platform`, `router`, `scheduler`, `scheduled_job`, `stream`, `outbox`, `mcp`. It tells you what is switched on, which is useful for confirming a split deployment started as intended. |
| `GET /router/health`, `/router/health/live`, `/router/health/ready`, `/router/health/startup` | Router probes (`LIVE`, `READY`). Open even when the router's Basic auth is on. |

## Metrics

Prometheus text format, from two places.

**`http://host:9090/metrics`** is the process view: Go runtime and process collectors (goroutines, GC,
heap, scheduler latency, CPU, resident memory, open file descriptors), the dispatch-job lifecycle
counters (for example `fc_dispatch_job_transition_refused_total`), and, when the dispatch scheduler runs
in the process, its series:

| Series | Meaning |
|---|---|
| `fc_scheduler_pending_backlog_jobs` | Pending dispatch jobs waiting to be claimed. |
| `fc_scheduler_pending_oldest_age_seconds` | Age of the oldest pending job. A steadily growing value means the scheduler is not keeping up. |
| `fc_scheduler_jobs_claimed_total`, `fc_scheduler_jobs_published_total` | Throughput of claim and publish. |
| `fc_scheduler_inflight_jobs`, `fc_scheduler_buffer_in_use` | Jobs between claim and publish; how full the buffer is. |
| `fc_scheduler_held_groups`, `fc_scheduler_jobs_skipped_held_total` | Message groups held back by a `BLOCK_ON_ERROR` failure, and jobs skipped because of it. |
| `fc_scheduler_paused_subscriptions` | Paused subscriptions. |
| `fc_scheduler_stale_jobs_recovered_total` | Jobs reverted to pending because they sat queued or processing too long. |
| `fc_scheduler_poll_duration_seconds`, `fc_scheduler_claim_duration_seconds`, `fc_scheduler_poll_errors_total`, `fc_scheduler_last_successful_poll_timestamp_seconds` | Health of the claim loop. |

**`http://host:8080/router/metrics`** (the router prefix on the API listener) carries the router's own
series:

| Series | Meaning |
|---|---|
| `fc_messages_submitted_total`, `fc_messages_processed_total` | Messages entering and leaving the pools. |
| `fc_mediation_duration_seconds` | Histogram of delivery-callback duration. |
| `fc_pool_active_workers`, `fc_pool_queue_size`, `fc_pool_message_groups` | Per-pool concurrency in use, buffered messages, live message groups. |
| `fc_queue_pending_messages`, `fc_queue_in_flight_messages`, `fc_queue_messages_total` | Per-queue depth and flow. |
| `fc_consumer_polls_total`, `fc_consumer_messages_received_total` | Consumer activity. |
| `fc_in_pipeline_messages` | Messages the router is currently holding. |
| `fc_circuit_breaker_open`, `fc_circuit_breaker_calls_total` | Circuit-breaker state and calls per target. |
| `fc_rate_limit_exceeded_total` | Messages delayed by a pool's rate limiter. |
| `fc_router_panics_recovered_total` | Recovered panics: should stay at zero. |

## The router dashboard and monitoring API

With the router enabled, `http://host:8080/router/monitoring/dashboard` is an HTML dashboard of pools,
queues, circuit breakers, in-flight messages and warnings. The same data is available as JSON under
`/router/monitoring/` (the prefix is `FC_ROUTER_HTTP_PREFIX`):

| Endpoint | Shows |
|---|---|
| `GET /monitoring/health` | Overall health: healthy queues and pools, active and critical warnings, uptime. |
| `GET /monitoring/pool-stats` | Per pool: processed, succeeded, failed, rate-limited and deferred totals, active workers, available permits, queue size and capacity. |
| `GET /monitoring/queue-stats`, `/monitoring/queues` | Per queue: messages, consumed, failed, deferred, depth, throughput. |
| `GET /monitoring/circuit-breakers` | Breaker state per target (`CLOSED`, `OPEN`, `HALF_OPEN`). |
| `GET /monitoring/in-flight-messages`, `/monitoring/mediating` | What the router is working on right now. |
| `GET /monitoring/blocked-groups` | Every live message group across all pools, optionally filtered with `?poolCode=`. |
| `GET /monitoring/group-flushes` | Active target-requested group suppressions. |
| `GET /monitoring/consumer-health` | Each consumer's polling state. |
| `GET /monitoring/warnings` | Warnings, including `/unacknowledged` and `/severity/{severity}`. |
| `GET /monitoring/stream-health`, `/live`, `/ready` | Health of the stream processor's projections. |
| `GET /monitoring/standby-status` | Whether leader election is on and whether this instance is the leader. |

There are also operator actions: `POST /monitoring/circuit-breakers/{name}/reset` and `/reset-all`,
`POST /monitoring/warnings/{id}/acknowledge`, `PUT /monitoring/pools/{poolCode}` to change a pool,
`POST /monitoring/in-flight-messages/{messageId}/ack` to force-acknowledge a message, and
`POST /monitoring/group-flushes/{pool}/{group}/clear` to lift a suppression early.

If you set `FC_ROUTER_AUTH_USER` and `FC_ROUTER_AUTH_PASS`, the `/router` surface requires HTTP Basic auth,
apart from the health probes, `/router/metrics` and the OpenAPI document, which stay open so
orchestration and Prometheus need no credentials. Leaving them empty disables auth there, which is how
`fcdev` runs. In production, set them or keep the surface off the public network.

The router also publishes its own OpenAPI document at `/router/openapi.json`.

## Warnings and notifications

The router keeps a list of warnings: stalled messages, queue backlogs, routing and configuration
problems. They are visible on the dashboard and at `/monitoring/warnings`. Set `FC_NOTIFY_WEBHOOK_URL`
and the router also posts them to that webhook in batches (every 300 seconds, or at once for a
`CRITICAL` warning or a full batch of 20); `FC_NOTIFY_MIN_SEVERITY` sets the floor.

## Logs

Logs are structured JSON on standard output and error, one object per line, with `time`, `level` and
`msg` plus fields. Set the level with `FC_LOG_LEVEL`. A panic that escapes start-up is logged as a
structured `fc-server: panic, exiting` line before the process exits.

## In the console

Operators rarely need the metrics endpoints to start. The console has **Events** and **Dispatch Jobs**
list pages with filtering, per-job attempt history, **Audit Log**, **Login Attempts**, and raw-event and
raw-dispatch-job views for administrators who hold the view-raw permission. See
[Troubleshooting dispatch](troubleshooting-dispatch.md) for how to use them together.
