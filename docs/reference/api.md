# HTTP API

The platform API is described by an **OpenAPI 3.1** document generated from the code that serves it,
so the document and the behaviour cannot drift apart. It covers about 290 operations across more
than 200 paths.

## Where to find the spec

| Source | What it is |
|---|---|
| `GET /api/openapi.json` and `GET /api/openapi.yaml` | The live document from a running platform. Unauthenticated, so tooling and code generators can fetch it. |
| `GET /q/openapi` | The same JSON, at an alias path. |
| `GET /swagger-ui` | A Swagger UI page for browsing and trying requests. It loads the Swagger UI scripts from a public CDN, so it needs internet access from your browser. |
| `api/openapi.lock.json` in the repository | The committed baseline of the spec. CI fails if the code drifts from it. This is the file to diff or to generate a client from. |
| `make dump-spec` | Prints the current spec to standard output without needing a database. |

The router has its own, smaller document at `/router/openapi.json` (under `FC_ROUTER_HTTP_PREFIX`).

Some endpoints are intentionally **not** in the platform spec because they are plain HTTP handlers and
not described by it: the OAuth/OIDC provider surface (`/oauth/authorize`, `/oauth/token`,
`/.well-known/...`), the session and password-reset endpoints under `/auth/`, and the endpoints that
function runners use to reach the platform (`/control/functions/...`). The
[wire contract](wire-contract.md) page lists them.

## Authentication

Call the API with a bearer token. Get one with the `client_credentials` grant using a service
account's client id and secret:

```sh
curl -s -X POST http://localhost:8080/oauth/token \
  -d grant_type=client_credentials \
  -d client_id=$FLOWCATALYST_CLIENT_ID \
  -d client_secret=$FLOWCATALYST_CLIENT_SECRET
# {"access_token":"...","token_type":"Bearer","expires_in":3600}

curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/api/event-types
```

The console uses a session cookie (`fc_session`) set by `POST /auth/login`, which the API also accepts.
A missing credential is a `401`; a missing permission is a `403` whose message names the permission
(`platform:messaging:event-type:create`, for example). See
[Identity and access](../concepts/identity-and-access.md) for what a token carries and which kinds the
API refuses.

## Conventions

- **Timestamps** are RFC 3339 with exactly six fractional digits: `2026-05-24T08:30:00.123456Z`.
- **Enums** are `SCREAMING_SNAKE_CASE` strings.
- **Errors** are `{"error": "CODE", "message": "..."}`. Validation is `400`, unauthenticated `401`,
  forbidden `403`, not found `404`, a conflict or business-rule failure `409`, rate limited `429`.
  There is no `422` in the platform's own error mapping.
- **Lists** use one of three shapes, chosen per endpoint: cursor (`items`, `nextCursor`, `hasMore`) for
  the high-volume event and dispatch-job tables, offset (`items`, `totalCount`, `page`, `pageSize`,
  `totalPages`) for most others, or a bare list.
- **Operation ids** are stable and are used as method names by the generated clients.

## Resource families

| Path prefix | What it manages |
|---|---|
| `/api/events`, `/api/event-types` | Publishing and registering events. |
| `/api/subscriptions`, `/api/connections` | Routing and delivery credentials. |
| `/api/dispatch-jobs`, `/api/dispatch-pools` | Deliveries and their limits. |
| `/api/scheduled-jobs` | Cron jobs, instances and logs. |
| `/api/processes` | Multi-step process definitions. |
| `/api/applications`, `/api/clients` | Integration units and tenants, plus the application sync endpoints. |
| `/api/principals`, `/api/roles`, `/api/service-accounts`, `/api/oauth-clients` | Identity and access. |
| `/api/identity-providers`, `/api/email-domain-mappings`, `/api/idp-role-mappings`, `/api/anchor-domains`, `/api/auth-configs` | Federation and domain routing. |
| `/api/portal-users`, `/api/portal-apps` | The customer-portal identity plane. |
| `/api/functions`, `/api/function-domains` | Function versions, aliases, routes and zones. |
| `/api/audit-logs`, `/api/login-attempts` | Audit trails. |
| `/api/docs` | The documentation pages the console shows. |

## Generated clients

The TypeScript, Laravel and Java SDKs are generated from this document (`make sdk-generate` refreshes
and regenerates the first two, `make build-java-sdk` the third), which is why their types always match.
If your language has no SDK, generate a client from `api/openapi.lock.json` or
`/api/openapi.json` with any OpenAPI 3.1 generator.
