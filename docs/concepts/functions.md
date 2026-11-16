# Functions

A **function** is a small program the platform stores, versions and runs for you. You write it in
Go, Rust or TypeScript against a FlowCatalyst function SDK, publish it, and promote a version to
`live`. The platform then wires it up: subscriptions deliver events to it, schedules fire it, and
callers invoke it over HTTP, with no server of yours to run.

Functions run in the **function runner**, a sandbox built on WebAssembly (TypeScript functions run on
a shared JavaScript engine inside the same runner). A function reaches nothing except what it
declares: its config and secret keys, its databases, the hosts it may call, and the event types it may
emit. The runner holds every credential; the function never sees one.

The SDKs and their install notes are on the [Function SDKs](../sdks/functions.md) page.

## Addresses, versions and aliases

| Concept | Meaning |
|---|---|
| **Address** | `{application}.{name}`, for example `billing.invoice-pdf`. The application owns the function; the name is lower-case letters, digits and hyphens. The address never changes. |
| **Version** | One published build, numbered 1, 2, 3 and so on. Versions are immutable. |
| **Alias** | A name that points at a version. `live` is what subscriptions, schedules and ordinary calls reach. Other aliases (`qa`, `canary`) are reachable over HTTP only. |

Publishing a version changes nothing that is running. **Promoting** a version to `live` is the moment it
takes effect, and the moment its subscriptions and schedules are created, updated or removed to match
what that version declares. Promoting an older version back restores its wiring too.

## The local loop

```sh
fcdev fn init --lang go --app billing invoice-pdf   # or --lang rust / --lang ts
cd invoice-pdf && go mod tidy                        # npm install for ts
fcdev fn build                                       # build, then check the declarations
fcdev fn run function.wasm --config GREETING=Hi --watch
curl -H "Authorization: Bearer dev" localhost:8099/fn/local.fn/hello/Aroha
```

- `fcdev fn build` builds with the project's own toolchain and then reads the function's declarations
  exactly as publishing will, so a function that builds here publishes.
- `fcdev fn run` serves one function on the real runner with **no platform**: settings come from
  `--config`, `--secret` and `--db`; emitted events are printed; platform endpoints accept any bearer
  token; `--watch` picks up every rebuild. By default it listens on `127.0.0.1:8099` and serves the
  function at address `local.fn`.

## Publishing and promoting

```sh
fcdev fn deploy billing.invoice-pdf . --create        # build, publish, wait until loaded, promote live
fcdev fn set billing.invoice-pdf --config GREETING=Hi --secret STRIPE_KEY=...
fcdev fn publish billing.invoice-pdf function.wasm    # publish only
fcdev fn promote billing.invoice-pdf 7                # point live at version 7 (--alias for others)
fcdev fn invoke billing.invoice-pdf@qa hello/Aroha    # call through a runner
fcdev fn status billing.invoice-pdf
```

A version must be loaded by a runner before it can be promoted; `deploy` waits for that. Promotion is
refused while a config key, secret or database the version declares has no value. Against a local
`fcdev` these commands sign in by themselves. In CI, pass `--platform`, `--client-id` and
`--client-secret` (or `FC_PLATFORM_URL`, `FC_CLIENT_ID`, `FC_CLIENT_SECRET`) for a service account holding
`platform:function-publisher`, plus `platform:function:function:manage` to create functions.

## Declaring what the function needs

Everything a function needs is declared **in its code**, and the platform reads the declarations from
the built artifact. There is no separate manifest to keep in step. In Go:

```go
var greeting = fn.Config("GREETING")
var orders   = fn.DB("main")

func init() {
	fn.Webhook("POST /events/order-created", onOrderCreated)
	fn.Platform("GET /orders/{id}", getOrder)
	fn.Open("GET /healthz", health)

	fn.Subscribe("shop:orders:order:created", "/events/order-created")
	fn.Schedule("0 */15 * * * *", "/events/order-created")
	fn.HTTPAllow("api.stripe.com")
	fn.Emits("shop:orders:order:invoiced")
}

func main() {}
```

