# Router tuning

The router is a poller, not a server. It consumes the queue, routes each message to a dispatch pool,
and asks the platform to make the delivery. This page covers the runtime settings that change its
throughput and memory, and the pool-level controls that decide who waits.

## Runtime tuning at start-up

When `fc-server` starts it reads its container limits and adjusts the Go runtime once. It logs a
`runtime tuning` line with what it decided and why, so you can confirm it from the logs.

| Setting | What `fc-server` does | How to override |
|---|---|---|
| `GOMAXPROCS` | Go's container-aware default never goes below 2. When `GOMAXPROCS` is **unset** and the cgroup CPU limit (v2 `cpu.max`, or v1 `cpu.cfs_quota_us` over `cpu.cfs_period_us`) is **at most 1.0 CPU**, it calls `GOMAXPROCS(1)`. A larger limit, no limit, or no cgroup files (for example on macOS) leaves Go's default alone. | Set `GOMAXPROCS` yourself; the automatic step is then skipped. |
| GC target | When the router or the dispatch scheduler is enabled and `GOGC` is unset, the garbage-collection target is raised from Go's default of 100 to **200**: both subsystems allocate heavily and trade memory for throughput well. | `FC_GC_PERCENT`, below. Setting `GOGC` leaves the GC target and `FC_GC_PERCENT` entirely alone. |
| Memory limit | When the GC target was raised or overridden, and `GOMEMLIMIT` is unset, a soft limit of **90% of the cgroup memory limit** is set (v2 `memory.max`, v1 `memory.limit_in_bytes`), so the collector tightens before the container is OOM-killed. No cgroup limit means nothing is set. | Set `GOMEMLIMIT` yourself. |

`FC_GC_PERCENT` is only consulted when `GOGC` is unset:

| Value | Effect |
|---|---|
| a positive integer | That GC target, applied whether or not the router or scheduler runs. |
| `off` | Disables the percentage trigger (`-1`): only the memory limit then drives collection. |
| anything else, including `0` and negatives | Logs a warning and falls back to the default rule. |

A higher target trades memory for throughput. In one measurement a router at 1 CPU used about 714 MB
at a target of 200 against about 522 MB at 100. Size the container's memory for the setting you pick,
and leave the memory limit in place: with a raised target and no limit, a heap spike has nothing to
stop it.

## Pools and who waits

Every message is routed to a **dispatch pool**, and each pool has a concurrency limit and, optionally,
a rate limit (per minute). Three things are worth knowing when throughput looks lower than you expect.

**A pool's rate limit is a silent wait.** A message held by a pool's rate limiter is not failed or
deferred; it waits for a token. On the dashboard such messages can look as if nothing is happening
("draining, but not in flight"). If a queue is slow and the pool has a `rateLimit`, that is the first
suspect.

**Pool names carry the tenant.** A client's pool is routed as `{clientIdentifier}-{poolCode}`, a
platform-level pool as `platform-{poolCode}`, and jobs without a pool go to
`{clientIdentifier}-DEFAULT-POOL`. These per-client default pools are created on demand and removed after
an hour with no traffic (`FC_ROUTER_SYNTH_POOL_IDLE_SECS`, default 3600). Configured pools are never
evicted.

**Reconfiguration is in place.** When the platform's pool or queue configuration changes (the router
re-fetches it every 300 seconds by default, `FC_ROUTER_CONFIG_INTERVAL_SECONDS`), a pool that still
exists is re-capped and re-rate-limited without being rebuilt, and a removed pool or queue drains
rather than aborting.

### When a pool is full

Each pool buffers up to `max(concurrency x 40, 100)` messages. A message that arrives at a full pool is
not failed: the router **defers** it, handing it back to the queue for a computed delay, so the broker
holds it and the pool is not flooded.

The delay is a reservation. The pool measures its completion rate over the last five minutes and books
each deferred message one slot after the previous one, so deferred messages return spaced at the
pool's own pace, in the order they were deferred, each bouncing about once instead of all returning
together as a herd. The queue's consumer keeps polling while any pool it feeds has room, and while its
**deferral budget** lasts; it only pauses when every pool is full and the budget is spent.

| Variable | Default | Effect |
|---|---|---|
| `FC_ROUTER_DEFERRAL_MAX_DELAY_SECONDS` | `3600` | The longest any one deferral asks the broker to hold a message. Caps the reservation. |
| `FC_ROUTER_DEFERRAL_BUDGET` | `15000` | Deferred messages one queue's consumer may have outstanding before it stops polling into full pools. |

The budget must be at least as large as the biggest slow-pool backlog you expect on a queue. SQS FIFO
serves oldest first, so reaching other pools' messages means deferring the whole backlog ahead of
them, and SQS FIFO stops delivering anything from a queue at **20,000** messages in flight, which
deferred messages count toward. A backlog beyond roughly 15,000 on a shared FIFO queue is not workable
from the consumer side: give that job its own queue.

The practical rules:

- **Give a slow or rate-limited consumer its own pool.** A slow pool then blocks only itself.
- **Do not expect a deferred message back early.** An early return would find the pool still full and
  rebook at the back of the schedule. If you raise a pool's concurrency in the middle of a backlog,
  already-deferred messages still return on the old schedule, so the pool idles until they do,
  bounded by the horizon above.
- On the dashboard, the Pools table's **Deferred** column (a lifetime total) is the number to watch when
  one pool's backlog keeps growing while the others are fine.

One slow *message group* monopolising a shared pool's buffer is a different case that this mechanism does
not address: that job belongs in its own pool.

## Delivery connections

The router's outbound delivery connections use HTTP/2 when the target supports it. A connection that dies silently
(a NAT or load-balancer idle drop, or a peer that vanished without closing) would otherwise stall every
delivery on it until each request's own deadline. To bound that, the router sends an HTTP/2 `PING`
after a period of silence and closes the connection if the reply does not come.

| Variable | Default | Effect |
|---|---|---|
| `FC_ROUTER_HTTP2_READ_IDLE_TIMEOUT_SECONDS` | `30` | Seconds with no frame received before the router sends a `PING`. |
| `FC_ROUTER_HTTP2_PING_TIMEOUT_SECONDS` | `15` | Seconds to wait for the reply before closing the connection. Requests on it fail with a retryable error and retry on a new connection. |

Together these bound a half-open connection's stall to about 45 seconds. A healthy connection carrying
a long request is never closed, because the target's HTTP/2 layer answers the `PING`.

## Delivery outcomes at the router

For messages whose outcome the router can see (operator-submitted messages and any producer that points
a message straight at a subscriber), the router turns each response into exactly one queue action:

| Response | Action |
|---|---|
| `2xx` | Acknowledge: delivered. |
| `3xx`, `4xx` | Acknowledge: retrying cannot change the answer. (Redirects are not followed.) |
| `500`, `501` and other `5xx` apart from the three below | Acknowledge after a single attempt: the application ran the request and answered. A warning records it. |
| `502`, `503`, `504`, transport error, timeout, open circuit breaker | **Release** the message **and its whole group** back to the queue: nothing about the message is wrong. |
| `429`, or `2xx` with `{"ack": false}` | Retry in place, honouring `Retry-After`; after a bounded number of in-place attempts the message is released. |

Releasing the whole group, not just the failed head, is what keeps ordering: if the head alone went
back it would return behind its own successors. For the platform's own dispatch jobs the router never
sees a delivery failure at all, because the delivery callback records the outcome itself and answers
`200 {"ack": true}`; their retries and ordering are enforced by the platform
([Dispatch jobs, pools and ordering](../concepts/dispatch.md)).
