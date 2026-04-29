# Changelog

## v1.15.0 — Unreleased (single-ingress cf-tunnel refactor)

### Changed — Cloudflare Tunnel is now per-ingress, not per-app

The previous model spun up one `cloudflared` container per installed
app, each with its own token. This shipped two production bugs in
`lib/ingress.sh::ingress_render_caddyfile` (cf-tunnel mode used a
different site-host scheme + needed an `auto_https off` directive that
Caddy rejected inside a site block) and made cf-tunnel mode untestable
end-to-end. The whole mode-branching renderer is now collapsed.

- **`lib/ingress.sh`** — `ingress_render_caddyfile` reduced from three
  TLS branches to two (`internal`/`cf-tunnel` share `tls internal`;
  `acme` overrides). Caddy serves HTTPS in every mode now; cloudflared
  connects to `caddy:443` with `noTLSVerify`, so cf-tunnel needs no
  scheme gymnastics. New `ingress_validate_caddyfile` runs `caddy
  validate` on every render before applying — both shipped cf-tunnel
  bugs would have tripped this. New `ingress_preview_caddyfile`
  renders + validates against a tmp dir without touching live config.
  `ingress_compose` auto-passes `--profile tunnel` when
  `tls_mode=cf-tunnel`.

- **`ingress/Caddyfile.template`** — dropped the dead
  `@@CF_TUNNEL_BLOCK@@` placeholder + the cf-tunnel-only second site
  block. Down from 5 placeholders to 4.

- **`ingress/docker-compose.yml`** — added a profile-gated
  `cloudflared` sidecar. One tunnel handles every installed app.
  Healthcheck probes the cloudflared `/ready` metrics endpoint so a
  revoked token surfaces as `Unhealthy` instead of a `Up` container
  with a dead tunnel.

- **`lib/cloudflare.sh`** — replaced per-app `attach`/`detach` with
  `set-token` / `clear` / `status` / `logs` operating on the
  ingress-level sidecar. The old verbs are kept as deprecated
  redirects.

- **`lib/apps.sh`** — `apps_install_{mybooks,connect,tb,payroll,tax}`
  no longer accept `--cloudflare-tunnel <token>` as a meaningful flag.
  `_apps_warn_deprecated_cf_flag` parses + warns + redirects to
  `vibe cloudflare set-token`.

- **`bin/vibe`** — new `ingress preview` subcommand. New
  `cloudflare {set-token,clear,status,logs}` subcommands; old
  `attach`/`detach` kept as deprecation shims.

- **`tools/vibed/handlers.go`** — `cloudflare.set_token` and
  `cloudflare.clear` RPC methods. `cloudflare.status` returns
  `{tls_mode, token_attached, redacted_token, sidecar_running, apps:[]}`.
  Old `cloudflare.attach`/`cloudflare.detach` and the `apps.install`
  `cloudflare_tunnel` field are kept as deprecated forwarders so a
  stale admin UI build doesn't crash.

- **`apps/{mybooks,payroll}/docker-compose.yml`** — vendored upstream
  `cloudflared` services kept verbatim (would otherwise diverge from
  upstream) but annotated as installer-no-op.

## v1.14.0 — Unreleased (5th app: Vibe Tax Research Chat)

### Added — fifth product app: `tax` (Vibe Tax Research Chat)

The first app to add a piece of infrastructure no other app uses today
(Redis 7 + BullMQ for the skills-sync + usage-rollup + backup queues),
and the first that hard-requires the operator's own Anthropic API key
(configured post-install via the admin UI, encrypted at rest using the
installer-generated MASTER_KEY).

- **`apps/tax/`** — five vendored files mirroring the payroll/mybooks
  shape:
  - `docker-compose.yml` — postgres + redis + api + web. Pulls
    `ghcr.io/kisaesdevlab/vibe-tax-{api,web}:${IMAGE_TAG}`. Web
    publishes :8082 in single-app standalone; multi-app overlay leaves
    the port bound but the shared Caddy ingress handles all real
    traffic over the internal `vibe_ingress` network.
  - `docker-compose.grouped.yml` — sets `VITE_BASE_PATH=/tax/` for the
    web container's runtime substitution hook + joins api+web to
    `vibe_ingress`. No bundled-Caddy disable needed (upstream compose
    doesn't ship one).
  - `caddy.fragment` — three handles: `/tax/health` →
    api/api/health, `/tax/api/*` → api:4000 (with X-Forwarded-Prefix),
    `/tax/*` → web:80 (note: web binds 80, not 8080 like payroll).
  - `env.template` — POSTGRES_PASSWORD + 32-byte hex MASTER_KEY +
    JWT_SECRET + JWT_REFRESH_SECRET + the standard distribution-mode
    + license + cloudflare slots.
  - `healthcheck.sh` — probes the shared ingress at `/tax/health`,
    falls back to the single-app published port (the dev-convenience
    path).

- **`lib/apps.sh`**:
  - `APPS_SUPPORTED` gains `tax`.
  - `apps_ensure_datadirs` provisions `/var/lib/vibe/tax/{postgres-data,redis-data,workspaces,attachments,backups}`
    with the right uids (postgres:70, redis:999, node:1000).
  - New `apps_install_tax` function — env render, `PUBLIC_BASE_URL`
    re-stamping per mode, GHCR-image-existence pre-check, image pull,
    stack up, 240s healthwait (longer than other apps because the api
    boots after a one-time skills-repo clone).
  - `apps_primary_service` returns `api` for tax.
  - `apps_version_key` returns `IMAGE_TAG` for tax (the upstream
    compose pins both api + web off the same env var; we keep that
    naming so re-vendoring stays a `cp` rather than a sed).

- **`lib/checks.sh::checks_app_http`** — adds a `tax` branch probing
  `http://127.0.0.1:${WEB_PUBLISH_PORT:-8082}/api/health` in single-app
  mode (multi-app uses the existing shared-ingress path).

- **`lib/update_check.sh::update_check_image`** — registers
  `kisaesdevlab/vibe-tax-api` so `vibe upgrade-check` queries GHCR for
  newer tags. Apps with paired api+web images poll just the api leg
  because the release workflow publishes both off the same git tag.

- **`tools/vibed/handlers.go::handleAppsList`** — `tax` added to the
  supported apps array surfaced over `apps.list` to the admin UI.

- **`bin/vibe`** + **`install.sh`** + **`README.md`** + landing page
  + `docs/release.md` — help text + per-app table + tile.

### Upstream prereqs (committed locally on branch `feat/installer-readiness`)

The vendored stack can't actually start until the upstream
`Vibe-Tax-Research-Chat` repo lands two changes:

- **GHCR publish workflow** (`.github/workflows/release.yml`) — a
  matrix that publishes `vibe-tax-api` and `vibe-tax-web` on push to
  main + tag pushes. Mirrors Vibe-Payroll-Time's CI publish job
  (lower-cased owner + docker/metadata-action's canonical tag set
  + buildx + GHA cache). amd64-only for now; the rationale for not
  spending the QEMU minutes on arm64 is the same as payroll's.

- **Runtime base-path conversion** so the `VITE_BASE_PATH=/tax/`
  override the grouped overlay sets actually does something:
  - `apps/web/vite.config.ts` — `base: '/__VIBE_BASE_PATH__/'` for
    builds, `'/'` for dev. No PWA manifest plugin (tax-chat has no
    manifest yet).
  - `apps/web/Dockerfile` — copies the entrypoint hook + chmods +
    strips CR.
  - `apps/web/docker-entrypoint.d/40-base-path.sh` — same shape as
    Vibe-Payroll-Time's hook (in fact derived line-for-line — keep
    them in sync).
  - `apps/web/src/main.tsx` — `BrowserRouter basename={BASE_URL.replace(/\/$/, '')}`
    so React Router routes resolve relative to the runtime prefix.
  - `apps/web/src/lib/api.ts` — exports a new `apiUrl(path)` helper
    that prepends `import.meta.env.BASE_URL` and strips a single
    leading slash. The internal `api()` wrapper now goes through it.
  - `apps/web/src/hooks/useChatStream.ts` — uses `apiUrl` for the
    SSE POST so streaming chat doesn't 404 in multi-app mode.
  - `apps/web/src/pages/admin/Usage.tsx` — the CSV-download anchor
    href is wrapped in `apiUrl(...)` (was the only raw `<a href="/api/...">`
    in the SPA).

