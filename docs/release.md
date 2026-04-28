# Releasing the appliance

This document is the source of truth for what happens between "merge a
change" and "operator runs `vibe upgrade`". There are three independent
release surfaces — the vibe-installer itself, vibed (the daemon binary),
and vibe-admin (the web UI image) — and five per-app surfaces (mybooks,
connect, tb, payroll, tax). Each has its own cadence; the cross-cutting
"a coordinated v1.x" releases land all of them on the same day.

## Surfaces

| Surface | Repo | What ships | Where it lands |
|---|---|---|---|
| `install.sh` + `lib/` + `apps/*` (vendored compose + Caddy fragments) | `vibe-installer` | install.sh, signed | GitHub Release `v*` |
| `vibed` daemon binary | `vibe-installer/tools/vibed` | static binaries linux/{amd64,arm64} | Same GitHub Release |
| Vibe-Admin image | `Vibe-Admin` | multi-arch container image | `ghcr.io/kisaesdevlab/vibe-admin:<tag>` |
| Per-app: MyBooks | `myBooks` | api + web + worker images | `ghcr.io/kisaesdevlab/vibe-mybooks-{api,web,worker}:<tag>` |
| Per-app: Connect | `Vibe-Connect` | app + nginx images | `ghcr.io/kisaesdevlab/vibe-connect{,-nginx}:<tag>` |
| Per-app: TB | `trial-balance-app` | api + web images | `ghcr.io/kisaesdevlab/vibe-tb-{api,web}:<tag>` |
| Per-app: Payroll | `Vibe-Payroll-Time` | api + web images | `ghcr.io/kisaesdevlab/vibe-payroll-{api,web}:<tag>` |
| Per-app: Tax | `Vibe-Tax-Research-Chat` | api + web images | `ghcr.io/kisaesdevlab/vibe-tax-{api,web}:<tag>` |

## vibe-installer release flow

`vibe-installer/.github/workflows/release.yml` triggers on `v*` tag push
and runs two jobs:

1. **`build-vibed`** — cross-compiles `tools/vibed` for `linux/amd64` and
   `linux/arm64` in parallel. Static binaries (`CGO_ENABLED=0`),
   `-trimpath`, `-X main.VibedVersion=<tag>`. Uploaded as build
   artifacts.
2. **`sign-and-release`** — depends on `build-vibed`. Cosign-signs
   `install.sh` with keyless OIDC, hashes the binaries with `sha256sum`,
   creates the GitHub Release with all of: `install.sh`, its `.sha256`
   / `.sig` / `.crt`, and the two vibed binaries plus their `.sha256`
   files.

To cut a release:

```sh
cd ~/Projects/vibe-installer
git tag -a v1.8.0 -m 'v1.8.0'
git push origin v1.8.0
# CI takes ~3 min; the release shows up at
#   https://github.com/KisaesDevLab/vibe-installer/releases/tag/v1.8.0
```

`install.sh::ensure_vibed` matches the current host's `uname -m` to
the right binary URL automatically.

## Vibe-Admin release flow

`Vibe-Admin/.github/workflows/release.yml` triggers on `v*` tag push.
Single job:

- Buildx with QEMU sets up linux/arm64 emulation, then `docker
  build --platform=linux/amd64,linux/arm64 --push` writes a
  multi-arch manifest to GHCR. Tag pattern `<major>.<minor>.<patch>`,
  `<major>.<minor>`, plus `latest` on default branch.

To cut a release:

```sh
cd ~/Projects/Vibe-Admin
git tag -a v1.8.0 -m 'v1.8.0'
git push origin v1.8.0
# CI takes ~6-8 min (arm64 emulation is slow); pulls from
#   docker pull ghcr.io/kisaesdevlab/vibe-admin:1.8.0
```

The `vibe-installer` repo's `apps/admin/docker-compose.yml` reads the
tag from `${VERSION:-latest}`, so a coordinated release also bumps
the `VIBE_ADMIN_VERSION` env var in the installer's
`apps/admin/env.template` (auto-substituted into `/etc/vibe/admin/.env`
on first install) — or operators can pin manually with
`VIBE_ADMIN_VERSION=1.8.0 sudo vibe upgrade admin` once that subcommand
exists (currently install.sh re-renders the env file from template,
re-applying the new version on next bootstrap).

## Per-app release flow

Each product app owns its own GitHub release pipeline. The
`vibe-installer` consumes the published images via the vendored
`apps/<name>/docker-compose.yml`. To bump the installer to a new
upstream version:

1. The upstream cuts a release (their own CI).
2. The vibe-installer's vendored compose reads the image tag from
   `${VERSION:-latest}` (or the per-app equivalent —
   `VIBE_MYBOOKS_VERSION`, `IMAGE_TAG`, `VIBE_PAYROLL_VERSION`,
   etc.), so on a fresh install the operator gets the latest.
3. To pin to a specific upstream version after install: the operator
   runs `vibe upgrade <app> --to <version>` from the host, or the
   admin web UI's per-app version picker (Updates page).

## Per-app re-vendor checklist (Phase 2.4 changes pending publish)

The Rung 2 work in this repo introduced several upstream changes that
are still **pending GHCR re-publication**. Until the upstream tags ship
with these changes baked in, the installer's vendored composes work
against the published images but NOT with the post-Phase-2.4 SPA flows
the admin UI relies on.

Coordinator: track which upstream tags include each fix in the table
below. When a tag ships, the installer's vendored
`apps/<name>/docker-compose.yml` (and `caddy.fragment` if applicable)
should be re-vendored from the upstream's `docker-compose.prod.yml`.

