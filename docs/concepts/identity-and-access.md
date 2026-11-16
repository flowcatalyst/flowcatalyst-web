# Identity and access

FlowCatalyst is a full OAuth2/OIDC provider. Your applications never store credentials or run login
screens: they send people to the platform, get tokens back, and run their own sessions from them.
Machines authenticate with client credentials. Everything that proves identity (passwords, passkeys,
two-factor authentication, federation to a corporate identity provider) lives here, once, audited.

## The provider endpoints

| What | Where |
|---|---|
| Discovery document | `/.well-known/openid-configuration` |
| Signing keys (JWKS) | `/.well-known/jwks.json` |
| Authorization | `/oauth/authorize` |
| Token | `/oauth/token` |
| User info | `/oauth/userinfo` |

The platform advertises the `authorization_code`, `refresh_token` and `client_credentials` grants,
PKCE with `S256` only, the scopes `openid`, `profile`, `email` and `offline_access`, and RS256
signing. Tokens are issued with the issuer set by `FC_JWT_ISSUER`; set it to your public base URL.

## Principals, roles and permissions

- **Users** and **service accounts** are *principals* (`prn_...`). Every principal has a
  [tier](applications-and-tenants.md#clients-are-tenants): `ANCHOR`, `PARTNER` or `CLIENT`.
- A **role** is a named bundle of permissions, assigned to principals. Applications register their own
  roles through definition sync, and the role name carries the application code (`orders:editor`).
  Platform roles are seeded.
- A **permission** has four segments: `application:context:resource:action`. For the platform
  itself the application is `platform`, for example `platform:messaging:event-type:create`. A `*` in a
  segment is a wildcard. A permission failure is a `403` that names what was missing.
- **Client-managed roles** let a client's administrators run their own user management inside
  their boundary. Every operation is checked against the caller's client, so delegation never
  crosses tenants.

## Two kinds of token

Interactive logins and machine credentials produce different kinds of token, and the platform API
enforces the difference.

| Token | Minted by | Carries | Accepted by the platform API |
|---|---|---|---|
| **ID token** | interactive login (OIDC) | who the user is, and roles narrowed to the requesting application | no. Applications authenticate from it and run their own session. |
| **Identity access token** | interactive login | `token_use=identity` and no authority | **rejected** |
| **API access token** | `client_credentials`, the console, refresh | `token_use=api`, the tier, roles and granted `scope` | yes |

The consequences are deliberate. A browser token that leaks cannot drive the API. A relying
application's users get exactly the roles that belong to that application. And permission grants can
be narrowed at request time: a token asks for scopes and receives the intersection with its
principal's ceiling, never more.

Refresh tokens rotate on every use, with reuse detection across the whole token family (replaying an
old token revokes the family) and an absolute lifetime (7 days by default, `OIDC_REFRESH_TOKEN_TTL`).
Authorization codes are single-use. Access tokens last an hour by default
(`FC_JWT_ACCESS_TOKEN_TTL_SECS`), ID tokens five minutes, and a console session 24 hours
(`OIDC_SESSION_TTL`).

## Signing in

When someone enters their email on the login page the platform decides how to authenticate them from
the **email domain**:

- If the domain is mapped to an OIDC **identity provider** (Microsoft Entra, Google, or any
  standards-compliant OIDC provider), the user is redirected to their organisation's sign-in.
  The platform checks issuer, audience, nonce and that the returned email's domain is one it expects.
- Otherwise the user signs in with a **password**, optionally a **passkey**, and a second factor if one
  is required.

On federated sign-in the platform can **provision** the principal on first login using the
domain mapping's tier and client, and can **sync roles** from the identity provider's group claims on
every login, filtered by an allow-list: remove someone upstream and their next login drops the
role. Multi-tenant providers are pinned by issuer pattern and allowed domains so that a foreign tenant
cannot create identities.

## Second factors and credentials

- **Two-factor authentication** with TOTP authenticator apps or email PINs, a "remember this browser"
  option, recovery codes, a per-domain enforcement policy, and an audited administrator reset. A
  password reset for a user with a second factor requires the second factor.
- **Passkeys** (WebAuthn) for passwordless sign-in. Set `FC_WEBAUTHN_RP_ID` and
  `FC_WEBAUTHN_ORIGINS` for your domain; the defaults are `localhost` and `http://localhost:8080`.
- **Password policy** enforces length bounds, a common-password list, and refuses your name or email as a
  password. Credentials are only ever typed into pages the platform hosts.
- **Brute-force protection**: failed logins back off exponentially per identifier and address, with a
  longer lock if failures pile up across addresses. The `FC_LOGIN_*` variables tune it.
- **Developer credentials**: a user with the developer role can mint a personal API credential for
  `client_credentials`, acting as themselves, with no shared service account. Revoking the role
  stops new tokens immediately.

Password reset and 2FA emails are sent through SMTP when `FC_SMTP_HOST` is set. Without it they are
written to the log instead, which is what you want locally.

## Audit

Every administrative identity action lands in the **audit log**, and every authentication attempt,
success or failure, human or machine, lands in **login attempts**. Both are in the console under
**Platform**.
