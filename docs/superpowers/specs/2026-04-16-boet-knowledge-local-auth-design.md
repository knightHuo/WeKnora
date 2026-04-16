# BOET Knowledge Local Auth Integration Design

## Goal

Build a local, LAN-testable integration path where Beijing Lanhai Zhixin Energy Technology Co., Ltd. (BOET) can validate authentication, token issuance, and protected knowledge-base access before moving the same architecture to a cloud server.

The knowledge-base product/module name is **BOET 智库**.

## Confirmed Direction

Use a staged, low-risk rollout:

1. Start with account/password login.
2. Add SMS login after the account/password flow is stable.
3. Add WeChat login after SMS is stable.
4. Reuse the existing WeKnora frontend with light BOET branding changes instead of a major rewrite.
5. Keep the local setup easy to migrate to a cloud deployment later.

## Architecture

The local test environment has five runtime units:

1. **Nacos**
   - Runs locally from `C:\Users\46044\Downloads\nacos-server-2.4.0.1\nacos`.
   - Stores `kernel-security` configuration.
   - Should stay local-only during LAN testing unless there is a specific reason to expose the management UI.

2. **PostgreSQL**
   - Use a new dedicated local test database for `kernel-security`.
   - Do not mix auth test data with existing WeKnora or other local business databases.
   - The database stores OAuth2/OIDC tables, user data, and account binding data required by the chosen login method.

3. **kernel-security**
   - Runs as the authentication center.
   - Runnable module: `D:\CloudPilot\kernel-security\kernel-security-spring-boot-starter`.
   - Main class: `com.boet.security.starter.AuthApplication`.
   - Local default port: `2010`.
   - Provides:
     - OIDC discovery: `/.well-known/openid-configuration`
     - JWKS: `/oauth2/jwks`
     - Token endpoint: `/oauth2/token`
   - First-stage login target: account/password.

4. **WeKnora-Knowledge-Service**
   - Runs as the independent knowledge-base service.
   - Current local path: `D:\CloudPilot\WeKnora-Knowledge-Service`.
   - Switch from `AUTH_MODE=dev` to `AUTH_MODE=jwks` once `kernel-security` is stable.
   - Prefer `OIDC_DISCOVERY_URL=http://<local-lan-host>:2010/.well-known/openid-configuration` so JWKS and issuer information come from discovery.

5. **WeKnora main service and frontend**
   - Keep usable in the first stage.
   - Make only the minimum changes required for auth integration and LAN testing.
   - Longer-term, split or replace parts gradually after the auth and knowledge boundaries are stable.

## Data Design

Create a dedicated local PostgreSQL test database for `kernel-security`.

Required data areas:

1. OAuth2/OIDC infrastructure tables
   - Registered clients
   - Authorizations
   - Authorization consent
   - Any token/session persistence required by Spring Authorization Server

2. User profile tables
   - Tables expected by `kernel-security-userdetails` mappers.
   - Seed at least one local test user for account/password validation.

3. Account/password tables
   - Use the table names and fields expected by existing `kernel-security` code and mappers.
   - If the current password resolver is incomplete, implement or minimally patch the resolver so the first test user can authenticate.

4. SMS and WeChat tables
   - Create or defer based on whether those modules are hard startup dependencies.
   - Functional SMS and WeChat flows are out of the first implementation stage, but schema dependencies that block startup should be satisfied.

## Nacos Design

Use the local Nacos instance as the configuration source for `kernel-security`.

Required first-stage configuration:

1. Create the `dev` namespace.
2. Add the datasource config currently imported by `kernel-security`:
   - `pgdatasource.yml`
3. Add other required imported configs if startup needs them:
   - `public.yml`
   - `redis_ylh.yml`
   - `sms.yml`
   - `wechat.yml`
   - `system-file-route.yml`
   - `auth-service.yml`

Keep sensitive values in local Nacos and do not commit database passwords into the repository.

## LAN Testing Design

Expose only the service ports needed for coworkers to complete the test.

Expose to LAN:

1. `kernel-security` on port `2010`
   - Required for login, token acquisition, discovery, and JWKS.

2. `WeKnora-Knowledge-Service` on port `8090`
   - Required for protected knowledge-base API validation.

