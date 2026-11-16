# SDKs overview

FlowCatalyst ships SDKs so your applications do not talk raw HTTP. They all speak the same
[wire contract](../reference/wire-contract.md), which is generated from the platform's OpenAPI
document, and they cover the same ground:

- a **control-plane client** for event types, subscriptions, pools, applications, roles and more;
- **definition sync**: declare what your application owns in code and push it;
- the **outbox**: write events inside your own database transaction;
- **delivery verification**: check the HMAC signature on a webhook;
- **sign-in** for web applications, where the SDK supports it.

| SDK | Language | Package | Page |
|---|---|---|---|
| TypeScript | TypeScript and JavaScript (Node) | `@flowcatalyst/sdk` | [TypeScript](typescript.md) |
| Laravel | PHP 8.1+, Laravel 10 to 13 | `flowcatalyst/laravel-sdk` | [Laravel](laravel.md) |
| Java | Java 25+ | `io.flowcatalyst:flowcatalyst-sdk` | [Java](java.md) |
| Function SDKs | Go, Rust, TypeScript | `clients/fn-*` | [Function SDKs](functions.md) |

A Go SDK also lives in the repository as an importable package, `pkg/fcsdk`, for Go applications:
a use-case and unit-of-work toolkit with an outbox sink, a control-plane client, definition sync, a
scheduled-job runner and webhook validation. Its webhook validator reads the signing secret from
`FLOWCATALYST_SIGNING_SECRET`. It is licensed MPL-2.0, while the platform is Apache-2.0.

## Which credentials does an SDK use?

An SDK authenticates as a **service account** with the OAuth `client_credentials` grant: a client id
and secret that you create in the console, or that [`fcdev init`](../reference/fcdev.md#fcdev-init)
creates for you locally. The service account's roles decide what the SDK may do: a new service account has none, so assign the
built-in `platform:application-service` role to let an application publish events and sync its own
definitions. An application-scoped service account is confined to its own application on the server. See
[Applications and tenants](../concepts/applications-and-tenants.md#service-accounts-and-oauth-clients).

## Local development with fcdev

Run `fcdev` for a full local platform and point the SDK at `http://localhost:8080`. If your application
uses the outbox, also run the poller against your application's database:

```sh
fcdev outbox --source-db-url postgres://user:pass@localhost:5432/app \
  --client-id <id> --client-secret <secret>
```

See [`fcdev outbox`](../reference/fcdev.md#fcdev-outbox).
