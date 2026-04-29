# Releasing the appliance

This document is the source of truth for what happens between "merge a
change" and "operator runs `vibe upgrade`". There is one installer
release surface (`vibe-installer`) and five per-app surfaces (mybooks,
connect, tb, payroll, tax). Each has its own cadence; the cross-cutting
"a coordinated v1.x" releases land all of them on the same day.

> **History note (2026-04):** Pre-2026-04 there were three installer-side
> surfaces: `vibe-installer`, the `vibed` Go daemon binary, and the
> `Vibe-Admin` web UI image. Both `vibed` and `Vibe-Admin` were retired
> when the static operator panel on the landing page replaced the
> browser-based admin SPA. Their release flows are gone too — only
> `install.sh` is signed and attached to the GitHub Release now.

## Surfaces

| Surface | Repo | What ships | Where it lands |
|---|---|---|---|
| `install.sh` + `lib/` + `apps/*` (vendored compose + Caddy fragments) + `ingress/landing/*` | `vibe-installer` | install.sh, signed | GitHub Release `v*` |
| Per-app: MyBooks | `myBooks` | api + web + worker images | `ghcr.io/kisaesdevlab/vibe-mybooks-{api,web,worker}:<tag>` |
| Per-app: Connect | `Vibe-Connect` | app + nginx images | `ghcr.io/kisaesdevlab/vibe-connect{,-nginx}:<tag>` |
| Per-app: TB | `trial-balance-app` | api + web images | `ghcr.io/kisaesdevlab/vibe-tb-{api,web}:<tag>` |
| Per-app: Payroll | `Vibe-Payroll-Time` | api + web images | `ghcr.io/kisaesdevlab/vibe-payroll-{api,web}:<tag>` |
| Per-app: Tax | `Vibe-Tax-Research-Chat` | api + web images | `ghcr.io/kisaesdevlab/vibe-tax-{api,web}:<tag>` |

## vibe-installer release flow

`vibe-installer/.github/workflows/release.yml` triggers on `v*` tag
push and runs a single `sign-and-release` job:

- Cosign-signs `install.sh` with keyless OIDC.
- Hashes `install.sh` with `sha256sum`.
- Creates the GitHub Release with `install.sh` + its `.sha256` /
  `.sig` / `.crt`.

To cut a release:

```sh
cd ~/Projects/vibe-installer
git tag -a v1.16.0 -m 'v1.16.0'
git push origin v1.16.0
# CI takes ~30s; the release shows up at
#   https://github.com/KisaesDevLab/vibe-installer/releases/tag/v1.16.0
```

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
   runs `vibe upgrade <app> --to <version>` from the host. The
   landing page's operator panel surfaces the same command in a
   copy-pasteable snippet when an update is available.

## Coordinated release (cutting a v1.x of everything)

When the installer + a per-app fix need to ship together:

1. Tag the per-app repos. Each upstream's CI publishes its own image.
2. Re-vendor the per-app compose files in `vibe-installer` if any of
   them changed shape (entrypoint, mounted paths, ports).
3. Tag `vibe-installer` last. The vendored composes pointing at the
   new images go out alongside the signed `install.sh`.

Operators on existing hosts get the new versions by re-running
`install.sh` (re-renders the env templates) or by running
`vibe upgrade <app> --to <new-version>` directly. The landing page's
update badges + operator-panel snippets reflect the new state on the
next daily `vibe-upgrade-check.timer` run (or sooner with
`sudo vibe ingress refresh-updates`).

## Rolling back

`vibe upgrade <app> --to <previous-version>` from the host downgrades
a product app. There's no automated rollback for the installer
itself — operators re-install the previous tag manually:

```sh
sudo VIBE_REF=v1.15.0 bash -c 'curl -fsSL https://raw.githubusercontent.com/KisaesDevLab/vibe-installer/v1.15.0/install.sh | bash'
```

Volume data is never touched by an installer downgrade; the host's
`/var/lib/vibe/<app>/` survives.