3. WeKnora frontend/API ports only if the browser path needs them
   - Current known frontend: `3000`
   - Current known API: `8088`

Do not expose by default:

1. PostgreSQL
2. Nacos management/API
3. Maven/Nexus credentials or local repository paths

## Test Paths

Support both browser and API testing.

### Browser Path

1. Coworker opens the LAN frontend URL.
2. Frontend shows BOET branding and login entry.
3. User logs in through `kernel-security`.
4. Frontend stores or forwards the token according to the current frontend integration pattern.
5. User accesses knowledge-base features.
6. Protected calls include `Authorization: Bearer <jwt>`.

### API Path

1. Coworker calls `kernel-security` token endpoint with account/password credentials.
2. Coworker copies the returned access token.
3. Coworker calls `WeKnora-Knowledge-Service` with `Authorization: Bearer <jwt>`.
4. Knowledge service validates the token through JWKS/discovery and proxies to WeKnora using its internal API key.

## Frontend Branding Design

Use light customization instead of rebuilding the frontend.

Product/module name:

- `BOET 智库`

Company name:

- `北京蓝海智信能源技术有限公司`

Frontend changes:

1. Replace visible WeKnora product references where appropriate with `BOET 智库`.
2. Add or replace company display text with `北京蓝海智信能源技术有限公司`.
3. Replace logo assets with BOET branding when available.
4. Hide or remove links that should not appear in internal/external tests:
   - Official website links
   - GitHub links
   - Other upstream project promotional links
5. Keep layout, navigation, and core interactions mostly unchanged.

This avoids a large frontend rewrite while still making the test environment feel like a BOET product.

## WeKnora Evolution Path

Do not rewrite WeKnora immediately.

Recommended sequence:

1. Keep existing WeKnora main service and frontend working.
2. Stabilize external auth through `kernel-security`.
3. Stabilize the independent knowledge service boundary.
4. Gradually split or replace larger WeKnora domains later, such as:
   - Tenant management
   - Model configuration
   - Conversation/session APIs
   - Workflow/agent features
   - Frontend shell and page-level IA
5. Move to cloud only after local LAN validation is repeatable.

## Acceptance Criteria

Stage 1 is complete when all of the following are true:

1. Local PostgreSQL has a dedicated `kernel-security` test database.
2. Required OAuth2/OIDC and user/account tables exist.
3. Local Nacos has a `dev` namespace and required config entries.
4. `kernel-security` starts reliably on port `2010`.
5. OIDC discovery returns a valid document.
6. JWKS returns RSA keys.
7. Account/password login can issue an access token.
8. `WeKnora-Knowledge-Service` runs in `AUTH_MODE=jwks`.
9. A real token from `kernel-security` can access at least one protected knowledge-service endpoint.
10. LAN coworkers can test through both browser and API paths.
11. Frontend displays `BOET 智库` and BOET company branding, with upstream promotional links removed or hidden.
12. A local test guide exists with URLs, test account, token command examples, and troubleshooting notes.

## Out of Scope For Stage 1

1. Production-grade cloud deployment.
2. Full frontend redesign.
3. Full WeKnora service rewrite.
4. SMS login functionality beyond startup/schema requirements.
5. WeChat login functionality beyond startup/schema requirements.
6. Exposing PostgreSQL or Nacos to LAN users.

## Risks And Mitigations

1. **Risk:** Existing account/password resolver may be incomplete.
   - **Mitigation:** Implement the minimum resolver behavior needed for a seeded local test user, with tests where practical.

2. **Risk:** Database schema may not be fully documented.
   - **Mitigation:** Prefer existing mapper XML and Spring Authorization Server schema; use startup/runtime errors to close any missing-table gaps.

3. **Risk:** LAN callbacks and issuer URLs may differ from localhost URLs.
   - **Mitigation:** Use a stable LAN host/IP in discovery-facing config before coworker testing.

4. **Risk:** Frontend auth expectations may differ from the token endpoint flow.
   - **Mitigation:** Keep API token testing as the fallback validation path while browser integration is adjusted.

5. **Risk:** Local setup could drift from future cloud setup.
   - **Mitigation:** Keep Nacos config, DB schema, and startup commands documented in the local test guide.

