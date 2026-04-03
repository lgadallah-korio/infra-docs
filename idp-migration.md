# IdP Migration

This document describes the existing identity and authentication system built around Azure Entra B2C and defines requirements for its replacement.

## Current System

### Overview

Authentication for Korio's application users is provided by
[**Azure Entra B2C**](https://learn.microsoft.com/en-us/azure/active-directory-b2c/technical-overview), one tenant per environment. The two application components that integrate with B2C are:

- [**`portico-react`**](https://github.com/korio-clinical/portico-react-llama) — the React SPA; handles login and token acquisition via [MSAL](https://learn.microsoft.com/en-us/entra/identity-platform/msal-overview).
- [**`auth-node`**](https://github.com/korio-clinical/auth-node-llama) — a [Node.js](https://nodejs.org/en) microservice; validates tokens on every inbound API request and resolves the caller's identity.

[NGINX](https://nginx.org/) sits between the two as the API gateway, enforcing that every backend request passes through `auth-node` before being proxied.

### B2C Tenants (Per Environment)

One B2C tenant is provisioned per environment. All clients within an environment share the same tenant — there is no per-client B2C isolation. Client context (which service version/path a user belongs to) is resolved post-login by [`back-end-node`](https://github.com/korio-clinical/back-end-node-llama), not by B2C.

| Environment | Tenant Name | Policy Name |
|---|---|---|
| dev | `koriodevaad` | `B2C_1_dev_signupsignin` |
| test | `koriotestaad` | `B2C_1_test_signupsignin` |
| staging | `koriostagingaad` | `B2C_1_staging_signupsignin` |
| prod | `koriob2c` | `B2C_1_{subenv}` (one policy per sub-env) |

### Authentication Flow

```
portico-react                NGINX               auth-node          MongoDB
     |                         |                     |                 |
     |-- login redirect ------>|                     |                 |
     |<-- redirect to B2C -----|                     |                 |
     |                                               |                 |
     |======= B2C login / MFA (browser redirect) ===>|                 |
     |<====== ID token (OIDC) =======================|                 |
     |                                               |                 |
     |-- GET /api/v1/... Bearer: {idToken} --------->|                 |
     |                         |-- auth_request ---->|                 |
     |                         |      GET /api/v1/auth/verify          |
     |                         |                     |-- JWKS verify   |
     |                         |                     |-- lookup email->|
     |                         |                     |<- user record --|
     |                         |                     |-- assert ACTIVE |
     |                         |<- 200 + User header-|                 |
     |                         |-- proxy_pass ------->backend service  |
     |                         |   X_HTTP_USER: {...}                  |
```

- `portico-react` acquires the **ID token** (not the access token) and sends it as `Authorization: Bearer` on all API calls.
- NGINX uses `auth_request` to call `auth-node` synchronously on every request. On success, `auth-node` returns the resolved user object in a response header (`X_HTTP_USER`), which NGINX forwards to the backend service.
- The token is stored in `SessionStorage`; cleared on tab close. A 15-minute inactivity timeout is enforced client-side.

### Libraries

| Component | Library | Role |
|---|---|---|
| `portico-react` | `@azure/msal-browser` ^3.7.0 | Login, token acquisition |
| `portico-react` | `@azure/msal-react` ^2.0.3 | React integration |
| `auth-node` | `passport-azure-ad` ^4.3.4 | Bearer token validation |
| `auth-node` | `@azure/msal-node` ^1.15.0 | Management API credentials |
| `auth-node` | `@microsoft/microsoft-graph-client` ^3.0.5 | User management |

### Token Validation (`auth-node`)

`auth-node` uses [`passport-azure-ad`](https://www.npmjs.com/package/passport-azure-ad) BearerStrategy. The [OIDC](https://openid.net/developers/how-connect-works/) metadata URL is constructed from the environment's tenant name and policy name at startup. The strategy fetches the [JWKS](https://datatracker.ietf.org/doc/html/rfc7517) from B2C, validates the [JWT](https://datatracker.ietf.org/doc/html/rfc7519) signature, and asserts the audience matches `AZURE_CLIENT_ID`.

Claims extracted from the validated token:

- `info.emails[0]` — used as the lookup key in MongoDB
- `info.iat` — issued-at timestamp, used for audit logging

### User Management (Graph API)

Out-of-band user lifecycle operations (performed by Korio administrators, not end users) are implemented via the Microsoft Graph API using client credentials. The B2C object ID returned by Microsoft Graph is stored on the MongoDB user record as `user.azure_oid`.

| Operation | Graph Endpoint |
|---|---|
| Create user | `POST /users` |
| Find user | `GET /users?$filter=startswith(userPrincipalName,...)` |
| Reset password | `PATCH /users/{oid}` — `passwordProfile` |
| Enable / disable | `PATCH /users/{oid}` — `accountEnabled` |
| Set email MFA | `POST /users/{oid}/authentication/emailMethods` |

### Test Environment Override

When `NODE_ENV === 'SQAA'`, `auth-node` bypasses B2C validation entirely and validates tokens using a local symmetric key (`JWT_SECRET_KEY`). This path must be preserved or reproduced in the replacement.

---

## Requirements for the Replacement System

### Functional Requirements

| # | Requirement |
|---|---|
| F-1 | **Headless / API-first.** No enforced hosted login UI from the IdP. Korio must be able to supply its own login UI or control the login UX entirely. |
| F-2 | **OIDC / OAuth 2.0.** Must issue OIDC ID tokens consumable by a standard JWT library. Token must include an email claim usable as a user identifier. |
| F-3 | **SAML 2.0.** Must support acting as a [SAML](https://en.wikipedia.org/wiki/SAML) service provider (SP) to federate with upstream corporate IdPs (e.g. a sponsor's Okta or Azure AD tenant). This is required to support sponsor SSO mandates such as those that may arise from clients like Bristol Myers Squibb. |
| F-4 | **Multi-factor authentication.** Must support at minimum e-mail OTP; [TOTP](https://en.wikipedia.org/wiki/Time-based_one-time_password) (authenticator app) strongly preferred. |
| F-5 | **Out-of-band user management.** All user lifecycle operations (create, enable/disable, password reset, MFA enrollment) must be available via a management API callable by Korio's own services — no reliance on user-initiated self-service flows for these operations. |
| F-6 | **Admin web console.** A web UI for Korio administrators to inspect and manage users, applications, and IdP configuration. |
| F-7 | **Per-environment isolation.** Must support logically separate identity stores per deployment environment (dev / test / staging / prod), equivalent to the current one-tenant-per-environment model. |
| F-8 | **Sponsor IdP federation.** Must support OIDC and SAML federation with external upstream IdPs so that sponsor-mandated SSO flows can be accommodated per client. |

### API / SDK Requirements

| # | Requirement |
|---|---|
| A-1 | **Go client.** A supported Go client library or a well-documented REST/gRPC API usable from Go for both token validation (JWKS) and management operations. |
| A-2 | **JavaScript / Node.js client.** A supported JS/Node.js library or REST API for the same, to replace the current MSAL + Graph API usage in `auth-node` and `portico-react`. |

### Deployment Requirements

| # | Requirement |
|---|---|
| D-1 | **AKS-hostable or managed SaaS.** Must either deploy to Kubernetes via a Helm chart / operator, or be available as a managed cloud service. On-premises-only solutions are not acceptable. |
| D-2 | **High availability.** Must support HA configuration when self-hosted (no single-replica-only constraint). |
| D-3 | **Operability.** If self-hosted: standard Kubernetes deployment patterns, health endpoints, and support for external secret injection (e.g. Azure Key Vault / Kubernetes Secrets). |

### Compliance / Security Requirements

| # | Requirement |
|---|---|
| C-1 | **Audit logging.** Must emit logs for authentication events (login, logout, failed attempts) and administrative actions (user create/modify/disable). |
| C-2 | **Security certifications.** SOC 2 Type II at minimum. ISO 27001 preferred. (Required for pharma/clinical trial customer audits.) |
| C-3 | **Encrypted tokens.** Tokens must be signed (RS256 or ES256); symmetric-key-only solutions (HS256) are not acceptable in production. |

### Migration Requirements

| # | Requirement |
|---|---|
| M-1 | **Lazy user migration.** Users are migrated on-demand as they authenticate, not in a batch cutover. When a user presents a valid B2C token during the transition period, `auth-node` detects that the account has not yet been migrated, creates the account in the new IdP via the management API, and returns a redirect response that portico-react handles to move the user to the new IdP login. After the user completes their first new-IdP login and resets their password, the corresponding B2C account is disabled. See [Lazy Migration Flow](#lazy-migration-flow) below. |
| M-2 | **Migration state tracking.** The MongoDB user record must carry a migration status field (e.g. `auth_migration_status: pending \| migrated`) so that `auth-node` can determine which token validation path to apply per user. |
| M-3 | **Temporary credential delivery.** During lazy migration, a temporary password is generated by the new IdP management API (not by `auth-node`) and displayed to the user in-browser immediately after their B2C login. It must be: single-use (invalidated after first new-IdP login regardless of whether password reset has completed), short-lived (15-30 minute expiry), and generated by a [CSPRNG](https://en.wikipedia.org/wiki/Cryptographically_secure_pseudorandom_number_generator). The credential is never stored by `auth-node` and is not transmitted via email. |
| M-4 | **Dual-token parallel operation.** During the transition period, `auth-node` must validate both B2C tokens (for unmigrated users) and new IdP tokens (for migrated users). The validation path is selected per request based on `auth_migration_status`. |
| M-5 | **Unclaimed account cleanup.** A Kubernetes CronJob runs on an interval matching the temporary password expiry window (e.g. every 30 minutes). It queries MongoDB for users with `auth_migration_status: awaiting_login` whose new IdP account was created more than one expiry window ago, deletes those accounts from the new IdP, and resets `auth_migration_status` to `pending`. This returns the user to a clean migration-ready state for their next B2C login attempt. The CronJob must only target accounts older than the expiry window to avoid deleting accounts that are actively being claimed. |
| M-5a | **Post-transition sweep.** After the transition window closes, any user accounts still at `auth_migration_status: pending` (users who never logged in during the transition period) must be handled: either batch-migrated with a forced password reset notification, or disabled, depending on policy. |
| M-6 | **User ID mapping.** The MongoDB `user.azure_oid` field must be replaced with a provider-agnostic `idp_user_id` field storing the new IdP's internal user ID (the brokered identity, not the upstream Entra AD OID for federated users). |
| M-7 | **`auth-node` compatibility.** The existing NGINX `auth_request` pattern must be preserved. `auth-node` is the integration point to be updated; the NGINX config and downstream backend contract (`X_HTTP_USER` header) must remain unchanged. |
| M-8 | **Test override.** The `SQAA` local-JWT override path in `auth-node` must be reproduced with the new IdP (or an equivalent mechanism retained). |

### Lazy Migration Flow

```
portico-react         NGINX          auth-node        new IdP mgmt API     B2C mgmt API
     |                  |                |                    |                   |
     |-- B2C login ----> (browser redirect to B2C)            |                   |
     |<-- B2C ID token --------------------------------       |                   |
     |                  |                |                    |                   |
     |-- GET /api/... Bearer: {b2cToken}->|                   |                   |
     |                  |-- auth_request->|                   |                   |
     |                  |    /auth/verify |                   |                   |
     |                  |                |-- validate B2C token                   |
     |                  |                |-- lookup user in MongoDB               |
     |                  |                |   auth_migration_status: pending       |
     |                  |                |-- create account ------->              |
     |                  |                |<- new IdP user ID + temp password <--  |
     |                  |                |-- store idp_user_id in MongoDB         |
     |                  |                |-- set migration_status: awaiting_login |
     |                  |<- 302 redirect (new IdP login + temp password display)  |
     |<-- redirect to new IdP login UI --|                    |                   |
     |                  |                |                    |                   |
     |  (user logs in to new IdP with temp password, resets password)             |
     |                  |                |                    |                   |
     |-- GET /api/... Bearer: {newIdPToken}->|                |                   |
     |                  |-- auth_request->|                   |                   |
     |                  |    /auth/verify |                   |                   |
     |                  |                |-- validate new IdP token               |
     |                  |                |-- set migration_status: migrated       |
     |                  |                |-- disable B2C account ------------>    |
     |                  |<- 200 + User header                 |                   |
     |                  |-- proxy_pass --> backend service    |                   |
```

Notes:
- The temporary password is shown to the user in portico-react immediately after the B2C redirect response; it is not stored by `auth-node` after being passed to the frontend.
- B2C account disablement occurs on the first successful new-IdP token validation after migration, not at account creation time, ensuring the user is never locked out between the two steps.
- During the transition period, `auth-node` accepts both B2C and new IdP tokens; post-transition, the B2C validation path is removed.
- `awaiting_login` is a transient state managed exclusively by the unclaimed-account CronJob (M-5). From `auth-node`'s perspective only two states are relevant: `pending` (use B2C validation path) and `migrated` (use new IdP validation path). If a B2C token arrives for a user in `awaiting_login` state, `auth-node` treats it identically to `pending` — it does not re-trigger migration, as the CronJob will reset the state to `pending` once the temp password expires.

---

## Candidate Providers

The following providers have been identified as candidates for qualification against the requirements above. Providers are grouped by deployment model. This list is not exhaustive and is intended as a starting point for the formal survey and qualification tasks.

### Shortlist

| Provider | Model | Notes |
|---|---|---|
| **Keycloak** | Self-hosted (K8s Helm / Operator) | Most mature open source IdP. Strong SAML SP + upstream federation, OIDC, TOTP + email OTP, comprehensive REST admin API. Go and JS clients available. HA supported. SOC 2 falls on Korio as operator — must be covered in Korio's own audit scope if self-hosted. |
| **Auth0** | Managed SaaS (Okta) | De facto standard managed IdP. SOC 2 Type II + ISO 27001. Good SAML federation and OIDC. Official JS SDK; community Go SDK. **Verify** that headless/custom login UI (F-1) is fully supported without hosted-page constraints. Pricing scales with monthly active users. |
| **FusionAuth** | Self-hosted or managed SaaS | Explicitly API-first and headless by design — strong F-1 fit. SAML SP + federation, OIDC, TOTP + email OTP. Comprehensive management API; official JS SDK; community Go SDK. K8s deployable via Helm. SOC 2 Type II on managed tier. |
| **Zitadel** | Self-hosted or managed SaaS | Built in Go — first-class Go SDK is a genuine differentiator for A-1. OIDC + SAML, TOTP + WebAuthn + email OTP, management API (gRPC + REST). K8s deployable; HA supported. Relatively newer project; SOC 2 status of managed offering must be verified during qualification. |
| **Azure Entra External ID** | Managed SaaS (Microsoft) | Microsoft's official B2C replacement — natural migration path, familiar tooling (MSAL, Graph API). SOC 2 + ISO 27001 via Microsoft certifications. Perpetuates the Microsoft dependency; SAML federation as SP is less flexible than the other candidates. Headless/custom UI support has historically been constrained — verify against F-1. |

### Excluded from Shortlist

| Provider | Reason |
|---|---|
| **Ory (Kratos + Hydra)** | No native SAML support — F-3 and F-8 would require a separate SAML proxy (e.g. Dex), adding operational complexity. Revisit if SAML requirement is ever dropped. |
| **Okta** (enterprise tier) | Covers all requirements but priced for large enterprise. Auth0 (same parent company) provides equivalent capability at lower cost for Korio's scale. |
| **Ping Identity / PingOne** | Enterprise-grade, full compliance coverage, but heavyweight operationally and expensive relative to the others. |

### Key Discriminators for Qualification

1. **SOC 2 Type II scope**: For self-hosted options (Keycloak, FusionAuth community, Zitadel self-hosted), confirm whether Korio's existing SOC 2 scope can absorb the IdP or whether a managed tier is required.
2. **Headless login UI** (F-1): Verify that Auth0 and Entra External ID support fully custom login UX without hosted-page constraints.
3. **SAML SP flexibility** (F-3 / F-8): Confirm that upstream IdP federation (Okta, Entra AD) works without undocumented limitations.
4. **Go client maturity** (A-1): Community Go clients (Auth0, FusionAuth) should be assessed for maintenance activity and API coverage before committing.

---

## Components Requiring Change at Migration

| Component | Current Dependency | Change Required |
|---|---|---|
| `portico-react` | `@azure/msal-browser`, `@azure/msal-react` | Replace with new IdP's browser SDK or PKCE flow; add migration redirect handling (display temp password, redirect to new IdP login) |
| `auth-node` | `passport-azure-ad`, `@azure/msal-node`, `@microsoft/microsoft-graph-client` | Add dual-token validation (B2C + new IdP); add lazy migration interceptor; replace user management with new IdP management API; add B2C account disablement trigger |
| MongoDB | `user.azure_oid` field | Replace with `idp_user_id` (new IdP's brokered user ID); add `auth_migration_status` field |
| Terraform / Azure | B2C tenant provisioning | Replace with new IdP provisioning (Terraform provider or manual) |
| Environment config | B2C tenant/policy env vars | Add new IdP issuer/client env vars alongside B2C vars during transition; remove B2C vars post-transition |
| New: migration CronJob | — | Kubernetes CronJob to detect and clean up unclaimed new-IdP accounts; resets `auth_migration_status` to `pending` so users get a fresh migration attempt on next B2C login |