Branch is committed locally; push command + PR boilerplate are in
`docs/release.md`.

### Notes — what's NOT done yet

- **No release.yml on the installer side** — tax doesn't change how
  the installer itself releases.
- **CI for tax-chat** — the upstream repo currently has no test or
  typecheck workflow. The release workflow added here builds + pushes
  unconditionally. That's intentional for the first cut (no false
  green from a missing test step); a typecheck/test job should land
  alongside the first release tag.
- **Cloudflare Tunnel sidecar** — not vendored. The installer's
  `--cloudflare-tunnel` flag accepts the token and writes it to the
  env file's `CLOUDFLARE_TUNNEL_TOKEN` slot, but until upstream
  publishes a sidecar service the token is consumed by no one.
  Operators wanting a tunnel today can use the host-level cloudflared
  via the integrations UI.
- **Smoke test** — `tests/smoke.sh` has no `tax` case. Add when
  prereq T-A's images are published so the smoke can actually pull
  them.

---

## v1.13.0 — Unreleased (multi-admin v0.3 — audit retention pruner + GLM-OCR UI)

### Added — GLM-OCR install UI

- **Three new vibed RPCs** in `tools/vibed/handlers.go`:
  `integrations.glm-ocr.install`, `integrations.glm-ocr.uninstall`,
  `integrations.glm-ocr.status`. Install + uninstall return a
  `job_id` and stream progress through the existing `jobs.stream`
  pattern. Status shells out to `docker inspect` for a fast
  `{installed, running, healthy, url}` probe — same shape +
  reasoning as `integrations.tailscale.status`.
- **`delete_cache` param on uninstall** (default `false`).
  vibed always sets `VIBE_ASSUME_YES=1`, which would have caused
  `glm_ocr_uninstall`'s "remove the multi-GB cache?" confirm to
  default-yes and silently nuke a cache the operator probably
  wanted to keep. The handler now sets exactly one of two new
  env vars (`VIBE_GLM_OCR_KEEP_CACHE=1` /
  `VIBE_GLM_OCR_DELETE_CACHE=1`) so the lib's decision is
  unambiguous from the UI side. `lib/glm_ocr.sh` honors them
  ahead of the interactive prompt; CLI behavior is unchanged for
  operators who don't set either.
- **Admin server allowlist** in `routes/rpc.ts` extended with
  the three new methods.
- **Real GLM-OCR card** on the Integrations page (replaces the
  earlier "CLI-only for now" placeholder). Status pill —
  green/healthy, amber/loading-model, gray/stopped or
  not-installed — plus install button or uninstall + cache-
  retention checkbox. The shared `JobLogPanel` streams the
  install job's output the same way it does for Tailscale; the
  shared in-flight job slot is fine because the host's flock
  serializes lifecycle ops anyway.

### Added — audit retention pruner (`Vibe-Admin` server)

- **`ADMIN_AUDIT_RETENTION_DAYS`** env var (default `365`, range
  `0..36500`). `0` disables the pruner — events grow forever, fine
  for very small deployments. Anything else is the maximum age in
  days for `admin_audit_events` rows.
- **`pruneOldAuditEvents(retentionDays)`** helper in
  `services/audit.ts` — single `DELETE WHERE created_at < cutoff`,
  served by the migration's `created_at` index. Returns the
  number of rows deleted so the background runner can log it.
- **`services/audit-pruner.ts`** — background daily prune job.
  Mirrors the `update-poller` pattern: 60s startup delay (so we
  don't burn a connection on a `DELETE` while the server is still
  serving its first requests), then 24h `setInterval`. Both
  timers are `unref`'d so they don't block process shutdown.
  Failure is non-fatal (logged + retried tomorrow). Started from
  `server.ts` next to `startUpdatePoller()`.
- **`/__vibe-boot.js`** now emits `auditRetentionDays` so the SPA
  can render a retention hint without a separate authed call.

### Added — `Vibe-Admin` web

- **Retention notice** on the AdminAudit page header: "Events
  older than N days are pruned automatically …". Hidden when
  retention is `0` (disabled).

### Changed — `vibe-installer`

- `apps/admin/env.template` gains an `ADMIN_AUDIT_RETENTION_DAYS=365`
  block at the bottom, with comments explaining the disable
  sentinel and the SOC-2 / payroll-audit rationale for the
  default. The admin compose's `env_file` directive picks the
  value up automatically — no compose change needed.

### Notes

- Daily cadence is the boring middle: the table grows on the
  order of tens of rows per day on a single-tenant appliance, so
  pruning more often is wasted work and pruning weekly doesn't
  save anything either.
- The pruner does not run `VACUUM`. Postgres' autovacuum already
  handles bloat, and a manual `VACUUM` would need higher
  privileges than the application role has.
- Email-based admin invitations + per-action permission tiers
  remain on the v0.4+ list — both need design work (SMTP for
  invites; a real permission model for tiers) that hasn't started.

---

## v1.12.0 — Unreleased (multi-admin v0.2 — audit viewer + super-admin password reset)

### Added — `Vibe-Admin` server

- **POST `/api/admins/:id/reset-password`** (super_admin only).
  Replaces a peer's password with one the super-admin chose, sets
  `must_change_password=true` so the peer is forced through the
  rotate-password screen on their next sign-in. Refuses self-reset
  with a 409 `self_reset` (use the existing `/api/install/rotate-password`
  flow for that). Audited as `admin.password_reset`.
- **GET `/api/admins/audit`** (super_admin only). Paginated,
  keyset-cursor on `created_at` — the SPA passes the last-seen
  event's timestamp as `?before=…` to fetch the next page;
  concurrent inserts during a long browse session don't shift
  entries the way offset pagination would. Optional `action` and
  `actor_username` filters. Joins to `admin_users` so the response
  includes `actor_username` and `target_username`; falls back to
  `details.username` rendering on the SPA when those joins return
  null (the FK is `ON DELETE SET NULL`, so deleted users still show
  up identifiably in old rows).

### Added — `Vibe-Admin` web

- **`<ResetPasswordModal>`** (private to `Admins.tsx`). Two-field
  form (new temp password + show/hide), client-side ≥12 chars
  guard, server-side strength gate. Per-row "Reset password" button
  on the Admins table next to "Delete" — visible only when the row
  isn't the operator's own (server enforces self-reset block too).