| App | Pending change | Local branch | Upstream PR | First tag with fix |
|---|---|---|---|---|
| **mybooks** | `FirstRunSetupWizard.tsx` derives `/api/setup` from `import.meta.env.BASE_URL` | `fix/setup-wizard-base-path` | _push pending_ | _TODO_ |
| **connect** | New `infra/docker/docker-entrypoint.sh` runs `npx --no-install knex migrate:latest` before `node dist/index.js` | `fix/migrate-on-boot` | _push pending_ | _TODO_ |
| **tb** | _no upstream change required_ — fix lives entirely in `apps/tb/caddy.fragment` (already in this repo) | n/a | n/a | n/a |
| **payroll** | Frontend image switched from build-time `VITE_BASE_PATH`/`VITE_API_BASE_URL` baking to runtime sentinel substitution; `frontend/docker-entrypoint.d/40-base-path.sh` substitutes `/__VIBE_BASE_PATH__/` at container start; `nginx.conf` no longer relies on `__SPA_INDEX__` substitution | `refactor/runtime-base-path` | _push pending_ | _TODO_ |
| **tax** | New app, two upstream changes bundled on one branch: (1) `.github/workflows/release.yml` GHCR publish for vibe-tax-{api,web}; (2) runtime base-path conversion — `apps/web/vite.config.ts` sentinel, `docker-entrypoint.d/40-base-path.sh`, `apiUrl()` helper in `apps/web/src/lib/api.ts`, `BrowserRouter basename` from BASE_URL. Both changes required before `vibe install tax` can succeed | `feat/installer-readiness` | _push pending_ | _TODO_ |

### Pushing the branches + opening the PRs

The three branches are committed locally. To ship them:

```sh
# mybooks
git -C ~/Projects/myBooks push -u origin fix/setup-wizard-base-path
gh -R KisaesDevLab/Vibe-MyBooks pr create \
    --base main --head fix/setup-wizard-base-path \
    --title 'web: derive setup wizard URL from import.meta.env.BASE_URL' \
    --body 'See commit message. Fixes the multi-app first-install scenario where the wizard would 404 because the absolute /api/setup path is not routed by the vibe-installer Caddy ingress.'

# connect
git -C ~/Projects/Vibe-Connect push -u origin fix/migrate-on-boot
gh -R KisaesDevLab/Vibe-Connect pr create \
    --base main --head fix/migrate-on-boot \
    --title 'docker: run knex migrations before starting the server' \
    --body "See commit message. Fixes the \"Cannot reach the server\" InstallGate error on fresh installs."

# payroll
git -C ~/Projects/Vibe-Payroll-Time push -u origin refactor/runtime-base-path
gh -R KisaesDevLab/Vibe-Payroll-Time pr create \
    --base main --head refactor/runtime-base-path \
    --title 'frontend: switch base path from build-time bake to runtime sentinel' \
    --body 'See commit message. Same image now serves both single-app and multi-app modes — matches the mybooks/tb pattern.'

# tax
git -C ~/Projects/Vibe-Tax-Research-Chat push -u origin feat/installer-readiness
gh -R KisaesDevLab/Vibe-Tax-Research-Chat pr create \
    --base main --head feat/installer-readiness \
    --title 'installer-readiness: GHCR publish + runtime base-path' \
    --body 'See commit messages. Adds .github/workflows/release.yml that publishes vibe-tax-{api,web} to GHCR on tag, plus runtime base-path conversion (vite sentinel + nginx entrypoint + apiUrl helper + BrowserRouter basename). Required for the vibe-installer apps/tax stack to install in either single-app or multi-app mode.'
```

When a row's "First tag with fix" lands:

1. Bump the corresponding `VIBE_<APP>_VERSION` default in
   `apps/<name>/env.template` to the new tag.
2. Re-run a smoke test against a host running the bumped tag
   (`VIBE_SMOKE_APPS=<app> tests/smoke.sh`).
3. If the smoke passes, cross out the row above + cut a coordinated
   `v1.x` of the installer.
4. Operators get the new image automatically via the admin UI's
   Updates page (which polls `apps.upgrade.check` every 6 hours).

## Coordinated release (cutting a v1.x of everything)

When the installer + admin UI + a per-app fix all need to ship together:

1. Tag `vibe-admin` first. The image needs to be in GHCR before any
   installer that references it lands on a host.
2. Tag the per-app repos. Each upstream's CI publishes its own image.
3. Re-vendor the per-app compose files in `vibe-installer` if any of
   them changed shape (entrypoint, mounted paths, ports).
4. Tag `vibe-installer` last. install.sh's release-attached vibed
   binary + the vendored composes pointing at the new images go out
   together.

Operators on existing hosts get the new versions via:

- `vibed` itself: re-run `install.sh` on the host (or `sudo curl -fsSL
  .../<tag>/vibed-linux-amd64 -o /usr/local/bin/vibed && sudo
  systemctl restart vibed`).
- Admin app: `vibe upgrade admin` once that subcommand exists, or
  re-run `install.sh` (which re-renders the admin env file from the
  bumped `VIBE_ADMIN_VERSION`).
- Product apps: admin UI's Updates page → per-app Update button.

## Rolling back

`vibe upgrade <app> --to <previous-version>` from the host (or the
admin UI's Pin-to-version picker) downgrades a product app. There's
no automated rollback for the installer or vibed itself — operators
re-install the previous tag manually:

```sh
sudo VIBE_REF=v1.7.0 bash -c 'curl -fsSL https://raw.githubusercontent.com/KisaesDevLab/vibe-installer/v1.7.0/install.sh | bash'
```

Volume data is never touched by an installer downgrade; the host's
`/var/lib/vibe/<app>/` survives.
