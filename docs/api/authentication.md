# Authentication Guide

ArenaX uses **JWT Bearer tokens** with short-lived access tokens and longer-lived refresh tokens.

## Contract version

The public API contract is versioned and published as an OpenAPI document:

- **Current contract version:** `1.0.0`
- **OpenAPI document:** served at `/api/docs/openapi.json` (also available in the repo under `docs/api/openapi.json`)
- **Source of truth:** the contract is generated/validated from the Rust and TypeScript server sources; the published document is the authoritative description of request/response schemas, auth requirements, pagination, and error codes.

Every endpoint in this guide (auth, tournament, match, wallet, dispute, notification) is described in that document with concrete schemas and examples. The examples in this guide are exercised by the endpoint contract tests in CI.

## Deprecation policy

- **Breaking changes require an explicit decision.** Any change that removes or renames a field, changes a type, tightens validation, changes an error code, or alters auth requirements is a breaking change.
- **Breaking changes require a version bump** of the contract (major version) and a corresponding **deprecation entry** in the OpenAPI document (`deprecated: true` on the affected operation/schema, plus a changelog note).
- **Minimum notice window:** deprecated endpoints/fields remain functional for at least **90 days** (or two minor releases, whichever is longer) after the deprecation entry is published.
- **CI enforcement:** a contract-diff check runs in CI against the published OpenAPI document. It fails the build when a breaking change is detected without a version bump and deprecation entry, so breaking changes cannot land silently.
- **Validation in CI:** schema linting and endpoint contract tests run on every pull request.
=======

## Token Lifecycle

```
Register / Login
      │
      ▼
 access_token (15 min)  +  refresh_token (7 days)
      │                          │
      │ expires                  │ still valid
      ▼                          ▼
  Use /auth/refresh  ──────► new token pair
      │
      │ refresh also expired
      ▼
  Re-login required
```

## 1. Register

```http
POST /api/auth/register
Content-Type: application/json

{
  "username": "player_one",
  "email": "player@example.com",
  "phone_number": "+2348012345678",
  "password": "S3cur3P@ss!"
}
```

Response `201`:
```json
{
  "token": "<access_token>",
  "refresh_token": "<refresh_token>",
  "user": { "id": "...", "username": "player_one", ... }
}
```

## 2. Login

```http
POST /api/auth/login
Content-Type: application/json

{
  "email": "player@example.com",
  "password": "S3cur3P@ss!"
}
```

## 3. Authenticated Requests

Include the access token in every protected request:

```http
GET /api/auth/me
Authorization: Bearer <access_token>
```

## 4. Refresh Tokens

When the access token expires (HTTP 401 `Token expired`):

```http
POST /api/auth/refresh
Content-Type: application/json

{
  "refresh_token": "<refresh_token>"
}
```

Response `200`:
```json
{
  "access_token": "<new_access_token>",
  "refresh_token": "<new_refresh_token>",
  "expires_in": 900,
  "token_type": "Bearer"
}
```

> Both tokens are rotated on refresh. Store the new pair and discard the old ones.

## 5. Logout

Blacklists the current access token server-side:

```http
POST /api/auth/logout
Authorization: Bearer <access_token>
```

## 6. Session Management

List all active sessions:
```http
GET /api/auth/sessions
Authorization: Bearer <access_token>
```

Revoke all sessions (e.g. after a security incident):
```http
POST /api/auth/revoke-sessions
Authorization: Bearer <access_token>
```

## JWT Claims

The decoded access token payload:

```json
{
  "sub": "<user_uuid>",
  "exp": 1714000000,
  "iat": 1713999100,
  "jti": "<unique_token_id>",
  "token_type": "access",
  "device_id": null,
  "session_id": "<session_uuid>",
  "roles": ["user"]
}
```

Admin users have `"roles": ["admin", "user"]`.

## Error Responses

| Status | Meaning |
|--------|---------|
| 401 `Missing authorization header` | No `Authorization` header sent |
| 401 `Invalid authorization header format` | Header not in `Bearer <token>` format |
| 401 `Token expired` | Access token TTL elapsed — refresh it |
| 401 `Session expired or invalid` | Session was revoked server-side |
| 403 `Token has been revoked` | Token was explicitly blacklisted |

## Security Best Practices

- Store tokens in memory (not `localStorage`) in browser clients.
- Use `HttpOnly` cookies for refresh tokens in web apps.
- Always use HTTPS — tokens are bearer credentials.
- Rotate refresh tokens on every use (already enforced server-side).
- Call `/auth/revoke-sessions` if you suspect token compromise.
