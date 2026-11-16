# Wire contract

The HTTP API is a **stable wire contract**. Its consumers (the web console, the SDKs and every webhook
subscriber) are built against the exact shapes the API produces, so changing any of them is a breaking
change and happens only through deliberate, versioned evolution. This page summarises what is promised.
The complete document is `docs/wire-contract.md` in the repository.

## What counts as a breaking change

These look harmless and are **not** allowed:

- renaming a JSON field;
- changing an enum's string value;
- changing a field between nullable and required;
- adding or removing a field from a response, even when the value is null;
- changing the status code of an error case;
- returning the entity from an operation that returns `204 No Content`;
- changing an OpenAPI `operationId` (generated clients use them as method names);
- changing a pagination shape.

## How it is enforced

- **`api/openapi.lock.json`** is the committed baseline, generated from the registered routes.
  `make api-diff` (part of `make ci`) fails on any drift, and `make api-bump` records an intentional
  change.
- **Replay-based contract tests** assert status, headers and body shape for representative requests.
- **Frontend and SDK generation**: the console's TypeScript client is generated from the spec, and
  regenerating it must not produce a diff unless the contract changed on purpose.

## Formats

| Topic | Contract |
|---|---|
| Timestamps | RFC 3339, exactly six fractional digits (`2026-05-24T08:30:00.123456Z`). The one exception is the webhook signature timestamp, below. |
| Enums | `SCREAMING_SNAKE_CASE` strings; parsing is lenient. |
| Errors | `{"error": "<CODE>", "message": "<text>"}`. Status mapping: validation 400, auth 401, forbidden 403, not found 404, conflict 409, rate limit 429, otherwise 500. |
| Pagination | Per endpoint: cursor, offset or a bare list. See the [HTTP API](api.md#conventions). |
| JWT | RS256 with a `kid`. Claims include `sub`, `iat`, `exp`, `iss`, `scope`, `clients`, `roles`, `applications` and `email`. Keys at `/.well-known/jwks.json`. |

## Endpoints outside the spec

The auth and session surface is served by plain handlers and so is not in `api/openapi.lock.json`:
`POST /auth/login`, `POST /auth/refresh`, `GET /auth/check-domain`, `GET /auth/me`, the OIDC single
sign-on routes under `/auth/oidc/`, the password-reset routes under `/auth/password-reset/`,
`GET /api/me`, `GET /api/me/applications`, `/oauth/authorize`, `/oauth/token`, and the discovery and
JWKS documents under `/.well-known/`. The `client_credentials` token response is `no-store`.

## Webhook signatures

A delivery is signed over `timestamp + body` with HMAC-SHA256 and carries:

- `X-FLOWCATALYST-SIGNATURE`: lowercase hex, 64 characters;
- `X-FLOWCATALYST-TIMESTAMP`: ISO 8601 UTC with exactly **three** fractional digits
  (`2026-10-09T15:37:01.123Z`), unlike the six-digit format used elsewhere.

The platform signs the exact bytes it sends and never re-serialises them, so the choice of JSON library
cannot change a signature. A committed test vector pins the expected signature for a fixed input; the
platform's tests and every consumer SDK's verifier assert against it, so all of them change together or
not at all. Header names are case-insensitive on the wire.

### Delivery request

The platform delivers by `POST` to the subscription's endpoint:

- Headers: `Content-Type: application/json`, `X-Dispatch-Job-Id`, `X-Event-Type`,
  `Authorization: Bearer <token>` when the signing service account has one, the signature and
  timestamp headers above, and `X-FlowCatalyst-Client: {clientId}:{clientCode}` whenever the job's client
  resolves (never a half pair).
- Body: the raw payload byte for byte in `dataOnly` mode; otherwise a CloudEvents-style envelope with
  `id`, `type`, `attemptNumber` and, when present, `source`, `subject`, `correlationId`, `messageGroup`,
  `clientId`, `clientCode` and `data`.

Which service account signs, and what an unsigned delivery looks like, is in
[Messaging and delivery](../concepts/messaging-and-delivery.md#signatures).

### Response

The endpoint answers `2xx` with an optional JSON body:

| Field | Type | Meaning |
|---|---|---|
| `ack` | boolean | `false` means "not delivered, retry later". Default `true`. |
| `delaySeconds` | integer | With `ack: false`, the wait before the next try. With `flushGroup`, the suppression window. |
| `flushGroup` | boolean | `true` means delivered, and stop delivering the rest of this message group. Default `false`. |

`flushGroup` acknowledges the group's remaining messages **without delivering them**. It is only safe
for targets that already own the records the messages point at and will re-drive them themselves; a
target whose message body carries the only copy of the payload must never set it. The suppression is
bounded (60 seconds by default, at most 5 minutes) and then self-heals. `ack: false` takes precedence
over `flushGroup`.

## Not part of the contract

HTTP/2 versus HTTP/1.1 defaults, TLS cipher ordering, the `Server` and `Date` headers, gzip behaviour,
SQL query plans, connection-pool sizes and the log format may all change between builds.
