# Messaging and delivery

The messaging core moves a business event from a producer's database commit to a consumer's webhook
endpoint with **at-least-once delivery**, **ordering within a group**, and operator visibility at
every step. This page is what your endpoint can rely on, and what it must do in return.

## The guarantees

- **At least once.** A delivery that was not acknowledged is retried, and a process that dies
  mid-delivery can cause a repeat. Your handler must be idempotent. The `X-Dispatch-Job-Id` request
  header is a stable key for one delivery.
- **Ordered within a message group** when the subscription is in an ordered mode. See
  [Dispatch jobs, pools and ordering](dispatch.md#ordering).
- **Never silently dropped.** A job that cannot be delivered ends in `FAILED`, where an operator can
  see it, requeue it, cancel it or mark it complete.
- **Bounded.** Dispatch pools cap concurrency and rate per consumer, so a flood for one endpoint
  does not starve the others.

## What your endpoint receives

The platform makes an HTTP `POST` to the subscription's `endpoint`.

**Headers**

| Header | Value |
|---|---|
| `Content-Type` | `application/json` |
| `X-Dispatch-Job-Id` | The dispatch job id. Stable across retries of the same delivery. |
| `X-Event-Type` | The event type code. |
| `Authorization` | `Bearer <token>`, when the signing service account has a webhook auth token. |
| `X-FlowCatalyst-Signature` | Lowercase hex HMAC-SHA256 signature. Present when the delivery is signed. |
| `X-FlowCatalyst-Timestamp` | The signed time, ISO 8601 UTC with milliseconds, for example `2026-10-09T15:37:01.123Z`. |
| `X-FlowCatalyst-Client` | `{clientId}:{clientCode}`, naming the tenant a multi-tenant endpoint is receiving for. Sent whenever the job's client resolves; never half a pair. |

**Body.** With `dataOnly` on (the default when you create a subscription through the API) the body is
the event's `data`, byte for byte. With `dataOnly` off it is a CloudEvents-style envelope: `id`,
`type` and `attemptNumber`, plus `source`, `subject`, `correlationId`, `messageGroup`, `clientId`,
`clientCode` and `data` when present.

## Signatures

Every delivery can be verified, which proves it came from your FlowCatalyst platform and that the
body was not altered.

The signature is `hex( HMAC-SHA256( secret, timestamp + body ) )`, where `timestamp` is the exact
`X-FlowCatalyst-Timestamp` header value and `body` is the **raw request bytes**. Verify before you
parse: if you re-serialise the JSON, the bytes change and the signature fails. The platform signs the
bytes it sends and never re-serialises them.

The SDKs ship a verifier that also rejects stale or future timestamps (the TypeScript and Java
verifiers allow five minutes of age and 60 seconds into the future) and compares in constant time:

```typescript
import { verifyDeliverySignature } from "@flowcatalyst/sdk";

verifyDeliverySignature({
  rawBody,                                           // the exact bytes received
  signature: req.headers["x-flowcatalyst-signature"],
  timestamp: req.headers["x-flowcatalyst-timestamp"],
  secret: process.env.FLOWCATALYST_SIGNING_SECRET!,
}); // throws WebhookSignatureError on any failure
```

The [Laravel](../sdks/laravel.md#webhook-validation) and [Java](../sdks/java.md#webhook-verification)
SDKs have equivalents, and a fixed test vector in the repository pins the expected signature for a
given input so every implementation agrees.

### Who signs

The signing secret and bearer token belong to a **service account**. For each delivery the platform
picks the first of these that names an account, with no fall-through past it:

1. the subscription's own `serviceAccountId`;
2. the subscription's **connection's** service account (the normal case);
3. the owning application's oldest active service account.

If the account named is inactive or has no webhook credentials, the delivery goes out **unsigned,
with a recorded reason** rather than being silently signed by a different account. The reason is
logged and appended to a failed attempt's error message as `(delivered unsigned: ...)`. Rotate the
credentials from the service account page in the console; new values are shown once.

## Answering a delivery

Your response tells the platform what to do:

| Your response | Effect |
|---|---|
| any `2xx` | Delivered. The job is `COMPLETED`. |
| `2xx` with a JSON body `{"ack": false}` | Accepted but not done: try again later, without spending an attempt. Add `"delaySeconds": N` to set the wait (30 seconds if omitted). |
| `429`, optionally with `Retry-After` | Back-pressure: try again later, without spending an attempt. The wait is `Retry-After` seconds, or 30 seconds without it. |
| `401` or `403` | Terminal failure at once: the same credentials would be refused on every retry. Fix the credential, then requeue. |
| `422` with header `FlowCatalyst-Outcome: reject` | Terminal failure at once: you are saying retrying cannot help. |
| anything else, a timeout or a connection error | A failed attempt. Retried with backoff (5, 15, 30, 60, then 120 seconds) until `maxRetries`, then `FAILED`. |

A body that is empty or not JSON on a `2xx` simply means success. Respond promptly: the request
times out after the subscription's `timeoutSeconds` (30 by default). For long work, accept the
delivery, return `200`, and do the work afterwards, or use `ack: false` to ask to be asked again.

The mediation response has one more field, `flushGroup`, that tells the router to stop delivering the
rest of a message group and acknowledge it without delivering. It is only safe for targets that
already own the records the messages point at; read the [wire contract](../reference/wire-contract.md)
before you use it.

## Retries, expiry and what operators see

Retries are scheduled by the platform, not by the queue, so one component owns every re-dispatch.
After the retry budget is spent the job is `FAILED` and stays visible. The admin console lists dispatch
jobs and events with filters (application, event type, status, client, message group, time range),
shows every attempt, and offers single and bulk **requeue**. Users who hold the "view raw" permission
can also inspect raw stored events and jobs for debugging. See
[Troubleshooting dispatch](../operate/troubleshooting-dispatch.md).

## Where delivery is guarded

A subscription endpoint, scheduled-job target or direct dispatch-job `targetUrl` is customer input
that the platform `POST`s to from inside your network. In production the platform refuses
destinations that could expose the cluster (cloud metadata addresses, link-local, loopback, and by
default private ranges), both when you save the endpoint and again at connection time after DNS
resolution. See [Configuration](../operate/configuration.md#outbound-delivery-guard) for the switches
that allow a specific private target.
