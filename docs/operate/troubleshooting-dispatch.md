# Troubleshooting dispatch

"I published an event and nothing arrived" or "a job has been stuck for an hour" has a short list of
causes. This page walks the pipeline from the first hop to the last, with what to look at in the
console, the API and the metrics. For the model behind it, read
[Dispatch jobs, pools and ordering](../concepts/dispatch.md) first.

## Start in the Dispatch Jobs page

In the console, **Dispatch Jobs** lists jobs with filters for client, application, subdomain,
aggregate, code, status, message group and a created-time range. Open a job to see its target, its
status and **every attempt** with the response or error. The API equivalent is
`GET /api/dispatch-jobs` (with `status`, `code`, `subscriptionId`, `messageGroup`, `since`, `until` and
`size`), and `GET /api/dispatch-jobs/{id}` for one job with its attempts.

Most diagnoses come from combining the job's **status** with its **last error**:

| Status and symptom | Read this section |
|---|---|
| There is **no job** for the event | [No dispatch job was created](#no-dispatch-job-was-created) |
| `PENDING` for longer than a retry backoff | [Stuck in PENDING](#stuck-in-pending) |
| `QUEUED` for a long time | [Stuck in QUEUED](#stuck-in-queued) |
| `PROCESSING` for a long time | [Stuck in PROCESSING](#stuck-in-processing) |
| `FAILED` | [Failed jobs](#failed-jobs) |
| Messages for one group are not moving | [A blocked message group](#a-blocked-message-group) |

## No dispatch job was created

The event exists (see **Events**) but no job followed. In order:

1. **Is the stream processor running?** It matches events to subscriptions. In `fc-server` it needs
   `FC_STREAM_PROCESSOR_ENABLED=true` (and `FC_STREAM_FAN_OUT_ENABLED`, on by default). Check
   `GET /router/monitoring/stream-health` or the `/ready` output on the metrics port.
2. **Does a subscription match?** The subscription must be `ACTIVE` (not paused), its event-type
   binding must match the event's code (a `*` stands for exactly one segment, and the segment counts must
   agree), and, if the subscription is scoped to a client, the event must carry that client.
3. **Did you publish too soon?** The stream processor refreshes its subscription cache every five
   seconds. An event published in the same moment a subscription was created or resumed can be processed
   before the subscription is visible, and is never delivered to it. Re-publish.
4. **Is it a duplicate?** A publish with a `deduplicationId` that was already used returns
   `isDuplicate: true` and creates nothing new.
5. In `fc-server`, is the **instance leader**? With `FC_STANDBY_ENABLED`, only the elected leader runs
   the stream processor. `GET /router/monitoring/standby-status` shows `is_leader`.

## Stuck in PENDING

A job is `PENDING` when it is waiting for the dispatch scheduler to claim it, **or** when it is waiting
out a retry backoff (5, 15, 30, 60 and 120 seconds between attempts). A job with a growing attempt count
and a recent error is simply retrying: read its last error. If it has *no* attempts:

- **The scheduler is not running.** `fc-server` needs `FC_SCHEDULER_ENABLED=true`. Watch
  `fc_scheduler_pending_backlog_jobs` and `fc_scheduler_pending_oldest_age_seconds` on the metrics port:
  a backlog that only grows means jobs are not being claimed.
- **The scheduler refused to start** because `FLOWCATALYST_APP_KEY` is not set. Its dispatch-auth secret
  is derived from that key. The start-up log says so.
- **The group is held.** For a `BLOCK_ON_ERROR` subscription, a job is not claimed while an earlier job in
  its message group is `FAILED` or backing off. See
  [A blocked message group](#a-blocked-message-group). `fc_scheduler_held_groups` counts them.
- **The subscription is paused.** `fc_scheduler_paused_subscriptions` counts them.
- **It is in a retry backoff** (above).

## Stuck in QUEUED

`QUEUED` means the job was published to the queue and the router has not delivered it yet. The platform
reverts a job that has been `QUEUED` for 15 minutes back to `PENDING` and publishes it again, so a lost
queue message heals itself; duplicates that creates are dropped by the router or skipped by the
delivery callback.

If jobs sit in `QUEUED` for less than that, look at the router:

- **The router is not running, or has no configuration.** It needs `FC_ROUTER_ENABLED=true` and a
  `FLOWCATALYST_CONFIG_URL` plus credentials; with no URL it starts with **no queues and no pools**
  and consumes nothing. See [Deployment](deployment.md#one-instance-everything-on).
- **The router cannot reach the platform.** Check the circuit breaker for the
  `/api/dispatch/process` target at `GET /router/monitoring/circuit-breakers`. An `OPEN` breaker
  releases messages back to the queue without attempting them. Reset it with
  `POST /router/monitoring/circuit-breakers/{name}/reset` once the cause is fixed (the name is the
  target URL, so URL-encode it).
- **The pool is full or rate-limited.** `GET /router/monitoring/pool-stats` shows `queueSize`,
  `maxQueueCapacity`, `activeWorkers`, `totalRateLimited` and `totalDeferred` per pool. A full pool
  defers messages back to the queue on a schedule; a pool with a `rateLimit` makes messages wait for a
  token, and that wait does not show up as in-flight work. If the pool's `rateLimit` is lower than
  the arrival rate, this is the whole answer. See [Router tuning](router-tuning.md).
- **A slow consumer is sharing a pool.** Give it its own dispatch pool.
- **The queue is SQS and the message is parked** behind the broker's visibility or in-flight limit
  (SQS FIFO stops delivering at 20,000 messages in flight).

## Stuck in PROCESSING

`PROCESSING` means a delivery attempt is in flight. A healthy attempt ends within the subscription's
`timeoutSeconds` (30 by default). A job stuck far beyond that usually means the platform process
died mid-delivery. The platform keeps a claim lease on each processing job; a copy that finds the lease
expired takes the claim over and delivers, and a job `PROCESSING` for 75 minutes is reverted to `PENDING`
by recovery. Because that is **at-least-once**, your endpoint may see the same delivery twice after
such a crash: deduplicate on `X-Dispatch-Job-Id`.

## Failed jobs

`FAILED` jobs are the ones that need a person. Open the job and read the attempts.

| Last error | Meaning and fix |
|---|---|
| `HTTP 401` or `HTTP 403` | Your endpoint refused the credentials. The job failed on the **first** attempt, without retrying, because retrying sends the same credentials. Fix the endpoint's check or rotate the service account's token and secret, then requeue. |
| `HTTP 5xx`, timeout, `Connection error` | Your endpoint failed or was down for the whole retry budget (`maxRetries`, 3 by default). Fix it, then requeue. |
| `subscriber rejected the delivery` | Your endpoint answered `422` with `FlowCatalyst-Outcome: reject`: it said retrying cannot help. |
| `(delivered unsigned: ...)` appended to the error | The delivery went out without a signature because the service account that should sign it is inactive or has no webhook credentials. Your endpoint probably rejected it for that. Fix the credentials; see [Messaging and delivery](../concepts/messaging-and-delivery.md#who-signs). |
| `INVALID_ENDPOINT` or `INVALID_TARGET_URL` | The delivery guard refused the target address. See the [outbound delivery guard](configuration.md#outbound-delivery-guard). |

### Requeue

**Requeue** resets a job, from **any** status, to `PENDING` with a full retry budget: it clears the
scheduled time, the attempt count, the completion stamps and the last error, so the scheduler picks it up
immediately. In the console, select jobs in the list (or open one) and choose **Requeue**. Through the
API:

```sh
curl -X POST http://localhost:8080/api/dispatch-jobs/requeue \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"ids": ["6GJ2KW8PJTMP0"]}'
# {"requeued": 1}
```

`requeued` can be lower than the number of ids you sent: the call is scoped to the caller's tenants, so
you cannot reset another client's jobs. Requeueing a large backlog at once is safe; requeue storms are
deduplicated when the router sees the messages.

Two other operator actions apply only to `FAILED` jobs: **Cancel** (`POST /api/dispatch-jobs/{id}/cancel`)
moves it to `CANCELLED`, and **Complete** (`POST /api/dispatch-jobs/{id}/complete`) moves it to
`COMPLETED`, for work you handled by hand. Both need the same permission as viewing jobs.

### Raw views

Administrators with the view-raw permission can open raw dispatch jobs and raw events
(**Platform**, **Debug**), which show the stored rows without the console's projections. They are useful
when a job appears in one list and not in the other, because the console lists are built by the stream
processor's projections and can lag.

## A blocked message group

A `BLOCK_ON_ERROR` subscription stops a message group at a terminal failure, and the group stays stopped
until a person resolves the failed job. The symptom is that *later* jobs for one group (an order id, a
customer id) pile up as `PENDING` while other groups are fine.

1. Filter **Dispatch Jobs** by the message group and sort by created time.
2. The earliest non-completed job is the head. If it is `FAILED`, read its error. If it is `PENDING`
   with a growing attempt count, it is backing off and still owns its place at the front.
3. Resolve it: fix the endpoint and **requeue** the head, or **complete** it if the work was done, or
   **cancel** it to skip it. The next scheduler claim releases the rest of the group.

Watch `fc_scheduler_held_groups` and `fc_scheduler_jobs_skipped_held_total` to see held groups in
aggregate. The router's `GET /router/monitoring/blocked-groups` lists *every live message group* across
all pools, not only blocked ones, which is useful to see which groups are active but is not a list of
failures.

For the **outbox** (events not leaving your application's database at all), the outbox processor's
admin API (`FC_OUTBOX_ADMIN_PORT`) lists blocked groups and can unblock or skip a poison row. See
[The outbox pattern](../concepts/outbox.md).

## When it is not the pipeline

- **Login or token problems** show up in **Login Attempts** and the audit log, not in dispatch.
- **A function** that returns the wrong thing shows its response on the job's attempts. Run it with
  `fcdev fn run` to reproduce it without the platform ([Functions](../concepts/functions.md)).
- **Everything is slow**: check [Router tuning](router-tuning.md) for CPU and memory settings, and the
  database. The dispatch scheduler's claim query has its own connection pool so API traffic does not
  starve it.
