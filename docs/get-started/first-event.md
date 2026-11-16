# Your first event

In this walkthrough you register an event type, subscribe a local endpoint to it, publish an event
and watch it arrive as a webhook. You need `fcdev` running (see the [Quick start](quick-start.md))
and `curl`. Everything here is also available in the web console; the API is shown because it is
exact and repeatable.

## 1. Sign in from the command line

For local experiments you can sign in as the development administrator and keep the session cookie in a
file. `curl` then sends it with every request.

```sh
curl -s -c cookies.txt -X POST http://localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@flowcatalyst.local","password":"DevPassword123!"}'
```

The response confirms who you are (`"roles":["platform:super-admin"]`). Applications and scripts do not
use a cookie. They use a service account and an OAuth `client_credentials` token; the
[SDKs](../sdks/index.md) do that for you.

## 2. Start a webhook receiver

Any HTTP server that answers `200` will do. This script prints whatever it receives (save it as
`receiver.py` and run `python3 receiver.py`):

```python
import http.server

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        print(self.path, dict(self.headers), body.decode(), flush=True)
        self.send_response(200)
        self.end_headers()

http.server.HTTPServer(("127.0.0.1", 9000), Handler).serve_forever()
```

`fcdev` allows delivery to loopback and private addresses. A production `fc-server` refuses them
unless you opt in; see [Configuration](../operate/configuration.md#outbound-delivery-guard).

## 3. Register an event type

An event type code has four parts, `application:subdomain:aggregate:event`. The platform rejects
anything else with `INVALID_CODE_FORMAT`.

```sh
curl -s -b cookies.txt -X POST http://localhost:8080/api/event-types \
  -H 'Content-Type: application/json' \
  -d '{"code":"demo:orders:order:created","name":"Order created"}'
```

## 4. Subscribe your endpoint

A subscription binds one or more event types to a delivery endpoint:

```sh
curl -s -b cookies.txt -X POST http://localhost:8080/api/subscriptions \
  -H 'Content-Type: application/json' \
  -d '{
        "code": "demo-order-hook",
        "name": "Order hook",
        "endpoint": "http://127.0.0.1:9000/hook",
        "eventTypes": [{"eventTypeCode": "demo:orders:order:created"}]
      }'
```

Only `code`, `name` and `endpoint` are required. The values you did not set take these defaults:
ordered delivery per message group that moves on past a failure (`NEXT_ON_ERROR`), 30 second
timeout, 3 retries, and delivery of the event's data as the raw request body (`dataOnly`).

> **Wait a few seconds before publishing.** The stream processor caches the active subscriptions
> and refreshes them every 5 seconds (`FC_STREAM_FAN_OUT_SUBS_REFRESH_SECS`). An event published in
> the same instant a subscription is created can be processed before the subscription is visible, and
> is then not delivered to it.

## 5. Publish an event

```sh
curl -s -b cookies.txt -X POST http://localhost:8080/api/events \
  -H 'Content-Type: application/json' \
  -d '{
        "eventType": "demo:orders:order:created",
        "source": "quickstart",
        "data": {"orderId": "ORD-1"}
      }'
```

`eventType`, `source` and `data` are required. Optional fields include `subject`,
`correlationId`, `causationId`, `deduplicationId` and `messageGroup` (the key that orders events
relative to each other; see [Dispatch jobs, pools and ordering](../concepts/dispatch.md)).

The response returns the stored event straight away. Delivery is asynchronous and takes a few seconds
on a development machine while the event passes through the pipeline.

## 6. See the delivery

Your receiver prints the webhook. With the defaults above it receives the `data` object as the
body, with the identifying headers `X-Dispatch-Job-Id` and `X-Event-Type`:

```
/hook {... 'X-Dispatch-Job-Id': '...', 'X-Event-Type': 'demo:orders:order:created' ...} {"orderId": "ORD-1"}
```

The deliveries in this walkthrough are not signed, because the subscription has no
connection and service account to sign with. To receive HMAC-signed requests, give the subscription a
connection that names a service account that has webhook credentials; see
[Messaging and delivery](../concepts/messaging-and-delivery.md#signatures).

In the console, open **Dispatch Jobs** and find the job: its status goes `PENDING`, `QUEUED`,
`PROCESSING`, `COMPLETED`, and each attempt is recorded. The same list is available from the API at
`GET /api/dispatch-jobs`.

## Make the receiver fail

Stop the receiver and publish another event. The first attempt fails with a connection error, and the
platform schedules a retry after a backoff of 5, 15, 30, 60 and then 120 seconds, up to the
subscription's `maxRetries`. Between attempts the job sits in `PENDING` with its attempt count and last
error visible. When the budget is spent the job becomes `FAILED`. Start the receiver again, select
the job in the console and **requeue** it: it returns to `PENDING` with a fresh retry budget and is
delivered. [Troubleshooting dispatch](../operate/troubleshooting-dispatch.md) covers the operator side
in depth.

## Next

- Read how the model fits together in [Events and subscriptions](../concepts/events-and-subscriptions.md).
- Publish from a real application with an [SDK](../sdks/index.md), using the transactional outbox.