- **AdminAudit page** at `/admin/admins/audit`. Filter by action
  (dropdown of known values) + actor username (free text, commits
  on submit so typing doesn't refetch on every keystroke). Table
  with time / action pill / actor / target / IP / details. **"Load
  more"** uses TanStack Query's `useInfiniteQuery` with the
  cursor-based pager. Action pill is color-coded: green for login
  success, red for login failure, violet for admin management,
  amber for password rotations.
- **Audit log link** on the Admins page header (super_admin only)
  routes to `/admins/audit`.
- Read-only admins (`role === 'admin'`) navigating directly to
  `/admins/audit` see an explanatory "Restricted" card rather than
  a blank page or a confusing 403 — the `useInfiniteQuery` is
  `enabled: isSuper` so the page also doesn't generate 403 noise
  in the server logs.

### Changed

- `AuditAction` union (server + SPA) gains `admin.password_reset`.
- `Admins.tsx` reset-button styling: existing `btnGhostInline`
  vertical-padding bumped from 0 to 4px so the button sits at the
  same height as the danger button.

### Validation

- `bash -n` clean across all shell scripts.
- One TS import bug caught + fixed mid-build: the AdminAudit page
  initially imported `AdminUser` from `../state/auth`, but the
  type lives in `../api` (auth.ts only re-uses it). Fixed before
  saving.
- Walked through the keyset-pagination contract end-to-end:
  client → server has `?before=<iso-ts>` → server query has
  `WHERE created_at < before` → response's `has_more` based on
  `events.length === limit` → SPA's `getNextPageParam` returns the
  last event's `created_at` so the next call's `before` is
  monotonically older. The strict `<` comparison excludes the
  boundary event so we don't double-render it.
- Self-reset is blocked at the server (409 `self_reset`); SPA
  hides the Reset button on the operator's own row as UI hygiene.

### Deferred to v0.3

- Email invitation flow — still requires SMTP configuration the
  appliance doesn't have by default. Today's flow is "super-admin
  picks the password and shares out-of-band".
- Audit retention — events accumulate forever. Should add a
  configurable retention (e.g. 1 year) + a periodic cleanup job.
  Bounded today by Postgres disk capacity.
- Per-action permission tiers — today admin == super_admin for
  everything except admin management. Some operators may want
  "read-only" or "can-install-but-not-uninstall" tiers. Needs a
  real permission spec first.

## v1.11.0 — Unreleased (multi-admin v0.1 + upstream PR branches)

### Added — `Vibe-Admin`

- **Multi-admin support, v0.1.** Two roles (`super_admin` and `admin`)
  with the bootstrap admin auto-promoted to `super_admin` on
  migration. Subsequent admins default to `admin` and are creatable
  only by super-admins.
  - **Schema** — `apps/server/src/db/migrations/20260201000001_admin_roles_and_audit.js`
    adds the `admin_role` enum + `admin_users.role` column. Existing
    rows (the bootstrap admin from migration 20260101000001) are
    promoted to super-admin so a mid-version upgrade doesn't lock
    the operator out of admin management.
  - **`admin_audit_events` table** — append-only log keyed on
    `actor_user_id` + `target_user_id` + `action`. Both FKs nullable
    (failed-login events leave actor null when the supplied
    username doesn't match a row; deleted-user events lose the
    target reference via `ON DELETE SET NULL`). JSONB `details`
    column for action-specific payload.
  - **`/api/admins`** endpoints — `GET` (any signed-in admin),
    `POST` / `PATCH /:id` / `DELETE /:id` (super-admin only).
    Server enforces the gate via the new `requireSuperAdmin`
    middleware. DELETE refuses to delete self; both DELETE and
    role-change PATCH refuse to drop the last super-admin.
  - **`apps/server/src/services/audit.ts`** — `audit({action, actor,
    target, details, ip})` writer. Best-effort: a failed insert
    logs to stderr but doesn't propagate (we don't want a missing
    audit row to fail an otherwise-successful login). Login,
    logout, password rotation, admin create / delete /
    role-change events are all logged.
  - **Session schema** — `req.session.role` cached at sign-in for
    cheap per-request gating; refreshed on every `/api/auth/me`
    so a role change reaches the SPA on next focus refresh
    without forcing a re-sign-in.

### Added — `Vibe-Admin` web

- **Admins page** at `/admin/admins`. Visible to any signed-in
  admin (read-only); only super-admins see action controls
  (Create / role-dropdown / Delete). The role dropdown is rendered
  for every row except the operator's own (no self-demotion in
  v0.1) and demoting the last super-admin returns a server-side
  `last_super_admin` 409.
- **CreateAdminModal** — username + display name + initial password
  (server-side strength gate: ≥12 chars, etc.) + role picker.
  Show/Hide on the password field. New admin is forced through the
  existing rotate-password flow on first sign-in
  (`must_change_password=true`).
- **Layout nav** gains an **Admins** link, conditional on
  `user.role === 'super_admin'`. Read-only `admin` users don't see
  the link in the header but the route still resolves if they
  navigate there directly — the page renders the list but hides
  every action button. Belt-and-braces: server enforces the same
  gate at the route layer.
- **AdminUser** type extended with `role`. AuthContext threads it
  through so any component can do `user.role === 'super_admin'`
  checks.

### Deferred to v0.2

- Email-invitation flow (currently the super-admin picks an
  out-of-band initial password)
- Audit-log viewer page (rows are written today, no UI yet — query
  the DB or `journalctl` to inspect)
- Password reset by super-admin (today they delete + recreate the
  row)
- Role-aware lifecycle ops (e.g. "admin can install but not
  uninstall" — currently admin == super_admin for product-app
  lifecycle, only admin-management is gated)

### Upstream PR branches prepared (push pending)

Three local branches with the Phase 2.4-era changes — committed,
not yet pushed. `docs/release.md` has the exact `git push` +
`gh pr create` commands.

| Repo | Branch | SHA |
|---|---|---|
| `myBooks` | `fix/setup-wizard-base-path` | `aa68c17` |
| `Vibe-Connect` | `fix/migrate-on-boot` | `7ccc30c` |
| `Vibe-Payroll-Time` | `refactor/runtime-base-path` | `1e47b86` |

One license-header issue caught + fixed mid-build (Vibe-Payroll-Time
runs a pre-commit hook that requires PolyForm headers; the new
`frontend/docker-entrypoint.d/40-base-path.sh` was missing one and
the commit aborted; added the four-line header and re-committed).

### Validation

- `bash -n` clean across all shell scripts.
- Walked through the role-gate matrix: super_admin can do everything;
  admin can list but not mutate; signed-out users get 401 from every
  /api/admins call. `requireDashboardAccess` (the existing layer
  middleware) catches the 401 case before `requireSuperAdmin`
  fires; `requireSuperAdmin` then returns 403 for non-super_admins.
- Self-protection: DELETE /:id with `id == session.userId` returns
  409 `self_delete`; PATCH demoting the last super_admin returns
  409 `last_super_admin`. Both checked at server, with the SPA's
  Admins page hiding the buttons too as a UI nicety.
- Stale-session note: a super_admin who demotes themselves stays
  super_admin in their own session.role until /api/auth/me is
  re-fetched (which the AuthContext does on focus). The
  /api/admins router does an extra DB lookup per call as
  defense-in-depth.

## v1.10.0 — Unreleased (admin self-upgrade)

### Added — `vibe-installer`

- **`vibe upgrade admin [--to <ver>]`**. The system-installed admin
  app couldn't be bumped without re-running `install.sh` and
  hand-editing `/etc/vibe/admin/.env` first. The new path:
  - `lib/apps.sh::apps_upgrade_admin` — bumps `VERSION` in the env
    file, calls `apps_compose admin pull`, recreates containers,
    waits for health on the `admin` service. Mirrors `apps_upgrade`
    but bypasses `apps_is_supported` / `config_installed_has` since
    `admin` isn't a user-installable app.
  - `apps_upgrade` dispatches `app == "admin"` to the dedicated
    function. Other paths (install/uninstall) intentionally still
    reject `admin` — operators tear it down via direct
    `docker compose down` + `rm -rf /etc/vibe/admin/` if they ever
    want to.
  - `apps_primary_service` and `apps_version_key` gain `admin`
    cases (service name `admin`, version key `VERSION`).

### Added — `update_check`

