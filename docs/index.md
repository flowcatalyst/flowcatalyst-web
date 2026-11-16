# FlowCatalyst documentation

FlowCatalyst is a multi-tenant event router and webhook delivery platform. Your applications publish
business events into it. FlowCatalyst takes responsibility for everything that should happen next:
it matches each event to the subscriptions that want it, delivers it to the subscriber's endpoint as a
signed webhook, retries failures, rate-limits and orders deliveries, and gives operators one place
to watch and intervene. Around that messaging core it provides the identity your applications share:
an OAuth2/OIDC provider with federated login, roles and permissions, and service accounts.

You publish an event once. FlowCatalyst handles routing, FIFO ordering within a group, retry,
rate limiting, circuit breaking and audit across tenants, so you do not rebuild that machinery in
every consumer.

## What you get

| Capability | In short |
|---|---|
| **Event ingestion** | Applications `POST` events, singly or in batches, against registered **event types** that can carry a JSON schema. |
| **Routing** | **Subscriptions** bind event types to a delivery endpoint. Each match becomes a **dispatch job**. |
| **Delivery** | Dispatch jobs are delivered as HMAC-signed webhooks with retries, backoff and per-pool concurrency and rate limits. |
| **Scheduling** | **Scheduled jobs** fire on cron expressions, with locking, retention and per-run history. |
| **Functions** | Small programs the platform stores, versions and runs for you in a WebAssembly sandbox. |
| **Identity** | An OAuth2/OIDC provider: password, passkey and organisation single sign-on, two-factor authentication, service accounts. |
| **Access control** | Roles built from four-segment permissions, delegable to a client's own administrators. |
| **Administration** | A web console for every resource above, plus audit logs, login attempts and dispatch-job debugging. |

## How it fits together

The platform ships as two binaries. **`fc-server`** is the production server: every subsystem is
switched on or off with environment variables, so you can run one instance with everything enabled
or several instances that each run a subset. **`fcdev`** is the local development monolith: all
subsystems in one process against an embedded PostgreSQL, with no Docker and no queue service
to set up.

<div class="diagram" markdown="0">
<svg viewBox="0 0 795 340" role="img" aria-label="The path of an event: your app, platform API, stream processor, dispatch scheduler, queue, router, delivery, your endpoint. PostgreSQL stores state underneath.">
<defs><marker id="ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" class="d-arrow"/></marker></defs>
<text class="d-h" x="15" y="22">Event path</text>
<rect class="d-box" x="15" y="36" width="150" height="62" rx="8"/>
<text class="d-t" x="90" y="62">Your application</text>
<text class="d-s" x="90" y="80">SDK + local outbox</text>
<rect class="d-accent" x="215" y="36" width="150" height="62" rx="8"/>
<text class="d-t" x="290" y="62">Platform API</text>
<text class="d-s" x="290" y="80">validates, stores events</text>
<rect class="d-accent" x="415" y="36" width="150" height="62" rx="8"/>
<text class="d-t" x="490" y="62">Stream processor</text>
<text class="d-s" x="490" y="80">matches subscriptions</text>
<rect class="d-accent" x="615" y="36" width="150" height="62" rx="8"/>
<text class="d-t" x="690" y="62">Dispatch scheduler</text>
<text class="d-s" x="690" y="80">claims jobs, publishes</text>
<line class="d-line" x1="165" y1="67" x2="213" y2="67" marker-end="url(#ar)"/>
<line class="d-line" x1="365" y1="67" x2="413" y2="67" marker-end="url(#ar)"/>
<line class="d-line" x1="565" y1="67" x2="613" y2="67" marker-end="url(#ar)"/>
<line class="d-line" x1="690" y1="98" x2="690" y2="136" marker-end="url(#ar)"/>
<rect class="d-store" x="615" y="138" width="150" height="62" rx="8"/>
<text class="d-t" x="690" y="164">Queue</text>
<text class="d-s" x="690" y="182">Postgres or SQS FIFO</text>
<rect class="d-accent" x="415" y="138" width="150" height="62" rx="8"/>
<text class="d-t" x="490" y="164">Router</text>
<text class="d-s" x="490" y="182">pool limits and ordering</text>
<rect class="d-accent" x="215" y="138" width="150" height="62" rx="8"/>
<text class="d-t" x="290" y="164">Delivery</text>
<text class="d-s" x="290" y="182">signs, sends, records</text>
<rect class="d-box" x="15" y="138" width="150" height="62" rx="8"/>
<text class="d-t" x="90" y="164">Your endpoint</text>
<text class="d-s" x="90" y="182">gets a signed webhook</text>
<line class="d-line" x1="613" y1="169" x2="567" y2="169" marker-end="url(#ar)"/>
<line class="d-line" x1="413" y1="169" x2="367" y2="169" marker-end="url(#ar)"/>
<line class="d-line" x1="213" y1="169" x2="167" y2="169" marker-end="url(#ar)"/>
<text class="d-s" x="390" y="226">The router calls back into the platform, which makes the delivery and records the outcome.</text>
<text class="d-h" x="15" y="256">State</text>
<rect class="d-store" x="15" y="266" width="560" height="52" rx="8"/>
<text class="d-t" x="295" y="288">PostgreSQL</text>
<text class="d-s" x="295" y="305">events, subscriptions, dispatch jobs, attempts, identity, audit</text>
<rect class="d-store" x="605" y="266" width="160" height="52" rx="8"/>
<text class="d-t" x="685" y="288">Redis (optional)</text>
<text class="d-s" x="685" y="305">leader election for HA</text>
</svg>
</div>

