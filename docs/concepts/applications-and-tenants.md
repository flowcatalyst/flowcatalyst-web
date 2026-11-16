# Applications and tenants

FlowCatalyst is multi-tenant. This page defines the nouns you meet in the console and the API:
clients, applications, service accounts and OAuth clients, and how an application registers
everything it owns.

## Clients are tenants

A **client** (`clt_...`) is a tenant: a business whose data and users live on the platform. Events,
subscriptions, dispatch pools and users can be scoped to a client, and a client-scoped principal can
never see another client's data.

Every principal (a user or a service account) has a **tier**:

| Tier | Who | Reach |
|---|---|---|
| `ANCHOR` | Platform staff and operators | Every client |
| `PARTNER` | A partner organisation | A set of clients |
| `CLIENT` | A tenant's own people | Exactly one client |

The tier travels in the access token as the `tier` claim. The permissions the token grants travel as
`scope`. See [Identity and access](identity-and-access.md).

Clients are created in the console (**Clients**) or with `POST /api/clients`. A client has an
`identifier`: a short slug that appears in pool names, delivery headers and logs. It is immutable after
creation, and `platform` is reserved.

## Applications are integration units

An **application** (`app_...`) is a system that publishes events, consumes them, or both: your order
service, your billing system, a partner integration. An application has a short `code` (a URL-safe
slug such as `orders`) and a type, `APPLICATION` or `INTEGRATION`. The code is the first segment of
every event type the application owns (`orders:...`) and the prefix of every role it registers.

A client is not automatically entitled to every application. Access is an explicit **client
configuration** (**Clients**, then a client's applications, or `PUT /api/clients/{id}/applications`),
and it bounds what the client's users can be granted: a client administrator can assign any
application their client is entitled to.

## Service accounts and OAuth clients

Machines authenticate with a **service account**: a principal of type service, with:

- a confidential **OAuth client** (`client_credentials` grant) used to obtain access tokens for the
  platform API, and
- **webhook credentials**: a bearer token and an HMAC signing secret the platform uses when it
  delivers *to* that account's endpoints ([signatures](messaging-and-delivery.md#signatures)).

An application normally has one service account, created for it. Service accounts can be
**application-scoped**: confined to their own application, enforced on every sync endpoint on the
server, so a compromised credential for one application cannot rewrite another's definitions.

From the console an administrator can mint a short-lived bearer token for any service account
(`POST /api/service-accounts/{id}/token`, audited), which is handy for testing without exposing the
client secret.

An **interactive OAuth client** (authorization-code flow with PKCE) is a separate thing: the client an
application uses when it signs *people* in through the platform. Its redirect URIs are matched exactly.
Both kinds appear under **OAuth Clients**.

`fcdev init` creates an application, a service account and an OAuth client in one step and writes the
credentials to a `.env` file; see the [fcdev reference](../reference/fcdev.md#fcdev-init).

## Declaring what your application owns

Applications declare their resources in code and push them to the platform. Each sync makes the
platform match the declaration, and syncs are idempotent, so running one on every deploy is safe.

| Resource | Sync endpoint |
|---|---|
| Event types (and schemas) | `POST /api/applications/{appCode}/event-types/sync` |
| Subscriptions | `POST /api/applications/{appCode}/subscriptions/sync` |
| Connections | `POST /api/applications/{appCode}/connections/sync` |
| Dispatch pools | `POST /api/applications/{appCode}/dispatch-pools/sync` |
| Roles and permissions | `POST /api/applications/{appCode}/roles/sync` |
| Scheduled jobs | `POST /api/applications/{appCode}/scheduled-jobs/sync` |
| Processes | `POST /api/applications/{appCode}/processes/sync` |
| Principals (users) | `POST /api/applications/{appCode}/principals/sync` |
| OpenAPI document | `POST /api/applications/{appCode}/openapi/sync` |
| Documentation pages | `POST /api/applications/{appCode}/docs/sync` |

Where partial adoption matters, the `removeUnlisted` option controls whether resources that came
from the SDK but are no longer listed are deleted. The SDKs wrap all of this, so you rarely call the
endpoints directly: see [TypeScript](../sdks/typescript.md#syncing-definitions),
[Laravel](../sdks/laravel.md#declaring-and-syncing-definitions) and [Java](../sdks/java.md#declaring-definitions).

### Documentation sync

An application can ship its own documentation the same way:

```
POST /api/applications/{appCode}/docs/sync
{ "docs": [ { "slug": "getting-started", "content": "# Getting started\n..." } ] }
```

The payload is the complete set (pages that are not listed are removed), the title comes from the
first `# ` heading, and the pages appear in the console under **Platform, Documentation**, grouped by
application. It needs the `platform:application-service:docs:sync` permission.

## Identifiers

Every platform entity has a typed, sortable id with a three-letter prefix, so an id is self-describing
in logs and cannot be confused with another kind. Ids are always generated by the platform.

| Prefix | Entity | | Prefix | Entity |
|---|---|---|---|---|
| `clt_` | Client | | `sub_` | Subscription |
| `app_` | Application | | `sjb_` | Scheduled job |
| `prn_` | Principal (user or service) | | `sac_` | Service account |
| `evt_` | Event type | | `oac_` | OAuth client |
| `idp_` | Identity provider | | `ptu_` | Portal user |

Events and dispatch jobs use bare 13-character ids with no prefix, because they are written at high
volume.
