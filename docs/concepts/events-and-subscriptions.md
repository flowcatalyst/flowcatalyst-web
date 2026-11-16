# Events and subscriptions

This page covers the front half of the pipeline: what an event is, how it is described, and how a
subscription decides who receives it.

## Events

An **event** is an immutable fact that your application publishes: an order was placed, a shipment
left the warehouse. You send it to `POST /api/events`, or to `POST /api/events/batch` for a list:

| Field | Required | Meaning |
|---|---|---|
| `eventType` | yes | The event type code, for example `orders:fulfillment:shipment:shipped`. |
| `source` | yes | Where the event came from (a URI or a system name). |
| `data` | yes | The payload, any JSON value. |
| `subject` | no | What the event is about, for context. |
| `correlationId` | no | An id that ties together everything caused by one request. |
| `causationId` | no | The event that caused this one. |
| `messageGroup` | no | The ordering key: events with the same group are delivered in order. |
| `deduplicationId` | no | A key that makes publishing idempotent. See below. |
| `clientId` | no | The tenant the event belongs to. Defaults to the caller's client. |
| `contextData` | no | Key/value pairs for filtering and searching in the console. |

The response carries the stored event, a `dispatchJobCount`, and `isDuplicate`. If you do not send
a `deduplicationId` the platform generates a unique one, so a retried publish is only collapsed when
you supply a stable key. The SDK outboxes do that for you.

The batch endpoint returns one result per submitted item, in the same order as the input, so a
partial failure can be matched back to its item.

## Event types

An **event type** registers a kind of event. Its code has exactly four colon-separated parts:

```
application : subdomain   : aggregate : event
orders      : fulfillment : shipment  : shipped
```

The first part is the owning **application**. The platform rejects any other shape with
`INVALID_CODE_FORMAT` when you register a type. An event type can carry a JSON Schema and has
versions: `POST /api/event-types/{id}/versions` adds a schema version. Applications normally register
their event types at boot through the SDK's definition sync (see
[Applications and tenants](applications-and-tenants.md#declaring-what-your-application-owns)) rather
than by hand.

Event types matter beyond documentation. They are what a subscription binds to, and what the console
uses to filter events and dispatch jobs by application, subdomain and aggregate.

## Subscriptions

A **subscription** says: when an event of these types arrives, deliver it to this endpoint. Creating
one requires a `code`, a `name` and an `endpoint` (an `http` or `https` URL).

```json
{
  "code": "notify-warehouse",
  "name": "Notify warehouse",
  "endpoint": "https://warehouse.example.com/hooks/fc",
  "eventTypes": [{ "eventTypeCode": "orders:fulfillment:shipment:*" }]
}
```

### Matching

Each entry in `eventTypes` is a code or a pattern. A pattern matches segment by segment, and `*`
stands for exactly one segment, so `orders:fulfillment:shipment:*` matches every event of that
aggregate. The number of segments must agree.

A subscription can be tied to one **client** (tenant) with `clientId`. A client-scoped subscription
only receives events that carry the same client. A subscription without a client receives matching
events from every client.

Matching happens in the stream processor, which keeps a cache of the active subscriptions and
refreshes it every 5 seconds. A subscription you have just created or resumed can therefore take up to
five seconds to start matching.

### Delivery settings

| Setting | Meaning | Default when created through the API |
|---|---|---|
| `mode` | Ordering behaviour per message group: `NEXT_ON_ERROR`, `BLOCK_ON_ERROR` or `IMMEDIATE`. See [Dispatch jobs, pools and ordering](dispatch.md). | `NEXT_ON_ERROR` |
| `maxRetries` | Delivery attempts before the job is marked `FAILED`. | 3 |
| `timeoutSeconds` | How long the platform waits for your endpoint to answer. | 30 |
| `dataOnly` | `true` sends the event's `data` as the raw request body; `false` sends a CloudEvents-style envelope. | `true` |
| `dispatchPoolId` | The [dispatch pool](dispatch.md#dispatch-pools) whose limits apply. | none: the client's default pool |
| `queue` | `DEFAULT` or `HIGH_PRIORITY`: which of the client's two dispatch queues jobs are published to. | `DEFAULT` |
| `connectionId` | The [connection](#connections) the delivery belongs to. | none |
| `serviceAccountId` | A service account to sign deliveries with. | none |

The request schema has further optional fields (`description`, `customConfig`, `delaySeconds`,
`maxAgeSeconds`); the [HTTP API](../reference/api.md) reference points you at the full schema. A
subscription can be paused and resumed with `POST /api/subscriptions/{id}/pause` and `/resume`.

### Connections

A **connection** groups the delivery credentials for one destination. It names a service account
whose webhook credentials (a bearer token and an HMAC signing secret) the platform uses to sign
deliveries to every subscription that uses the connection. A connection needs a `code`, a `name` and a
`serviceAccountId`. It may belong to one application (`applicationCode`) or be shared across
applications, and it can be paused and re-activated. Using a connection means you rotate a credential
in one place. [Messaging and delivery](messaging-and-delivery.md#signatures) explains how signing works.

## From event to dispatch job

When the stream processor claims a new event it finds every matching active subscription and creates
one **dispatch job** for each. One event with three matching subscriptions therefore produces three
independent jobs, each with its own status, attempts and retries. What happens to a job next is the
subject of [Dispatch jobs, pools and ordering](dispatch.md).
