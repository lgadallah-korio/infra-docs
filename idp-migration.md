# IdP Migration

This document describes the existing identity and authentication
system built around Azure Entra B2C and defines requirements for
its replacement.

## Current System

### Overview

Authentication for Korio's application users is provided by
**Azure Entra B2C**, one tenant per environment. The two
application components that integrate with B2C are:

- **`portico-react`** — the React SPA; handles login and token
  acquisition via MSAL.
- **`auth-node`** — a Node.js microservice; validates tokens on
  every inbound API request and resolves the caller's identity.

NGINX sits between the two as the API gateway, enforcing that every
backend request passes through `auth-node` before being proxied.

### B2C Tenants (Per Environment)

One B2C tenant is provisioned per environment. All clients within
an environment share the same tenant — there is no per-client B2C
isolation. Client context (which service version/path a user
belongs to) is resolved post-login by `back-end-node`, not by B2C.

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
     |======= B2C login / MFA (browser redirect) ========>            |
     |<====== ID token (OIDC) ============================             |
     |                                               |                 |
     |-- GET /api/v1/... Bearer: {idToken} -------->|                 |
     |                         |-- auth_request ---->|                 |
     |                         |      GET /api/v1/auth/verify         |
     |                         |                     |-- JWKS verify  |
     |                         |                     |-- lookup email->|
     |                         |                     |<- user record --|
     |                         |                     |-- assert ACTIVE |
     |                         |<- 200 + User header-|                 |
     |                         |-- proxy_pass ------->backend service  |
     |                         |   X_HTTP_USER: {...}                  |
```

- `portico-react` acquires the **ID token** (not the access token)
  and sends it as `Authorization: Bearer` on all API calls.
- NGINX uses `auth_request` to call `auth-node` synchronously on
  every request. On success, `auth-node` returns the resolved user
  object in a response header (`X_HTTP_USER`), which NGINX
  forwards to the backend service.
- Token is stored in `SessionStorage`; cleared on tab close.
  A 15-minute inactivity timeout is enforced client-side.

### Libraries

| Component | Library | Role |
|---|---|---|
| `portico-react` | `@azure/msal-browser` ^3.7.0 | Login, token acquisition |
| `portico-react` | `@azure/msal-react` ^2.0.3 | React integration |
| `auth-node` | `passport-azure-ad` ^4.3.4 | Bearer token validation |
| `auth-node` | `@azure/msal-node` ^1.15.0 | Management API credentials |
| `auth-node` | `@microsoft/microsoft-graph-client` ^3.0.5 | User management |

### Token Validation (`auth-node`)

`auth-node` uses `passport-azure-ad` BearerStrategy. The OIDC
metadata URL is constructed from the environment's tenant name and
policy name at startup. The strategy fetches the JWKS from B2C,
validates the JWT signature, and asserts the audience matches
`AZURE_CLIENT_ID`.

Claims extracted from the validated token:

- `info.emails[0]` — used as the lookup key in MongoDB
- `info.iat` — issued-at timestamp, used for audit logging

### User Management (Graph API)

Out-of-band user lifecycle operations (performed by Korio
administrators, not end users) are implemented via the Microsoft
Graph API using client credentials. The B2C object ID returned by
Graph is stored on the MongoDB user record as `user.azure_oid`.

| Operation | Graph Endpoint |
|---|---|
| Create user | `POST /users` |
| Find user | `GET /users?$filter=startswith(userPrincipalName,...)` |
| Reset password | `PATCH /users/{oid}` — `passwordProfile` |
| Enable / disable | `PATCH /users/{oid}` — `accountEnabled` |
| Set email MFA | `POST /users/{oid}/authentication/emailMethods` |

### Test Environment Override

When `NODE_ENV === 'SQAA'`, `auth-node` bypasses B2C validation
entirely and validates tokens using a local symmetric key
(`JWT_SECRET_KEY`). This path must be preserved or reproduced
in the replacement.

---

## Requirements for the Replacement System

### Functional Requirements

| # | Requirement |
|---|---|
| F-1 | **Headless / API-first.** No enforced hosted login UI from the IdP. Korio must be able to supply its own login UI or control the login UX entirely. |
| F-2 | **OIDC / OAuth 2.0.** Must issue OIDC ID tokens consumable by a standard JWT library. Token must include an email claim usable as a user identifier. |
| F-3 | **SAML 2.0.** Must support acting as a SAML service provider (SP) to federate with upstream corporate IdPs (e.g. a sponsor's Okta or Azure AD tenant). This is required to support sponsor SSO mandates such as those that may arise from clients like Bristol Myers Squibb. |
| F-4 | **Multi-factor authentication.** Must support at minimum email OTP; TOTP (authenticator app) strongly preferred. |
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
| M-1 | **User identity migration.** A defined path to migrate existing B2C users to the new IdP. Note: B2C does not export password hashes — a forced password-reset flow at cutover must be anticipated. |
| M-2 | **User ID mapping.** The MongoDB `user.azure_oid` field must be migrated to the new IdP's user identifier, or the field replaced with a provider-agnostic key. |
| M-3 | **`auth-node` compatibility.** The existing NGINX `auth_request` pattern must be preserved. `auth-node` is the integration point to be updated; the NGINX config and downstream backend contract (`X_HTTP_USER` header) should remain unchanged. |
| M-4 | **Test override.** The `SQAA` local-JWT override path in `auth-node` must be reproduced with the new IdP (or an equivalent mechanism retained). |

---

## Components Requiring Change at Migration

| Component | Current Dependency | Change Required |
|---|---|---|
| `portico-react` | `@azure/msal-browser`, `@azure/msal-react` | Replace with new IdP's browser SDK or PKCE flow |
| `auth-node` | `passport-azure-ad`, `@azure/msal-node`, `@microsoft/microsoft-graph-client` | Replace token validation + user management with new IdP equivalents |
| MongoDB | `user.azure_oid` field | Migrate to new IdP user ID or use email as canonical key |
| Terraform / Azure | B2C tenant provisioning | Replace with new IdP provisioning (Terraform provider or manual) |
| Environment config | B2C tenant/policy env vars | Replace with new IdP issuer/client env vars |
