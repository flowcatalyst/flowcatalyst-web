# TypeScript SDK

`@flowcatalyst/sdk` is the TypeScript and JavaScript client for the platform. It gives you a typed
client for the control-plane API, definition sync, a transactional outbox, delivery-signature
verification, and a Fastify plugin that handles sign-in and token validation. The API types are
generated from the platform's OpenAPI document, so they track the wire contract exactly.

## Install

```sh
npm install @flowcatalyst/sdk
# or: yarn add @flowcatalyst/sdk   /   bun add @flowcatalyst/sdk
```

The package is ESM. The Fastify plugin has optional peer dependencies (`fastify@^5`,
`@fastify/cookie`, `jose`); install them only if you use it.

## Create a client

A client authenticates with a service account (OAuth `client_credentials`). If you already hold a
user's access token you can pass `accessToken` instead.

```typescript
import { FlowCatalystClient } from "@flowcatalyst/sdk";

const client = new FlowCatalystClient({
  baseUrl: "http://localhost:8080",
  clientId: "your_client_id",
  clientSecret: "your_client_secret",
});

// Every method returns a neverthrow ResultAsync: errors are values, not exceptions.
const result = await client.eventTypes().list();
result.match(
  (eventTypes) => console.log("Event types:", eventTypes.items),
  (error) => console.error("Error:", error.type, error.message),
);

await client.eventTypes().create({
  code: "orders:fulfillment:order:created",
  name: "Order Created",
  description: "Fired when a new order is placed",
});

await client.subscriptions().create({
  code: "notify-warehouse",
  name: "Notify Warehouse",
  eventTypes: [{ eventTypeCode: "orders:fulfillment:order:created" }],
  endpoint: "https://myapp.example.com/webhooks",
});
```

Options include `tokenUrl` (default `{baseUrl}/oauth/token`), `timeout` (30 s), `retryAttempts` (3) and
`retryDelay` (100 ms). Resource accessors cover event types, subscriptions, dispatch pools,
connections, processes, roles, permissions, applications, clients, principals, scheduled jobs, audit
logs and the router. Anything else is reachable through the generated functions, passed through
`client.request()` so it still gets authentication and retries.

For local credentials, run [`fcdev init`](../reference/fcdev.md#fcdev-init): it writes a client id and
secret to your `.env`.

## Syncing definitions

Declare your application's roles, event types, connections, subscriptions, dispatch pools and
principals in code and push them in one call. The platform makes its state match; running it on every
deploy is safe.

```typescript
import { FlowCatalystClient, sync } from "@flowcatalyst/sdk";

const definitions = sync
  .defineApplication("orders")
  .withRoles([{ name: "admin", displayName: "Administrator" }])
  .withEventTypes([
    { code: "orders:fulfillment:shipment:shipped", name: "Shipment Shipped" },
  ])
  .build();

await client.definitions().sync(definitions);
```

The repository's `clients/typescript-sdk/docs/syncing-definitions.md` is the full structure guide:
role naming, the four-part permission format, event-type conventions, subscription modes and
pool sizing.

## The outbox

The outbox writes events to a table in your own database inside your own transaction; a poller
forwards them. See [The outbox pattern](../concepts/outbox.md) for the design and for how to run
the poller. Writing a row with a `pg` pool:

```typescript
import { Pool } from "pg";
import { CreateEventDto, OutboxManager, PgOutboxDriver } from "@flowcatalyst/sdk";

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const outbox = new OutboxManager(new PgOutboxDriver(pool), "clt_your_client_id");

const tx = await pool.connect();
try {
  await tx.query("BEGIN");
  await tx.query("UPDATE orders SET status = 'shipped' WHERE id = $1", [orderId]);
  await outbox.createEvent(
    CreateEventDto.create("orders:fulfillment:order:shipped", { orderId })
      .withSource("order-service")
      .withMessageGroup(orderId),
    tx,
  );
  await tx.query("COMMIT");
} catch (err) {
  await tx.query("ROLLBACK");
  throw err;
} finally {
  tx.release();
}
```

`CreateEventDto`, `CreateDispatchJobDto` and `CreateAuditLogDto` are immutable builders
(`with*()` returns a new instance). Event types and dispatch-job codes must be fully qualified; the SDK
rejects a bare code. Create the table with `fcdev outbox create-table` or the SDK's migration in
`clients/typescript-sdk/migrations/postgresql`.

## Verifying deliveries

```typescript
import { verifyDeliverySignature } from "@flowcatalyst/sdk";

verifyDeliverySignature({
  rawBody,                                           // the exact bytes received
  signature: req.headers["x-flowcatalyst-signature"],
  timestamp: req.headers["x-flowcatalyst-timestamp"],
  secret: process.env.FLOWCATALYST_SIGNING_SECRET!,
}); // throws WebhookSignatureError, with a `code` that says what to fix
```

It checks the HMAC, allows five minutes of age and 60 seconds of clock skew, and compares in constant
time. The body must be the raw bytes, not re-serialised JSON. Details:
[Messaging and delivery](../concepts/messaging-and-delivery.md#signatures).

## Fastify plugin

`@flowcatalyst/sdk/fastify` is a drop-in plugin that handles the browser OIDC flow (redirect plus an
encrypted session cookie) and Bearer-token validation, and exposes the same `request.principal` for
both. Roles come from the access token; permissions are resolved locally from a catalogue you declare.

```typescript
import Fastify from "fastify";
import { flowcatalystAuth, defineRbac } from "@flowcatalyst/sdk/fastify";

const rbac = defineRbac()
  .role("orders:admin").grants("orders:*")
  .role("orders:viewer").grants("orders:read")
  .build();

const app = Fastify();

await app.register(flowcatalystAuth, {
  baseUrl: "https://platform.example.com",
  clientId: process.env.FC_CLIENT_ID!,
  clientSecret: process.env.FC_CLIENT_SECRET!,
  cookie: { secret: process.env.SESSION_SECRET! }, // 32 bytes, base64url
  rbac,
});

// Web route: redirects to /auth/login if there is no session cookie.
app.get("/dashboard", { preHandler: app.fc.requireSession() }, async (req) => ({
  hello: req.principal!.name,
}));

// API route: 401 JSON if there is no valid Bearer token.
app.post("/api/orders", { preHandler: app.fc.requireBearer() }, async (req) => {
  if (!req.principal!.hasPermissionTo(["orders:write"])) throw app.httpErrors.forbidden();
  // ...
});
```

`app.fc.requireAuth()` accepts either, redirecting browsers and rejecting machines. A browser
navigation gets a `302` to sign in; `fetch` and XHR calls get a `401`. Set `portal: true` when the
app is a customer portal so sign-ins enter through the portal identity plane
([Portal users](../concepts/portal-users.md)).

## More

The package also includes an [Effect](https://effect.website) integration (`@flowcatalyst/sdk/effect`),
use-case and unit-of-work helpers (`@flowcatalyst/sdk/usecase`), a scheduled-job runner, and an MCP
server for AI assistants. See the package README in the repository for each.