Reading the diagram:

1. Your application writes an event (usually through the SDK's transactional outbox) and the platform
   accepts it through `POST /api/events`.
2. The **stream processor** matches the event against active subscriptions and creates one
   **dispatch job** per match.
3. The **dispatch scheduler** claims pending jobs and publishes a pointer to each onto a queue: the
   built-in PostgreSQL broker (what `fcdev` uses) or SQS FIFO.
4. The **router** consumes the queue and applies the delivery rules of each **dispatch pool**:
   concurrency, rate limit and per-group ordering. It then asks the platform to make the delivery.
5. The platform signs the request, `POST`s it to the subscriber's endpoint, records the attempt, and
   schedules a retry or marks the job complete.

## The subsystems

| Subsystem | What it does | Switch (`fc-server`) |
|---|---|---|
| **Platform API** | Event ingestion, every resource's REST API, the OAuth2/OIDC provider, the embedded web console. | `FC_PLATFORM_ENABLED` (default on) |
| **Stream processor** | Projects events and dispatch jobs for the console, fans events out to subscriptions, manages table partitions. | `FC_STREAM_PROCESSOR_ENABLED` |
| **Dispatch scheduler** | Claims pending dispatch jobs and publishes them to the queue. | `FC_SCHEDULER_ENABLED` |
| **Router** | Consumes the queue, enforces pool limits and ordering, calls the platform to deliver. | `FC_ROUTER_ENABLED` |
| **Outbox processor** | Forwards rows from an outbox table to the platform. | `FC_OUTBOX_ENABLED` |
| **Scheduled jobs** | Fires cron-driven work with locking and instance tracking. | `FC_SCHEDULED_JOB_ENABLED` |
| **Functions runner** | Runs stored WebAssembly and JavaScript functions. | `FC_FUNCTIONS_ENABLED` |
| **MCP server** | A read-only Model Context Protocol server for LLM clients. | `FC_MCP_ENABLED` |

Only the platform API is on by default in `fc-server`. `fcdev` turns the scheduler, stream
processor, scheduled jobs, router and function runner on. See [Configuration](operate/configuration.md)
for every switch.

## Where to go next

- **New here?** Follow the [Quick start](get-started/quick-start.md), then
  [publish your first event](get-started/first-event.md).
- **Learning the model?** Start with [events and subscriptions](concepts/events-and-subscriptions.md)
  and [dispatch jobs, pools and ordering](concepts/dispatch.md).
- **Integrating an application?** See the [SDKs](sdks/index.md).
- **Running it in production?** See [Deployment](operate/deployment.md) and
  [Configuration](operate/configuration.md).
- **Something stuck?** See [Troubleshooting dispatch](operate/troubleshooting-dispatch.md).

## Compatibility

The PostgreSQL schema, the HTTP API contracts and the OpenAPI document are a stable contract:
existing SDK consumers and webhook subscribers keep working unchanged across releases. The
[wire contract](reference/wire-contract.md) page says exactly what is promised.
