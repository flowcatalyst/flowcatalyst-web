# Portal users

*The platform proves who someone is. The portal application decides what that means.*

Some FlowCatalyst clients run customer portals: web applications for **their own customers**. Those
customers are a separate population from platform users. They have their own identities, entry
points and credentials, and they carry no platform authority at all. A platform administrator and a
portal user may share an email address and are still two unrelated identities.

This page is a summary. The in-product documentation (Platform, Documentation) has the full
sequence diagrams.

## The parts

| Part | What it is |
|---|---|
| **Portal identity** (`ptu_...`) | One identity per client and email. It holds an email, a name, an optional password hash, a status, and its portal-application grants. It never holds roles or permissions. |
| **Portal application** (`pta_...`) | A named portal that a client runs, for example `customer-portal`. A client can run several. Identities are granted per portal application. |
| **Portal OAuth client** | An OAuth client flagged as belonging to a tenant client and linked to the portal application it fronts. Its flows start at `/portal/authorize` instead of `/oauth/authorize`. |
| **Identity provider** | An authenticator only. If an OIDC identity provider owns an email domain, every sign-in for that domain routes to it. There is deliberately no per-portal binding. |
| **Membership** | Lives in the portal application's own database: organisations, roles, delegated administration. The platform never learns what an "organisation" is. |

## Signing in

A portal sign-in is always a fresh authentication. The platform never sets or reuses a session
cookie for it. The portal application runs its own session from the ID token.

1. The portal application redirects the user to `/portal/authorize` with its portal OAuth client,
   PKCE and a state value.
2. The platform looks at the email's domain. If an OIDC identity provider owns it, the user signs in
   with their organisation. Otherwise they use a portal password.
3. The platform returns an authorization code. The portal exchanges it at `/oauth/token`.
4. The token response contains an ID token whose subject is the `ptu_` id (with an **empty roles
   claim** and, for a linked portal OAuth client, `portal_app_code`), and an identity-only access token
   that the platform API rejects as a credential. There is **no refresh token**: when the portal's
   own session ends, the user signs in again.
5. The portal checks its own membership table. A valid sign-in with no membership row is refused
   by the portal.

Password sign-in through a portal application is refused unless the identity holds that portal's
grant. A federated sign-in creates the identity and grants the portal it came through on first
login only.

## Inviting and managing portal users

Invitations come **from the portal application**, not from the platform console, because an invite
has two halves: the platform identity and the portal's own membership row.

`POST /api/portal-users` is an idempotent "ensure": it creates or reactivates the identity for a
client and email, grants the calling portal application, and decides the invitation from the same domain
lookup as sign-in. A domain owned by an identity provider gets a "join the portal" email with no
password. A password domain gets a 72-hour set-password link. The caller is the portal's service
account or a client administrator; the permission is client-delegable, so a client manages its own
portal population and nobody else's.

| Action | Effect |
|---|---|
| Suspend (deactivate) | Blocks the next code issuance. The portal kills its own live sessions for an immediate cut. |
| Reactivate | Explicit activate, or ensure again. |
| Revoke one portal | `DELETE /api/portal-users/{id}/apps/{code}` removes one grant and leaves the others. |
| Offboard | `DELETE /api/portal-users/{id}` removes the identity across every portal of that client. |
| Forgot password | Self-service from the portal login page; a 15-minute link; refused for domains owned by an identity provider. |

The status shown to administrators is derived, never stored: **Invited**, **Active**,
**Invite expired** (the 72-hour link lapsed unused) or **Suspended**.

The Laravel and TypeScript SDKs include portal-identity helpers; see their pages under
[SDKs](../sdks/index.md).
