# Java SDK

The Java SDK is a plain-Java client for the platform: Java 25 or later, a blocking API (scale it with
virtual threads), and Jackson as the only runtime dependency. It covers the control-plane resources,
the transactional outbox, definition sync and delivery-signature verification, mirroring the
TypeScript SDK's surface.

## Install

The Maven coordinates are:

```xml
<dependency>
  <groupId>io.flowcatalyst</groupId>
  <artifactId>flowcatalyst-sdk</artifactId>
  <version>0.0.11</version>
</dependency>
```

The SDK is a standalone Maven module (no parent POM, no dependency on any other FlowCatalyst module),
so `mvn test` works in its directory. To build and test it from a checkout of the repository:

```sh
make build-java-sdk        # regenerates the models from the vendored OpenAPI document, then verifies
```

The generated model classes come from `clients/java-sdk/openapi/openapi.json`, so any drift from the
platform's API surfaces as a compile error. Where the artifact is published is not stated in the
repository: check the [releases page](../releases.md) before depending on a version.

## Create a client

```java
var client = FlowCatalystClient.builder()
        .baseUrl("https://platform.example.com")
        .clientCredentials("oac_your_client_id", "your_client_secret")
        .build();

var eventTypes = client.eventTypes().list(null);
```

Two authentication modes:

- **Client credentials** (a service account): `.clientCredentials(id, secret)`. Tokens are cached with
  a 60-second expiry buffer, refreshed single-flight, and refreshed once more transparently on a `401`.
- **User token**: `.accessToken(String)` or `.accessToken(Supplier<String>)`. The host application owns
  refresh and `401`s are surfaced, not retried.

Transient statuses (408, 429, 502, 503, 504) retry with exponential backoff, three attempts by default.
Failures are one exception type, `FlowCatalystException`, carrying a sealed `SdkError` you can handle
with a pattern-matching `switch`:

```java
try {
    client.eventTypes().get(id);
} catch (FlowCatalystException e) {
    switch (e.error()) {
        case SdkError.NotFound nf -> handleMissing();
        case SdkError.RateLimited rl -> backOff(rl.retryAfter());
        case SdkError.Validation v -> log(v.errors());
        default -> throw e;
    }
}
```

## Declaring definitions

Declare event types, roles, connections, subscriptions and the rest in code, then sync them. The
platform makes its state match; running the sync on every deploy is safe.

```java
var set = Definitions.DefinitionSet.define("orders")
        .withEventTypes(List.of(
                Definitions.EventType.of("orders:sales:order:placed", "Order Placed")))
        .withRoles(List.of(Definitions.Role.of("admin")
                .withPermissions(List.of(Definitions.Permission.of("admin", "*", "*")))));

client.definitions().sync(set, SyncOptions.removingUnlisted());
```

Or use annotations and explicit class registration (there is no classpath scanning):

```java
@AsEventType(code = "orders:sales:order:placed", name = "Order Placed")
public record OrderPlaced(String orderId) {}

@AsConnection(code = "billing-hook", name = "Billing Webhook")
final class BillingConnection {}

@AsSubscription(code = "order-placed", name = "Order Placed",
        target = "https://billing.example.com/hook",
        connectionCode = "billing-hook",
        eventTypes = {"orders:sales:order:placed"})
final class OrderPlacedHandler {}

var set = DefinitionScanner.scan("orders",
        List.of(OrderPlaced.class, BillingConnection.class, OrderPlacedHandler.class));
client.definitions().sync(set);
```

A subscription names its connection by `connectionCode`, which is stable across environments (ids are
not). A connection is owned by the application, and the platform assigns its service account. A
subscription's target can be a path such as `/webhooks/orders`, resolved against a base URL at sync
time so one definition works in every environment. `sync` throws `DefinitionSyncException` if any
category could not be synced, so a deploy step cannot mistake a partial failure for success.

## The outbox

Events are not published over HTTP. They are written to `outbox_messages` in your own database inside
your own transaction (migrations are in `migrations/postgresql` and `migrations/mysql`), and the
outbox poller ships them. See [The outbox pattern](../concepts/outbox.md).

```java
var driver = new JdbcOutboxDriver(dataSource);
var outbox = new OutboxManager(driver, "clt_your_client_tsid");

driver.withTransaction(tx -> {
    // business writes on (Connection) tx ...
    outbox.createEvent(CreateEventDto
            .create("orders:sales:order:placed", Map.of("orderId", orderId))
            .withMessageGroup(orderId), tx);
    return null;
});
```

Event types and dispatch-job codes must be fully qualified `application:subdomain:aggregate:action`
strings; the SDK rejects bare codes.

## Webhook verification

```java
WebhookSignature.verify(rawBodyBytes,
        request.header("X-FlowCatalyst-Signature"),
        request.header("X-FlowCatalyst-Timestamp"),
        signingSecret);
```

The body must be the raw bytes as received. The default replay tolerance is 300 seconds. See
[Messaging and delivery](../concepts/messaging-and-delivery.md#signatures).

## Users and invitations

`client.principals().createUser(...)` takes two flags that decide who sends the "set your password"
email. Prefer sending your own email (create the user with `sendInvitation(false)` and link back to
your application, where the platform's hosted login handles password creation), or take the link
yourself with `returnInviteLink(true)`. An invite link is a live 72-hour bearer credential: never log
it or store it in plain text.