The TypeScript and Rust SDKs declare the same things with the same names. Schedules use the platform's
[six-field cron format](scheduled-jobs.md#cron-format).

### Endpoints and how callers authenticate

Every endpoint names exactly one auth mode; there is no default.

| Declared with | Who calls it | What the runner checks first |
|---|---|---|
| `Webhook` | subscriptions and schedules | the platform's delivery signature |
| `Platform` | people and services holding platform tokens | a valid platform access token; your code then checks the caller's permissions |
| `Open` | anyone | nothing. For health checks and third-party webhooks you verify yourself |

A webhook endpoint accepts `POST` only. Paths use Go's routing patterns: `/orders/{id}`,
`/files/{rest...}`.

`Subscribe(eventType, path)` asks for an event type to be delivered to one of your webhook endpoints;
`Schedule(cron, path)` asks for a cron firing to be. The path must be a literal path that lands on a
webhook endpoint. A subscription without a mode keeps each message group in order and moves on past a
failure (`NEXT_ON_ERROR`) like every other subscription; ask for `IMMEDIATE` if you do not need ordering.

## What a function can reach

| Capability | Notes |
|---|---|
| Config and secrets | Only declared keys. Values are set on the platform per function; secrets are write-only. |
| Databases | `fn.DB("main")` gives a `database/sql` handle in Go, or `query`, `exec` and `transaction` in Rust and TypeScript. The connection string is a platform setting and the pool belongs to the runner. Statements use `?` placeholders; a result is capped at 10,000 rows or 8 MiB; a transaction still open when the call ends is rolled back. |
| Outbound HTTP | Only to hosts declared with `HTTPAllow` (`api.example.com` or `*.example.com`), including on redirects. Responses over 16 MiB are refused. |
| Emitting events | Only types declared with `Emits`, and only your application's own. Every event needs a dedup id, derived from what you are handling so a redelivery emits once. |
| Logging | `fn.Log(ctx)` in Go, `ctx.log_*` in Rust, `fn.log` and `console` in TypeScript. |

Every call has a deadline, and it reaches databases, HTTP and emits too: when the call's time is up,
everything it started stops.

## Answering deliveries

| Your answer | What the platform does |
|---|---|
| any `2xx` | Delivered. |
| `fn.Retry(w, d)`: `429` with `Retry-After` | Tries again after the delay, without spending an attempt. |
| `fn.Reject(w, reason)`: `422` with `FlowCatalyst-Outcome: reject` | Gives up at once, because retrying cannot help. |
| anything else, a crash or a timeout | A failed attempt, retried until the subscription's or schedule's limit. |

## Limits

| Limit | Default | Set per function |
|---|---|---|
| Memory per instance | 64 MB | yes |
| Concurrent calls | 16 | yes |
| Timeout | 30 s | yes, and per endpoint |
| Request body | 1 MiB | yes, and per endpoint |

A function past its concurrency limit answers `429`, and deliveries wait and try again without
spending an attempt. A function that needs more memory than it may have fails only its own call, never
its neighbours'.

## Running the runner

The runner is part of `fc-server`. `FC_FUNCTIONS_ENABLED=true` starts it; a runner-only deployment
needs no database. It authenticates to the platform as a service account holding the
`platform:function-runner` role, learns what to run from the platform, and uses all of its
container's memory except a reserve for itself. In `fcdev` it runs in-process on port 8095 (the private
entry), with a public entry on 8096. The runner's own variables are in
[Configuration](../operate/configuration.md#function-runner).

## Public routes

A function's own endpoints are always reachable through `/fn/{address}[@alias]/{path}`. A **public
route** maps a plain hostname and path prefix straight to a function, so
`https://api.acme.example.com/webhooks/orders` can reach `shop.orders` without the `/fn/...` shape.
The prefix is stripped before the function's own endpoint matching, so the function still declares
`/orders` as usual.

Adding a route is two steps.

1. **Claim the zone.** A claim covers the hostname itself and everything under it. A claim is verified
   by being made; there is no DNS check. Two different owners cannot claim overlapping zones; the same
   owner can.

   ```sh
   curl -X POST https://platform.example.com/api/function-domains \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"zone": "acme.example.com", "clientId": "clt_..."}'   # omit clientId for a platform zone (anchor only)
   ```

   Claiming and releasing a zone needs `platform:function:domain:manage`.

2. **Add the route.** The hostname must be covered by a zone your client has claimed.

   ```sh
   curl -X PUT https://platform.example.com/api/functions/$FUNCTION_ID/routes \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"hostname": "api.acme.example.com", "pathPrefix": "/webhooks", "alias": ""}'
   ```

   `alias` names an existing alias to route to; empty routes to `live`. A `(hostname, pathPrefix)` pair
   belongs to exactly one function at a time. Writing routes needs `platform:function:route:manage`.

For traffic to arrive, point the hostname at the runner pool's public entry (a load balancer or
ingress in front of the runner deployment). The route only decides which function answers once a
request reaches that port; it is not a DNS record.
