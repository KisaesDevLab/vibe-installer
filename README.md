# vibe-installer

One-command installer for the Vibe product family — Vibe MyBooks, Vibe Connect,
Vibe TB, and Vibe Payroll Time — on a single Ubuntu 24.04 host.

Designed for non-technical CPA-firm IT operators. Works on:

- A **self-hosted appliance** — NucBox M6 (or similar) running Ubuntu Server 24.04 LTS.
- A **DigitalOcean droplet** — Ubuntu 24.04, 4 vCPU / 8 GB GP Premium Intel as the floor.

## Quick start

On a fresh Ubuntu 24.04 host:

```bash
curl -fsSL https://raw.githubusercontent.com/KisaesDevLab/vibe-installer/main/install.sh | sudo bash
```

The bootstrapper installs Docker (if missing), clones this repo to
`/opt/vibe-installer`, creates a system `vibe` user, and asks you two
questions:

1. **Hostname** the appliance answers to (e.g. `vibe.local` or `vibe.firm.com`).
2. **TLS strategy:**
   - `internal` — `caddy trust` + `vibe.local` for in-office LAN use.
   - `acme` — Let's Encrypt over HTTP-01 for a public FQDN.
   - `cf-tunnel` — Cloudflare Tunnel terminates TLS upstream.

Once it finishes, you have a `vibe` command:

```bash
sudo vibe doctor                  # green = host is ready
sudo vibe install mybooks         # add Vibe MyBooks
sudo vibe install connect         # auto-promotes to multi-app mode at /mybooks /connect
sudo vibe install tb
sudo vibe install payroll
sudo vibe install tax             # Vibe Tax Research Chat (CPA AI assistant)
```

## What gets installed where

| Path                    | Contents                                          |
|-------------------------|---------------------------------------------------|
| `/opt/vibe-installer/`  | This repo (the CLI lives at `bin/vibe`).          |
| `/usr/local/bin/vibe`   | Symlink to `bin/vibe` — the operator's entry point.|
| `/etc/vibe/vibe.conf`   | Mode + host + tls + installed-apps registry.      |
| `/etc/vibe/<app>/.env`  | Per-app secrets, mode 0600 (owned by `vibe`).     |
| `/var/lib/vibe/<app>/`  | Per-app data (Postgres, uploads, redis AOF).      |
| `/var/lib/vibe/.archive/` | Where uninstalled app data goes.                |
| `/var/log/vibe/`        | Installer + lifecycle logs.                       |

## Modes

- **Single-app mode** — One Vibe product per host. The app publishes its own
  ports directly. Simplest for a firm running just one product.
- **Multi-app mode** — Two or more products on the same host behind a shared
  Caddy ingress at `https://<host>/<app>/`. Automatically activated when you
  install a second app.

You don't pick the mode up front — `vibe install` promotes/demotes the host
as you add or remove apps. To force a switch (e.g. for testing):

```bash
sudo vibe mode multi   # or: single
```

## Unattended install

For provisioning runs (Ansible, cloud-init, etc.):

```bash
export VIBE_HOST=vibe.example.com
export VIBE_TLS_MODE=acme
export VIBE_ASSUME_YES=1
curl -fsSL https://raw.githubusercontent.com/KisaesDevLab/vibe-installer/main/install.sh | sudo -E bash

export VIBE_LICENSE_TOKEN_MYBOOKS="…"   # PR2+
sudo -E vibe install mybooks
```

## Updating

The installer is **manual-update only by design**. There is no background
timer pulling new images.

```bash
sudo vibe upgrade-check                  # list available newer minor versions
sudo vibe upgrade mybooks                # apply the latest minor of the major you're on
sudo vibe upgrade mybooks --to 1.4.3     # pin a specific version

# Update the installer itself:
sudo curl -fsSL https://raw.githubusercontent.com/KisaesDevLab/vibe-installer/main/install.sh | sudo bash
```

## Status

This repo is in active development. Track per-PR scope:

| PR | Status | Scope |
|----|--------|-------|
| 1  | landed | bootstrap + CLI skeleton (`status`, `doctor`, `mode`) |
| 2  | next   | `install mybooks` (single-app) |
| 3  | next   | ingress + Connect + multi-app promotion |
| 4  | next   | TB + Payroll |
| 5  | next   | upgrade / uninstall / archive |
| 6  | next   | Cloudflare Tunnel toggle |
| 7  | next   | GLM-OCR + Tailscale + admin tools |
| 8  | next   | Cosign-signed `install.sh`, v1.0.0 |

## Security model

- Per-app data isolation: each Vibe product has its own Postgres, Redis, and
  volumes. The shared ingress never touches DBs.
- License keys verified locally with RSA pubkeys fetched from
  `licensing.kisaes.com`. Secrets generated at install time, written to
  `/etc/vibe/<app>/.env` (mode 0600, owned by the `vibe` user). They are
  never committed to this repo.
- Cloudflare credentials, when used, are **the customer's** — the installer
  prompts for the firm's tunnel token; it never embeds any third-party
  credential.

## Source-of-truth references

- [`vibe-distribution-plan.md`](https://github.com/KisaesDevLab/vibe-installer/blob/main/docs/vibe-distribution-plan.md) — the architectural spec this installer implements.
- App repos (where the GHCR images come from):
  - `KisaesDevLab/vibe-mybooks`
  - `KisaesDevLab/vibe-connect`
  - `KisaesDevLab/trial-balance-app`
  - `KisaesDevLab/vibe-payroll-time`
  - `KisaesDevLab/Vibe-Tax-Research-Chat`

## License

MIT (this installer is glue — the Vibe products carry their own BSL 1.1 /
PolyForm licenses).
