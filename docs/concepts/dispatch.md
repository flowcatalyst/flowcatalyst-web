# Dispatch jobs, pools and ordering

A **dispatch job** is one pending delivery: this event, to that subscription's endpoint. It is the
unit that gets queued, delivered, retried and shown to operators. This page explains the job's life,
how dispatch pools limit delivery, and how ordering works.

## The life of a dispatch job

| Status | Meaning |
|---|---|
| `PENDING` | Created and waiting for the dispatch scheduler to claim it. A job waiting out a retry backoff is also `PENDING`. |
| `QUEUED` | Published to the queue and waiting for the router. |
| `PROCESSING` | The platform is making the delivery. |
| `COMPLETED` | Your endpoint answered with a success. |
| `FAILED` | The retry budget is spent, or your endpoint made clear that retrying cannot help. |
| `CANCELLED` | An operator cancelled a failed job. |
| `EXPIRED` | A terminal status that the console and the projections recognise. |

What happens on a delivery attempt:

| Your endpoint answers | Result |
|---|---|
| any `2xx` | The job is `COMPLETED`. |
| `2xx` with `{"ack": false}`, or `429` | A deliberate "not now": the job is rescheduled **without spending an attempt**. |
| `401` or `403` | `FAILED` at once. Retrying sends the same credentials, so it cannot help. |
| a response that says to reject (`422` with `FlowCatalyst-Outcome: reject`, as functions send) | `FAILED` at once. |
| anything else (timeout, connection error, 3xx, 4xx other than the above, 5xx) | A failed attempt. The job returns to `PENDING` with a backoff of 5, 15, 30, 60, then 120 seconds, until `maxRetries` is spent, then `FAILED`. |

Every attempt is recorded with its outcome and visible on the job in the console. Retries are driven
by the dispatch scheduler, not by the queue, so exactly one component ever re-dispatches a job.
Delivery is **at least once**: if the platform process dies mid-delivery your endpoint may see the same
message again, so make handlers idempotent (the `X-Dispatch-Job-Id` header is a stable key).

An operator can act on jobs in the console or through the API; see
[Troubleshooting dispatch](../operate/troubleshooting-dispatch.md):

- **Requeue** resets a job from any status to `PENDING` with a full retry budget.
- **Cancel** moves a `FAILED` job to `CANCELLED`.
- **Complete** moves a `FAILED` job to `COMPLETED`, for work that was handled out of band.

Jobs that come from events carry the event, subscription and message group. An application can also
create **direct dispatch jobs**, with their own target URL and no subscription, through the SDK
outbox's dispatch-job support.

## Dispatch pools

A **dispatch pool** is a delivery budget. It sets how many deliveries may run at once and how fast
they may start, so one slow or flooded consumer cannot starve the rest.

| Setting | Meaning |
|---|---|
| `code` | Lowercase letters, digits and hyphens. |
| `concurrency` | Most deliveries in flight at once. Default 10 when you create a pool. |
| `rateLimit` | Most deliveries per minute. Leave unset for no limit. |

A subscription names its pool with `dispatchPoolId`. Pools can be suspended, re-activated and
archived. A pool belongs to a client or is platform-level.

Jobs that name no pool go to the owning client's **default pool**, and jobs with no client go to
the platform's. The router keys pools by a composed code, `{clientIdentifier}-{poolCode}` for a
client pool, `platform-{poolCode}` for a platform-level one, `{clientIdentifier}-DEFAULT-POOL` for a
client's default. Per-client default pools are created on demand. `platform` is therefore a reserved
client identifier.

Each pool also has a bounded buffer in the router (`max(concurrency x 40, 100)` messages). When it is
full, the router hands further messages back to the queue with a computed delay, which the
router-tuning page describes in [Router tuning](../operate/router-tuning.md#when-a-pool-is-full).

One rule of thumb: **give a consumer that is slow or rate-limited its own pool.** A pool serves one
queue's traffic for many subscriptions, and a slow message group inside a shared pool can still
occupy the shared buffer.

## Ordering

Ordering is defined **per message group**. Events carry an optional `messageGroup` (an order id, a
customer id, whatever must stay in sequence); the group travels onto each dispatch job. Within one
group, an ordered subscription delivers one job at a time, in creation order. Different groups
proceed in parallel. A job with no message group is not ordered against anything.

A subscription's `mode` decides what a failure does to the rest of its group:

| Mode | When a job in the group fails terminally |
|---|---|
| `NEXT_ON_ERROR` (default) | The group moves on to the next job. |
| `BLOCK_ON_ERROR` | The group **stops**. Later jobs are held back until the failed one is resolved. |
| `IMMEDIATE` | No ordering at all: jobs are delivered concurrently. |

Choose `BLOCK_ON_ERROR` when later messages are meaningless without earlier ones (an "item added"
event for an order whose "order created" never arrived). The held jobs stay safe as dispatch-job
rows in the platform store, which is the system of record; the queue copy is only a delivery attempt.

How a group is held, precisely: while an earlier job in the same group is `FAILED`, or is `PENDING`
with a future retry time (it is backing off and still owns its place at the front), the platform
refuses to deliver later `BLOCK_ON_ERROR` jobs in that group. Jobs that are `QUEUED` or `PROCESSING`
do not hold a group; that is the normal flow. To release a held group, resolve the failed job:
requeue it, mark it complete, or cancel it.

Ordering needs a FIFO queue. On SQS the queues are FIFO and the job's message group is the SQS message group id (a job with no
group uses its own id, which imposes no ordering); the built-in PostgreSQL broker makes only the earliest eligible message of each group claimable.
A router with leader election enabled runs its pools only on the elected leader, because per-group
buffers live in one process.

Ordering is one reason to be deliberate about what you put in a message group. A group is a
serial lane: one job at a time. Use fine-grained groups (one per order, not one per tenant).