- **Admin shows up in `vibe upgrade-check --json`** (and therefore
  in the admin UI's Updates page). New `_update_check_emit_app_json`
  helper factored out of `update_check_run_json` so the loop over
  installed apps + the always-emit-admin step share one code path.
  The admin entry is suppressed when `/etc/vibe/admin/.env` is
  missing (the operator never finished bootstrap).
- `update_check_image` gains `admin → kisaesdevlab/vibe-admin`.

### Added — `Vibe-Admin`

- **Updates page handles the admin row** with two affordances:
  - Friendly label: *"Vibe Admin (this dashboard)"* — distinguishes
    it from product apps so the operator notices the self-upgrade
    nature of the action.
  - **UX warning in the confirm modal** when `pending.app === "admin"`:
    "Upgrading the admin app restarts this dashboard. Your browser
    session will lose its connection to the streaming log panel for
    ~10–20 seconds while the new container starts. Refresh the page
    once it's back to re-attach."

### Validation

- `bash -n` clean across all shell scripts.
- Walked through the dispatch chain: `vibe upgrade admin --to 1.2.3`
  → `cmd_upgrade` → `with_lock apps_upgrade` → `apps_upgrade`
  detects `admin` → `apps_upgrade_admin` → `apps_compose admin pull`
  + `up -d` + `apps_wait_healthy admin admin 240`. Lock contract
  unchanged (admin upgrades serialize against any other vibe op
  via `/var/run/vibe.lock`).
- Self-upgrade caveat documented inline in `apps_upgrade_admin` and
  surfaced in the SPA modal: when triggered from the admin UI,
  the streaming log panel disconnects mid-flight. The operator
  refreshes once the new container is up and reconnects.

## v1.9.0 — Unreleased (shipping prep — release CI + Playwright smoke + runbook)

### Added — `vibe-installer`

- **`tools/vibed` cross-compile + release attach.**
  `.github/workflows/release.yml` gains a `build-vibed` matrix job that
  compiles vibed for `linux/amd64` + `linux/arm64` in parallel
  (`CGO_ENABLED=0`, `-trimpath`, `-X main.VibedVersion=<tag>`). Both
  binaries + their `.sha256` files attach to the GitHub Release
  alongside the existing cosign-signed `install.sh`. The
  `install.sh::ensure_vibed` step from Phase 2.1 already knows the
  download URL pattern; this is the producer side.
- **`docs/release.md`** — single-page release runbook covering all
  three release surfaces (vibe-installer, vibed, vibe-admin) plus the
  four per-app surfaces. Includes the **per-app re-vendor checklist**
  for the Phase 2.4-era upstream changes still pending GHCR
  re-publication (mybooks setup-wizard URL fix, connect migrate-on-
  boot entrypoint, payroll runtime base-path conversion).

### Added — `Vibe-Admin`

- **`.github/workflows/release.yml`** — on `v*` tag push, buildx +
  QEMU produces a multi-arch (`linux/amd64`, `linux/arm64`) image and
  pushes to `ghcr.io/kisaesdevlab/vibe-admin:<tag>`. Tag pattern via
  docker/metadata-action: `<major>.<minor>.<patch>`, `<major>.<minor>`,
  plus `latest` on the default branch. Layer cache reused across runs
  via the GHA cache backend (`type=gha`).
- **`.github/workflows/ci.yml`** — three jobs: `typecheck` (tsc
  --noEmit on both workspaces), `build` (full Vite + tsc emit so
  regressions that --noEmit silently passes get caught), and `e2e`
  (Playwright suite against a Postgres service container).
- **Playwright smoke suite** under `tests/e2e/`:
  - `playwright.config.ts` — boots `yarn workspace @vibe-admin/server
    start` via the `webServer` block; chromium-only project.
  - `tests/e2e/global-setup.ts` — drops + recreates the test
    database, runs knex migrations, drops the bootstrap-password file
    where `services/bootstrap.ts` will pick it up. Sets `VIBED_SOCKET`
    to a non-existent path so vibed-backed RPCs fail gracefully (the
    test rig doesn't run a daemon).
  - `tests/e2e/global-teardown.ts` — cleans up the temp dir.
  - `tests/e2e/auth.spec.ts` — first-sign-in-forces-rotation +
    second-sign-in-skips-rotation + bad-credentials-rejects.
  - `tests/e2e/dashboard.spec.ts` — dashboard renders core sections
    + nav links to Backups / Logs / Diagnostics / Updates /
    Integrations all reach a rendered page.
  - `tests/e2e/constants.ts` — shared username / bootstrap password /
    rotated password.
- **Root `package.json`** — `test:e2e` + `test:e2e:ui` scripts, dev
  deps on `@playwright/test`, `pg`, `@types/pg`, `@types/node`.
- **`README.md`** — local-run instructions for the e2e suite + CI
  pointer.

### Validation

- All shell scripts (`bash -n`) clean.
- YAML sanity: visual review (no python in the local env to round-trip
  through). Indentation + quoting verified by-eye against the
  GitHub Actions schema.
- Two scope decisions worth flagging:
  - **No vibed mocking in the e2e suite.** A fake-socket mock would
    let the dashboard tests assert RPC-driven flows (install /
    upgrade / restore), but it'd duplicate ~half of vibed's wire
    handling in test code. Current scope verifies the SPA renders
    + navigates correctly when the daemon is *unreachable* — which
    is itself a valuable graceful-degradation contract. RPC-driven
    flows live in `vibe-installer/tests/smoke.sh` (the droplet
    harness) where a real daemon + real apps run.
  - **No e2e for the bootstrap flow itself.** The first-time
    `install.sh` path produces the bootstrap password file by
    rendering it from the operator's interactive prompt; a full
    e2e would need to spawn the entire installer. The Playwright
    suite jumps in *after* that step by writing the bootstrap file
    in `global-setup.ts`. The droplet smoke covers the install.sh
    side end-to-end.

### What's still pending

- Per-app upstream re-publishes (tracked in `docs/release.md`'s
  re-vendor checklist).
- An admin-server `vibe upgrade admin` subcommand so operators can
  bump the admin image without re-running `install.sh`.

## v1.8.0 — Unreleased (operator gaps — Cloudflare UI + Tailscale onboarding)

### Added — `vibed`

- **`runVibeStreamWithEnv` / `runJobSubprocessWithEnv`** variants of
  the existing subprocess helpers. extraEnv is appended to
  `inheritedEnv()` (last-wins on duplicate keys), so handlers can
  inject per-call values like `TAILSCALE_AUTHKEY` without touching
  the daemon's global env (which would race across concurrent
  goroutines).
- **`integrations.tailscale.install`** RPC. Long-running, returns
  `{job_id}`. Threads `TAILSCALE_AUTHKEY=…` into the subprocess env
  so `lib/tailscale.sh`'s auth-key path fires (rather than the
  interactive browser-URL flow that wouldn't work from vibed's
  no-TTY subprocess). Auth-key is required at the RPC layer — without
  it the underlying CLI would skip enrollment silently.
- **`integrations.tailscale.uninstall`** RPC. Long-running, returns
  `{job_id}`. Maps to `vibe uninstall tailscale`.
