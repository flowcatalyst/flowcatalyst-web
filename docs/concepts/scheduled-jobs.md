# Scheduled jobs

A **scheduled job** (`sjb_...`) fires on a cron schedule and delivers a signed request to a target URL.
It is how an application asks the platform "call me every night at two" without running its own
scheduler, and how a deployment with many instances still gets exactly one firing per tick.

## What a job contains

| Field | Meaning |
|---|---|
| `code`, `name` | Identity. The code is unique. |
| `crons` | One or more cron expressions. See the format below. |
| `timezone` | The time zone the expressions are evaluated in. Defaults to `UTC`. |
| `targetUrl` | Where each firing is delivered. |
| `payload` | A JSON body sent with every firing. |
| `concurrent` | Whether firings may overlap. Off by default. The platform does not block a new firing itself; it sends the flag in every firing so the receiving SDK runner can hold an overlap lock when it is `false`. |
| `tracksCompletion` | Whether the target reports completion back to the platform. Off by default. See below. |
| `timeoutSeconds` | How long to wait for the target to answer. |
| `deliveryMaxAttempts` | Delivery attempts per firing. Default 3. |

### Cron format

Expressions have **six fields, with seconds first**: `second minute hour day-of-month month day-of-week`.

| Expression | Fires |
|---|---|
| `0 0 * * * *` | At the top of every hour. |
| `0 */15 * * * *` | Every 15 minutes. |
| `0 30 2 * * *` | Every day at 02:30. |
| `0 0 9 * * 1-5` | At 09:00 on weekdays. |

A five-field expression is accepted by the create call's shape check but is **not** parsed by the
scheduler and never fires; always write six fields. (Publishing a function with a five-field
schedule is rejected for this reason.)

If the platform was down and several slots were missed, only the **latest** missed slot fires, not a
burst of catch-up runs.

## Firings and instances

Each firing creates an **instance** with its own status and log. The scheduler wakes every 30 seconds
to find due jobs, and a dispatcher wakes every 5 seconds to deliver queued instances in batches of
32 (`FC_SCHEDULED_JOB_POLL_SECONDS`, `FC_SCHEDULED_JOB_DISPATCH_SECONDS`,
`FC_SCHEDULED_JOB_DISPATCH_BATCH`). Locking ensures exactly one instance of the platform fires a given
tick, even when several are running for high availability.

The delivery is a `POST` of a JSON envelope: `jobId`, `jobCode`, `instanceId`, `scheduledFor`,
`firedAt`, `triggerKind` (`CRON` or `MANUAL`), `correlationId`, `payload`, `tracksCompletion`,
`timeoutSeconds` and `concurrent`. It is signed exactly like a webhook (a bearer token plus an HMAC
signature over the body), so you verify it with the same SDK helper; see
[Messaging and delivery](messaging-and-delivery.md#signatures). The target should answer quickly with a
`2xx` (the dispatcher's HTTP timeout is 10 seconds by default, `FC_SCHEDULED_JOB_HTTP_TIMEOUT_SECONDS`)
and do the real work in the background, then report completion if `tracksCompletion` is on. The
TypeScript SDK ships a `ScheduledJobRunner` that does exactly this.

With `tracksCompletion` on, the target acknowledges completion by calling back:

- `POST /api/scheduled-jobs/instances/{instanceId}/complete` with a status (`COMPLETED` or `FAILED`, or
  `SUCCESS` or `FAILURE`) and an optional result;
- `POST /api/scheduled-jobs/instances/{instanceId}/log` to append `DEBUG`, `INFO`, `WARN` or `ERROR`
  log entries that show on the instance.

An instance that never reports completion stays visible as running rather than silently vanishing.

## Operating a job

In the console, **Scheduled Jobs** lets an administrator pause and resume a job, **fire it
manually** (`POST /api/scheduled-jobs/{id}/fire`), archive it, and inspect each instance and its log.
Instances and their logs are kept for 30 days by default; this is the retention of the partitioned
history tables (`FC_STREAM_PARTITION_RETENTION_DAYS_SCHEDULED_JOBS`).

## Declaring jobs from your application

Applications declare their jobs in code and sync them with
`POST /api/applications/{appCode}/scheduled-jobs/sync`, like every other definition. The Laravel
SDK uses an `#[AsScheduledJob]` attribute and the Java SDK's definition sync includes scheduled jobs. A job created by a [function](functions.md) is owned by that function and is
managed by its promotions, not by sync.

To run the scheduler in `fc-server`, set `FC_SCHEDULED_JOB_ENABLED=true`. `fcdev` runs it by default.
