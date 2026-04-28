# vibed

Long-running daemon that wraps the existing `vibe` CLI as a JSON-RPC API
over a Unix socket. Two clients consume it:

- The existing `vibe` CLI keeps working unchanged (it talks to the same
  `/opt/vibe-installer/lib/*.sh` directly, not through vibed).
- The admin web app (`apps/admin` in this repo, source in
  `KisaesDevLab/Vibe-Admin`) speaks JSON-RPC over `/run/vibed.sock`.

## Build

```sh
cd tools/vibed
go build -ldflags "-X main.VibedVersion=$(git describe --tags --always)" -o vibed .
sudo install -m 0755 -o root -g root vibed /usr/local/bin/vibed
```

The release pipeline in `.github/workflows/release.yml` cross-compiles
for `linux/amd64` and `linux/arm64` and attaches the binaries to the
GitHub release.

## Install

`install.sh` does this for you:

```sh
sudo install -m 0755 vibed /usr/local/bin/vibed
sudo install -m 0644 etc/systemd/system/vibed.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vibed
```

The daemon listens on `/run/vibed.sock` (mode 0660, group `vibe`). Only
processes whose effective gid includes `vibe` can connect — that's the
admin app's container (which runs as `vibe:vibe`) and any operator who
runs `sudo` (root has access regardless of group).

## Wire format

JSON-RPC 2.0, framed as one JSON object per line ("\n" terminated).

```sh
# Quick sanity check from the host:
echo '{"jsonrpc":"2.0","id":1,"method":"vibed.ping"}' \
  | sudo -u vibe nc -U /run/vibed.sock
```

Long-running methods (`apps.install`, `apps.upgrade`, `apps.uninstall`,
`apps.backup`) return a `job_id` immediately. Call `jobs.status` for a
snapshot or `jobs.stream` to follow output as it's produced.

## RPC method index

| Method | Returns | Notes |
|---|---|---|
| `vibed.ping` | `{ok, time}` | Liveness probe |
| `vibed.version` | `{version}` | Daemon build version |
| `status.get` | `{raw, mode, host}` | `vibe status` |
| `doctor.run` | `{raw, all_pass}` | `vibe doctor` |
| `apps.list` | `{supported, integrations, installed}` | Mostly static + `vibe.conf` |
| `apps.upgrade.check` | `{raw}` | `vibe upgrade-check` |
| `apps.install` | `{job_id}` | Long-running, `vibe install <app>` |
| `apps.uninstall` | `{job_id}` | Long-running, `vibe uninstall <app>` |
| `apps.upgrade` | `{job_id}` | Long-running, `vibe upgrade <app> [--to ver]` |
| `apps.backup` | `{job_id}` | `vibe backup <app>` |
| `apps.backups.list` | `{app, backups[]}` | Filesystem read |
| `license.set` | `{raw}` | `vibe license set <app> <token>` |
| `cloudflare.attach` | `{raw}` | `vibe cloudflare attach <app> --token T` |
| `cloudflare.detach` | `{raw}` | `vibe cloudflare detach <app>` |
| `cloudflare.status` | `{raw}` | `vibe cloudflare status [<app>]` |
| `jobs.status` | `JobSnapshot` | Snapshot of one job |
| `jobs.list` | `[Job, ...]` | Recent + in-flight jobs |
| `jobs.stream` | streaming | One JSON object per line per output line |
| `diagnostics.export` | `{path, size_bytes}` | Tarball under `/var/log/vibe/` |

## Limitations / TODOs

- No restore RPC yet (Phase 2.4 of the build plan). Operator restores
  via `sudo /opt/vibe-installer/bin/vibe ...` until that lands.
- No log-tail RPC (`apps.logs.tail`). Coming with the admin UI's logs tab.
- No persistent job history — daemon restart loses in-flight job state.
  Out of scope for Phase 2.1; future versions can spool to
  `/var/lib/vibe/jobs/`.