- **`integrations.tailscale.status`** RPC. Fast probe — shells out to
  `tailscale status --self=true --peers=false --json` directly
  (rather than going through the vibe CLI's human output) and
  returns `{installed, authenticated, ip}`.
- **`cloudflare.status` rewritten** to return structured data
  (`{apps: [{app, attached, redacted_token}]}` for the no-arg shape,
  `{app, attached, redacted_token}` for the per-app shape). Reads
  `/etc/vibe/<app>/.env` directly via two new helpers — `readEnvVar`
  and `redactCloudflareToken` — so the SPA doesn't have to parse the
  human-formatted CLI output (which has shifted shape in past
  releases). Token redaction matches `lib/cloudflare.sh::cloudflare_redact`.

### Added — `Vibe-Admin` server

- Allowlist additions in `routes/rpc.ts`:
  `integrations.tailscale.{install,uninstall,status}`.

### Added — `Vibe-Admin` web

- **`<CloudflareAttachModal>`** — token-input dialog distinct from
  the destructive `ConfirmModal`. Show/Hide toggle on the password
  field; Enter submits when non-empty. Shows the env-file path the
  token will land in for transparency.
- **`<AppCard>`** extended with a Cloudflare state pill (when
  attached, hover surfaces the redacted token) and per-state action:
  `Attach tunnel` button → opens the new modal; `Detach tunnel`
  button → opens the standard ConfirmModal with a non-`uninstall`
  destructive variant.
- **Dashboard** runs a new `cloudflare.status` query (30s polling)
  and threads the per-app status into each `<AppCard>`. Attach is a
  one-shot RPC (no streaming); detach goes through the existing
  ConfirmModal pipeline. Errors surface as a dismissible inline
  banner (separate path from the streaming JobLogPanel since these
  RPCs don't return job IDs).
- **Integrations page** at `/admin/integrations`. Cards for
  Tailscale (full install/uninstall flow with auth-key input),
  GLM-OCR (CLI-only stub), and Admin tools (CLI-only stub). Same
  streaming `JobLogPanel` reuse as the dashboard's lifecycle ops.
- Layout header gains the **Integrations** nav link.

### Wire format

```
Browser ↔ /api/rpc                       (one-shot)
   method: "cloudflare.attach", params: { app: "mybooks", token: "..." }
   ⤷ {result: {raw: "..."}}

Browser ↔ /api/rpc                       (one-shot)
   method: "integrations.tailscale.status", params: {}
   ⤷ {result: {installed: true, authenticated: true, ip: "100.64.x.y"}}

Browser ↔ /api/rpc + /api/rpc/stream     (long-running)
   method: "integrations.tailscale.install", params: {auth_key: "tskey-..."}
   ⤷ {result: {job_id: "..."}}
   ⤷ jobs.stream NDJSON to follow output
```

### Validation

- All shell scripts (`bash -n`) clean. The Go diff compiles in my
  head — `os/exec` import added for the Tailscale status probe; the
  one new struct field (`tailscaleInstallParams`) follows the same
  pattern as `installParams`/`upgradeParams`.
- I can't `tsc --noEmit` Vibe-Admin in this environment without
  `yarn install`; the user can locally with the standard
  `cd Vibe-Admin && yarn install && yarn typecheck`.
- One bug caught + fixed mid-build: I initially returned a global
  `tailscaleInstall` global env var via `os.Setenv` from the handler
  goroutine, which would have raced with every other concurrent
  vibed subprocess. Caught it before commit and threaded through
  `runJobSubprocessWithEnv` instead.

### Deferred (still on the operator-gaps list)

- **Log-based anomaly summary** on the dashboard — needs a real
  spec for "what counts as anomalous" before we ship something
  noisy. Currently nothing.
- **Multi-admin support** — schema migration + role enum + audit
  log + invitation flow. Bigger architectural lift; punted to a
  dedicated turn.

## v1.7.0 — Unreleased (Rung 2 phase 2.6 — update notifier + version pin)

### Added — `vibe-installer`

- **`vibe upgrade-check --json`** flag. Emits a single JSON object
  consumed by vibed's `apps.upgrade.check` handler instead of the
  human-formatted table. New `update_check_run_json` in
  `lib/update_check.sh` produces:
  ```
  {"apps": [
    {"app": "mybooks", "current": "1.4.0", "latest": "1.5.2",
     "all_tags": ["1.4.0", "1.5.0", "1.5.2"],
     "status": "outdated",
     "recommended_command": "vibe upgrade mybooks --to 1.5.2"}
  ]}
  ```
  Status values: `outdated` | `current` | `unpinned` | `ahead` |
  `no-ghcr` | `offline` (in sync between bash and the Go consumer).

### Added — `vibed`

- **`apps.upgrade.check`** now returns structured data instead of raw
  text. Calls `vibe upgrade-check --json`, unmarshals the result, and
  passes through (with a server-side `checked_at` timestamp the SPA
  uses for "last checked X minutes ago"). Falls back to a `parse_error`
  + `raw` shape if the JSON regresses, so the SPA can still render
  *something* during a future schema mismatch.

### Added — `Vibe-Admin` server

- **Background update poller** (`services/update-poller.ts`). Runs
  every 6 hours, calls `apps.upgrade.check` via the daemon, caches
  the result in module-scoped memory. First poll fires 30 s after
  server start (lets vibed come up under systemd without a startup
  race). Failures don't lose the previous cache — they're recorded
  as `last_error` alongside the prior good `apps[]` so the UI can
  render "couldn't refresh — last good data is from 4 h ago".
- **`/api/updates`** endpoint. `GET` returns the cache; `POST
  /api/updates/refresh` forces an immediate poll (in-flight
  deduplication so two concurrent refresh calls share one upstream
  RPC). Both gated by the existing `requireDashboardAccess`
  middleware.

### Added — `Vibe-Admin` web

- **`<UpdateBanner>`** component. Renders only when at least one app
  has `status: "outdated"` in the cached snapshot. Single line at
  the top of the dashboard: "*Vibe MyBooks (1.4.0) → 1.5.2 is
  available · and 1 other · Review updates →*". Click routes to the
  Updates page.
- **Updates page** at `/admin/updates`. Per-app rows with current /
  latest version + status pill (six visual states matching the bash
  enum) + per-state actions:
  - `outdated` → "Update to <latest>" button
  - `unpinned` → "Pin to <latest>" button
  - any state with published tags → "Pin to version…" link opens a
    tag picker modal listing `all_tags` newest-first, with markers
    for `latest` and `currently pinned`
  - `current` / `ahead` / `offline` / `no-ghcr` render their pill
    only (no actionable button — the operator either has nothing
    to do or needs to fix something off-appliance first).
- **"Check now"** button at top of the page calls `/api/updates/refresh`.
- All upgrade dispatches reuse the existing `useJob` hook + streaming
  `JobLogPanel` from Phase 2.3, so progress streaming is identical to
  the dashboard's Update flow.
- Layout header gains the **Updates** nav link.

### Wire format

```
Browser ↔ /api/updates  (GET, JSON)
   {"apps": [{app, current, latest, all_tags, status,
              recommended_command}, ...],
    "checked_at": "2026-04-27T...",
    "last_error": null,
    "last_attempted_at": "2026-04-27T..."}
```

### Validation

- `bash -n` clean across all shell scripts.
- Walked through the upgrade-check JSON contract end-to-end:
  bash `update_check_run_json` → vibed `upgradeCheckResult` Go
  struct → admin server `UpdateCacheEntry` TS interface → SPA
  `UpgradeCheckApp` TS type. Field names + status enum aligned
  across all four hops.
- Two SPA bugs caught + fixed mid-build:
  1. `useUpdates` initially had `staleTime: 30s` AND `refetchInterval:
     60s`, which would have made every navigation to /updates trigger
     an extra fetch despite the polling. Reduced to `staleTime: 30s`
     only with the interval kicking the cache when needed.
  2. `<PinToVersionModal>` first sorted tags ascending (matching
     `sort -V` upstream), but the operator's mental model is
     "newest first". Reversed in the picker.

## v1.6.0 — Unreleased (Rung 2 phase 2.5 — logs tab + diagnostics export)

### Added — `vibed`

- **`apps.logs.tail`** streaming RPC. Spawns `vibe logs <app> [service]`
  per subscription (no job tracking — logs run indefinitely until the
  client disconnects). Each output line emitted as
  `{"event":"line","line":{"seq":<n>,"time":"...","text":"..."}}`,
  matching jobs.stream's wire shape so the SPA reuses the same renderer.
  `done` event includes `reason:"cancelled"` for client-disconnect vs.
  `exit_code` for natural exits.

### Added — `Vibe-Admin` server

- **`/api/diagnostics/download/:filename`** streaming endpoint. Mirrors
  the backups download pattern: regex-validated filename
  (`^diagnostics-[0-9TZ]+\.tar\.gz$`), `path.normalize` + `startsWith`
  defenses, file → response stream so multi-MB tarballs don't pin
  memory.
- `apps.logs.tail` added to `ALLOWED_STREAM_METHODS`.
- Auth gate factored into `requireDashboardAccess` middleware (extracted
  in 2.4) and applied to the new `/api/diagnostics` mount.

### Added — `Vibe-Admin` web

- **Logs page** at `/admin/logs`. App picker (dropdown of installed
  apps) + free-text Service field with per-app placeholder hints
  (e.g. `api · web · worker · db · redis · …` for mybooks). Tail
  starts automatically on app change; service filter applies on
  Tail-button submit. New **`useLogStream`** hook owns the streaming
  state with a circular buffer capped at 4000 lines so a chatty
  container can't OOM the SPA.
- **`<LogStreamPanel>`** terminal-style viewer. Same auto-scroll-to-
  bottom + sticky-detach behavior as `<JobLogPanel>`, distinct
  controls (Pause / Resume / Clear).
- **Diagnostics page** at `/admin/diagnostics`. One-button "Generate
  diagnostics tarball" → calls `diagnostics.export` RPC, surfaces a
  Download link (HTTP-streamed via the new server endpoint) and a
  `mailto:support@kisaes.com` link with subject + body pre-filled.
  Honest scope: nothing is uploaded automatically — the operator
  sends the file manually (matches the SCP-only-restore decision
  from Rung 2 phase 2.4: any data leaving the appliance does so on
  the operator's authority, not background-pushed).
- Layout header gains **Logs** and **Diagnostics** nav links. Routes
  registered in `App.tsx`.

### Validation

- `bash -n` clean across all shell scripts.
- Path-traversal walked through three diagnostics-download attack
  paths (encoded `..`, absolute paths, dotfiles); all rejected at the
  regex stage before `path.normalize`.
- Two SPA bugs caught + fixed mid-build:
  1. `useLogStream`'s start function would race if called twice in
     quick succession. Fixed by `abortRef.current?.abort()` upfront —
     same pattern as `useJob`.
  2. The first draft of the Logs page had `[app, service]` in the
     auto-subscribe `useEffect` dep list, which would tear down +
     restart the stream on every keystroke into the service field.
     Reduced to `[app]` only; service changes commit on form submit.

## v1.5.0 — Unreleased (Rung 2 phase 2.4 — backup browser + restore)

### Added — `vibe-installer`

- **`vibe restore <app> <tarball>`** CLI subcommand. Validates the tarball is a gzipped tar containing the expected `var/lib/vibe/<app>/` + `etc/vibe/<app>/` paths, takes a pre-restore safety archive of current state under `/var/lib/vibe/.archive/<app>-pre-restore-<ts>.tar.gz`, stops the app, wipes the current data + env, extracts the tarball at `/`, re-applies per-uid ownership for postgres/redis dirs, restarts the stack, waits for healthy. Rolls forward via the image's startup-time migrations (Drizzle / knex / `MIGRATE_ON_BOOT`); restoring NEWER backups onto OLDER images is not supported.
- **`/var/lib/vibe/.restore-drop/`** directory created at install time (mode 0700, owner `vibe:vibe`). Operators SCP cross-host backup tarballs here for the admin UI to pick up.

### Added — `vibed`

- **`apps.restore`** RPC (long-running, returns `{job_id}`). Validates the tarball path against an allowlist of trusted roots — `/var/lib/vibe/<app>/backups/` and `/var/lib/vibe/.restore-drop/` — before spawning the job. Rejects anything outside with an `errInvalidParams` so an attacker who hijacks an admin session can't trigger a restore from `/tmp/anything-i-want.tar.gz`.
- **`apps.backups.drop_list`** RPC. Lists `*.tar.gz` files in `/var/lib/vibe/.restore-drop/` for the admin UI's restore page.
- **`inheritedEnv()`** now sets `VIBE_ASSUME_YES=1` for every vibed-spawned subprocess. The daemon is the canonical "no human watching" caller — every `confirm()` prompt in `lib/*.sh` would otherwise deadlock on a missing TTY. The admin UI's modal collects operator consent before the RPC fires; the daemon just speaks to the CLI.

### Added — `Vibe-Admin`

- **`/api/backups/download/:app/:filename`** + **`/api/backups/drop/download/:filename`** streaming endpoints. Direct file → response stream so multi-GB tarballs don't pin memory. Path-traversal defense: `:app` must be one of the four supported app ids; local filenames must match `^snapshot-[0-9TZ]+\.tar\.gz$`; drop-dir filenames must match `^[A-Za-z0-9._-]+\.tar\.gz$` and the resolved path must stay under `/var/lib/vibe/.restore-drop/`.
- **Backups page** at `/admin/backups` (or `/backups` standalone). Sections:
  1. SCP-instructions panel — shows two copyable commands the operator runs in their workstation terminal: `scp my-backup.tar.gz USER@<host>:/tmp/` then `ssh USER@<host> 'sudo mv /tmp/... /var/lib/vibe/.restore-drop/ && sudo chown vibe:vibe ...'`. The `<host>` is filled in from `window.location.hostname`.
  2. Restore drop-dir contents — files appearing in `/var/lib/vibe/.restore-drop/` show up here within ~10 s of upload.
  3. Per-app local snapshots — what `vibe backup <app>` writes to `/var/lib/vibe/<app>/backups/`. One row per file with Download (HTTP) + Restore (RPC) buttons.
  4. Active job log panel (reused from Phase 2.3) — restore is just another long-running RPC.
- Restore confirmation modal requires the operator to type the app name (matches uninstall's safety bar). Streaming log shows the exact same output as `sudo vibe restore <app> <tarball>` would print on the host.
- Backups nav link in the layout header.

### Allowlist additions (admin server `/api/rpc`)

- `apps.restore` (long-running, returns `{job_id}`)
- `apps.backups.drop_list`

### Validation

- All shell scripts (`install.sh`, `bin/vibe`, `lib/*.sh`) clean under `bash -n`.
- Path-traversal tests (mental walk-through):
  - `apps.restore { tarball: "/etc/passwd" }` → rejected by `isAllowedRestoreSource` (not under any allowed root).
  - `GET /api/backups/download/mybooks/../../../etc/passwd` → rejected by `LOCAL_NAME_RE`.
  - `GET /api/backups/drop/download/..%2F..%2Fetc%2Fpasswd` → URL decoding happens before the regex match, then `path.normalize` defenses + the `startsWith` check catch it.

## v1.4.0 — Unreleased (Rung 2 phase 2.3 — lifecycle UI)

### Added — `Vibe-Admin`

- **Streaming RPC.** New `/api/rpc/stream` POST endpoint that proxies
  vibed's `jobs.stream` NDJSON to a fetch ReadableStream. Server-side
  uses an `AbortController` so a closed browser tab tears down the
  upstream daemon socket. The SPA's `streamRpc` helper splits the
  response into JSON messages with a `TextDecoder`-backed line buffer.
- **Lifecycle allowlist.** `apps.install`, `apps.uninstall`,
  `apps.upgrade`, `apps.backup`, `license.set`,
  `cloudflare.{attach,detach}`, `diagnostics.export` added to the
  one-shot RPC allowlist. `jobs.stream` is the only entry on the
  streaming allowlist for now.
- **Lifecycle UI.** New `useJob` hook tracks an in-flight job:
  kicks off the RPC, opens the stream, accumulates lines, surfaces
  terminal state. New `<AppCard>` replaces the read-only app card
  with Install / Open / Upgrade / Backup / Uninstall buttons (per
  installed state). New `<JobLogPanel>` renders the streaming log
  with auto-scroll-to-bottom (sticky unless the operator scrolls up)
  + state pill + Stop-watching / Close buttons. New `<ConfirmModal>`
  gates destructive actions; uninstall additionally requires the
  operator to type the app name.
- The dashboard owns a single `JobLogPanel` slot — the daemon
  serializes lifecycle ops via `flock(/var/run/vibe.lock)`, so only
  one job runs at a time, and we surface that to the UI by disabling
  every action button while a job is active.
- React Query invalidations on job success: the `apps.list`,
  `status.get`, `doctor.run`, and `fullHealth` queries refetch the
  moment the job ends, so cards flip state without waiting for the
  poll interval.

### Changed — `vibe-installer`

- `etc/systemd/system/vibed.service`: now runs as `root` (was `vibe`).
  `vibed` shells out to `vibe install <app>` etc., which call
  `require_root` because they need to chown per-app data dirs to
  specific uids (postgres uid 70, redis uid 999, vibe-user, etc.).
  Running the daemon as `vibe` would have made every lifecycle RPC
  fail with a permission error. Hardening directives stay
  (`ProtectSystem=strict`, `ReadOnlyPaths=/opt/vibe-installer`,
  `PrivateTmp`, no kernel-tunable / module access). `/etc/vibe` was
  added to `ReadWritePaths` so `secrets_set` / `config_set` writes
  succeed under the namespace restriction.
- `NoNewPrivileges=true` removed (would block any future sudo path
  if we choose to walk back the root daemon for hardening).

### Known limitations

- Cloudflare attach / detach UI deferred to a follow-up — buttons not
  yet exposed in the AppCard. The RPC methods are allow-listed and
  the operator can still drive them via the CLI.
- Restore from backup is Phase 2.4; today the dashboard shows the
  list of backups (Phase 2.4) but doesn't expose a Restore button.
- Logs tab is Phase 2.5.

## v1.3.0 — Unreleased (Rung 2 phase 2.2 — admin web UI bootstrap)

### Added — `Vibe-Admin` (new repo)

- New repo `KisaesDevLab/Vibe-Admin` (yarn workspaces, Express server +
  React SPA, single image). Provides the `/admin/` web UI mounted by the
  installer's Caddy ingress. Speaks JSON-RPC to `vibed` for every
  product-management call; auth + session live in the admin server.
- Server: knex migrations on boot via the docker entrypoint (matches
  the Connect/TB pattern); express-session + connect-pg-simple +
  bcryptjs; `/api/auth/{login,logout,me}`; `/api/install/rotate-password`
  (force-rotate flow); `/api/rpc` JSON-RPC proxy with allowlisted
  methods; `/__vibe-boot.js` runtime config (matches Connect's pattern
  so a single image serves single-app `/` and multi-app `/admin/`
  prefixes with no rebuild).
- Web: React + Vite + TanStack Query SPA with three pages — Login,
  RotatePassword (forced on first sign-in), Dashboard. Dashboard polls
  health, status, apps.list, doctor.run as a read-only view. Lifecycle
  buttons (install/uninstall/upgrade/backup/restore/logs) land in
  Phases 2.3–2.6.
- First-run bootstrap: a `services/bootstrap.ts` step runs at server
  start. If `admin_users` is empty, reads the cleartext password
  `install.sh` dropped at `/etc/vibe/admin/admin-bootstrap.password`,
  bcrypts it, inserts the SuperAdmin row with `must_change_password=
  true`, deletes the file. The rotate-password endpoint deletes the
  operator-readable copy at `/var/log/vibe/admin-initial-password.txt`
  once the operator finishes the flow.
- Single image (`ghcr.io/kisaesdevlab/vibe-admin`) serves both the
  Express API and the SPA static bundle from the same Express
  instance.

### Changed — `vibe-installer`

- `install.sh::ensure_admin` runs after `ensure_vibed`. Mints a random
  initial admin password + session secret + Postgres password,
  renders `/etc/vibe/admin/.env`, drops the bootstrap-password file,
  brings up the admin compose stack with the multi-app overlay, and
  reloads the Caddy ingress.
- `install.sh::print_next_steps` now leads with the admin URL +
  username + password (also written to `/var/log/vibe/admin-initial-
  password.txt`, mode 0600 root-only).
- `lib/ingress.sh::ingress_render_caddyfile` always concatenates
  `apps/admin/caddy.fragment` regardless of the `installed=` list,
  since admin is a system app, not user-installable.
- New vendored stack: `apps/admin/{docker-compose.yml, docker-compose.
  grouped.yml, env.template, caddy.fragment, healthcheck.sh}`.

### Known limitations (Phase 2.2)

- Dashboard is read-only — install / uninstall / upgrade buttons are
  Phase 2.3 work.
- No backup browser yet (Phase 2.4) — operators still run `sudo vibe
  backup <app>` on the host.
- No log viewer or diagnostics export button (Phase 2.5).
- No update notifier (Phase 2.6).
- The admin app shares the host's `vibe_ingress` Docker network with
  the four product apps. WebAuthn / passkey support deferred to a
  future Rung-2 phase; v0.1 is password-only.

## v1.2.0 — Unreleased (per-app first-run UX fixes + Rung 2 phase 2.1 daemon)

### Per-app upstream changes (re-vendor required after each ships)

- **Vibe MyBooks**: `FirstRunSetupWizard.tsx` now derives its `/api/setup` URL from `${import.meta.env.BASE_URL}api/setup` instead of a hardcoded literal, so the install wizard works in both single-app (`/api/setup`) and multi-app (`/<prefix>/api/setup`) shapes. Previously the second-app multi-app install scenario would land on a Caddy 404 because the wizard's absolute path wasn't routed.
- **Vibe Connect**: new `infra/docker/docker-entrypoint.sh` runs `npx --no-install knex migrate:latest` before starting the server. Cures the "Can't reach the server" screen on first install (the SPA polled `/install/status` against an unmigrated `firm_keys` table). Idempotent; `restart: unless-stopped` re-tries on migration failure.
- **Vibe Payroll Time**: switched the frontend image from build-time `VITE_BASE_PATH` / `VITE_API_BASE_URL` baking to runtime sentinel substitution (matches MyBooks/TB pattern). Same image now serves both single-app and multi-app — no `dist-prefixed/<prefix>/` relocation, no separate GHCR builds. New `frontend/docker-entrypoint.d/40-base-path.sh` substitutes `/__VIBE_BASE_PATH__/` across html/js/css/json/map/webmanifest at container start. `frontend/src/lib/{api,clock-skew,kiosk-api,resources}.ts` derive `API_BASE` from `${import.meta.env.BASE_URL}api/v1` instead of `VITE_API_BASE_URL`.

### vibe-installer

- **`apps/payroll/caddy.fragment`**: port `:80` → `:8080` (the upstream web image listens on 8080, not 80). Added `handle_path /payroll/api/*` that bypasses web for API traffic — matches the new Caddy-strips-prefix routing model. `X-Forwarded-Prefix /payroll` so the api emits prefix-aware absolute URLs.
- **`apps/tb/caddy.fragment`**: dropped the spurious `rewrite * /tb{uri}` that was forcing the upstream web nginx to handle prefixed paths it doesn't have rules for. Caddy now strips `/tb/` and forwards unprefixed; web nginx serves `/api/`, `/assets/`, etc. as designed. The four nginx special-case routes (backup / restore / import / support-chat) and the MCP route are duplicated into Caddy with their long-timeout / SSE / body-size overrides preserved.
- **`apps/mybooks/caddy.fragment`**: bypass web for both `/api/*` and `/oauth/*` so the install wizard's `${BASE_URL}api/setup/*` calls reach the api directly. Stale comment about "VITE_BASE_URL=/mybooks/" replaced — mybooks uses runtime sentinel substitution, not build-time URL baking.
- **`apps/payroll/docker-compose.grouped.yml`**: sets `VITE_BASE_PATH=/payroll/` as a runtime env var on the web service so the new entrypoint hook substitutes the sentinel correctly.

### Rung 2 phase 2.1 — `vibed` daemon

- New `tools/vibed/` Go module (~950 LoC, stdlib only). Long-running daemon that exposes the existing `vibe` CLI as a JSON-RPC API over `/run/vibed.sock` (mode 0660, group `vibe`). The existing CLI keeps working unchanged; the upcoming admin web app speaks JSON-RPC to the daemon.
- RPC method index in `tools/vibed/README.md`. `apps.install`, `apps.upgrade`, `apps.uninstall`, `apps.backup` return job IDs; clients poll `jobs.status` or subscribe via `jobs.stream` for live output.
- Systemd unit at `etc/systemd/system/vibed.service` (Type=simple, runs as `vibe` user, hardened with `ProtectSystem=strict` + read-only mounts of `/etc/vibe` + `/opt/vibe-installer`).
- `install.sh::ensure_vibed` downloads the binary from GitHub releases (matching `VIBE_REF`) or falls back to a locally-built binary at `tools/vibed/vibed`. Installs the systemd unit even when the binary is missing, with a clear "build me" hint.

### Known limitations

- `vibed` doesn't yet plumb daemon-shutdown cancellation into in-flight jobs — a `systemctl stop vibed` mid-install leaves the subprocess running orphaned. Operator can `docker compose down` manually. Fix planned for Phase 2.2.
- Restore RPC (`apps.restore`) deferred to Phase 2.4.
- `apps.logs.tail` streaming RPC deferred to Phase 2.5.

## v1.1.0 — Unreleased (Rung 1: install-flow polish)

### Changed

- **Always-multi-app deployment.** `install.sh` now brings up the Caddy ingress at `:80/:443` immediately after bootstrap, even with zero apps installed. The first app installs at `https://<host>/<app>/`, every subsequent app installs at the same shape, and removing apps never tears the ingress down. URLs are stable from the first browser visit forward — adding a second app no longer flips modes or invalidates bookmarks. The `mode=single` shape is preserved only as a developer convenience (`docker compose -f apps/<app>/docker-compose.yml up -d` still publishes per-app ports, since the grouped overlay isn't layered).
- **Intent-based TLS prompt.** `install.sh`'s "internal / acme / cf-tunnel" choice is replaced with three operator-facing questions ("Will this be reachable from outside your office?", inline domain + email collection for ACME, inline tunnel-token paste for Cloudflare). The token is stashed at `/etc/vibe/cloudflared/tunnel.token` (mode 0600, owner `vibe:vibe`) and consumed automatically by the next `vibe install <app>` so the operator only enters it once.
- **IP-fallback URL** printed alongside the `https://<host>/` URL at the end of `install.sh`. Cures the silent failure on Windows-only LANs that don't resolve `.local` hostnames out of the box.
- **Landing page** now shows the URL the operator should bookmark / share, with a soft mDNS warning when the host is `.local`.
- **Legacy mode=single migration.** Existing installs are auto-detected at the next root `vibe` invocation and walked through the same `mode_promote_to_multi` machinery the legacy 1→2 promotion used. URLs change from per-app ports to `https://<host>/<app>/` once; bookmarks need updating.

### Added

- `vibe.conf::acme_email` — persisted ACME contact (set by the install-time prompt; written into the ingress envfile by `lib/ingress.sh`).
- `lib/cloudflare.sh::cloudflare_read_stashed_token` / `cloudflare_clear_stashed_token` — single-use consumption of the stashed tunnel token by per-app installers.
- `lib/mode.sh::mode_migrate_to_always_multi` — auto-runs at every root invocation of `vibe`; idempotent and silent on non-legacy configs.

## v1.0.0 — Unreleased

### Added

- **One-shot host bootstrap** (`install.sh`) — verifies host (Ubuntu 24.04, ≥4 GB RAM, ≥20 GB free), installs Docker, clones the installer to `/opt/vibe-installer`, creates a `vibe` system user + `/etc/vibe`, `/var/lib/vibe`, `/var/log/vibe`, creates the `vibe_ingress` Docker network, and writes `/etc/vibe/vibe.conf` from interactive (or env-driven) operator input.
- **`vibe` CLI** at `/usr/local/bin/vibe`. Commands:
  - Inspection: `status`, `doctor`, `mode`, `version`.
  - Lifecycle: `install <app>`, `uninstall <app>` / `--all`, `upgrade <app> [--to VER]`, `upgrade-check` (read-only).
  - Operational: `logs <app> [service]`, `exec <app> <svc> <cmd>`, `backup <app>`.
  - Auth & secrets: `license set <app> <token>`, `cloudflare {attach|detach|status} <app>`.
- **Vibe apps installable as single-app or multi-app**:
  - `mybooks` (Vibe MyBooks) — Postgres + Redis + api + web + worker.
  - `connect` (Vibe Connect) — Postgres + app + nginx (subject to upstream prereq P-B).
  - `tb` (Vibe Trial Balance) — Postgres + api + web (nginx).
  - `payroll` (Vibe Payroll Time) — Postgres + api + web; bundled Caddy disabled in multi-app mode (subject to upstream prereq P-A).
- **Multi-app mode**: shared **Caddy 2 ingress** at `https://<host>/<app>/`. Cookies, ports, and DBs stay isolated. Auto-promotes from single-app on the second `vibe install`; auto-demotes on the second-to-last `vibe uninstall` (with confirm).
- **TLS strategy** chosen at bootstrap and persisted to `vibe.conf` as `tls_mode`:
  - `internal` — Caddy `tls internal` + `caddy trust` for LAN/mDNS hosts.
  - `acme` — Caddy ACME HTTP-01 on :80 for public FQDNs.
  - `cf-tunnel` — Cloudflare Tunnel terminates TLS; Caddy stays plain HTTP.
- **Per-product license activation flow** (`lib/license.sh`):
  - Per-app pubkey fetched from `licensing.kisaes.com/v1/public-key?app=<app>` (24h cache).
  - Token order: `VIBE_LICENSE_TOKEN_<APP>` env > interactive prompt > 30-day trial.
- **Cloudflare Tunnel toggle** — `vibe install <app> --cloudflare-tunnel <token>` and `vibe cloudflare {attach|detach|status} <app>`. Customer-owned token; never logged in plaintext.
- **Optional integrations**:
  - `vibe install glm-ocr` — local OCR appliance, joins `vibe_ingress` as `vibe-glm-ocr:8090`.
  - `vibe install tailscale` — installs the Tailscale CLI and runs the 10-min `timeout 600 tailscale up` flow (lifted from `Vibe-Linux-Setup/provision.sh`).
  - `vibe install tools` — Portainer + Duplicati on a separate `vibe_admin` network, bound to `127.0.0.1` only.
- **Idempotence + rollback**: every state-mutating action wrapped in `flock /var/run/vibe.lock`; `/etc/vibe/vibe.conf` snapshotted before each operation and restored on failure. Volumes never touched by rollback.
- **Cosign-signed `install.sh`** at release time, with verification snippet in the release notes (no auto-update timer — manual update by design).

### Prerequisites tracked in upstream app repos

- **P-A** — `Vibe-Payroll-Time` must publish `vibe-payroll-{api,web}` to GHCR before `vibe install payroll` can succeed. The installer aborts with a clear message if `docker manifest inspect` doesn't find the image.
- **P-B** — `Vibe-Connect` should drop the `vibe-connect-nginx` image and rename `vibe-connect-app` → `vibe-connect`. The installer's Connect compose still expects nginx pending that change.
- **P-C** — Resolved upstream. `Vibe-MyBooks` `packages/web/` now uses the same runtime sentinel-substitution pattern as Vibe TB: Vite builds with `base: '/__VIBE_BASE_PATH__/'`, and `packages/web/docker-entrypoint.d/40-base-path.sh` rewrites the sentinel from `VITE_BASE_PATH` at container start. One image, every prefix — no local rebuild required for multi-app mode. Once a new MyBooks GHCR image is published with this change, the installer's vendored compose just works; no installer-side change beyond the compose re-vendor.

### Known caveats (operator-facing)

- **TB multi-app** is supported by upstream. TB's `client/vite.config.ts` uses the same `'/__VIBE_BASE_PATH__/'` sentinel and `deploy/web-entrypoint.sh` substitutes it at start. Verify on first promote.
- **`vibe install tailscale`** enrolls only the **host's** Tailscale CLI. MyBooks ships its own `tailscale` sidecar in its compose; to enroll that sidecar set `TS_AUTHKEY=…` in `/etc/vibe/mybooks/.env` and run `vibe upgrade mybooks` to pick up the change.

### Known limitations (v1.0.0)

- **WebAuthn `rpId` is shared in multi-app mode.** A passkey registered for one app under the same `<host>` is technically usable on sibling apps. Documented; mitigation (subdomain per app) deferred to v1.1.
- **`vibe rotate-secrets <app>`** is not implemented in v1.0.0; planned for v1.1.
- **Backup orchestration** (off-host replication) is the operator's job via Duplicati's UI; the installer only takes local snapshots.
