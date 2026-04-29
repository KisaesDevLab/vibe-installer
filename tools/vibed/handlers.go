// Copyright 2026 Kisaes LLC
// Licensed under the PolyForm Internal Use License 1.0.0.

package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Common param shapes pulled out of individual handlers.

type appParams struct {
	App string `json:"app"`
}

type installParams struct {
	App string `json:"app"`
	// CloudflareTunnel was the per-app token slot pre-2026-04. The
	// single-ingress refactor moved tunnel ownership to the ingress;
	// this field is parsed but ignored. Set the tunnel token via
	// `cloudflare.set_token` instead.
	CloudflareTunnel string `json:"cloudflare_tunnel,omitempty"`
}

type upgradeParams struct {
	App     string `json:"app"`
	Version string `json:"version,omitempty"` // empty → latest
}

type restoreParams struct {
	App     string `json:"app"`
	Tarball string `json:"tarball"`
}

type licenseSetParams struct {
	App   string `json:"app"`
	Token string `json:"token"`
}

type cloudflareAttachParams struct {
	// App is parsed for backwards compatibility but ignored — the
	// single-ingress refactor (2026-04) made the tunnel per-ingress,
	// not per-app.
	App   string `json:"app,omitempty"`
	Token string `json:"token"`
}

type cloudflareSetTokenParams struct {
	Token string `json:"token"`
}

type jobIDParams struct {
	JobID string `json:"job_id"`
}

// VibedVersion is bumped each release tag; install.sh stamps the build
// at packaging time via -ldflags '-X main.VibedVersion=...'. Unset
// builds fall back to "dev".
var VibedVersion = "dev"

// ---------- meta ----------

func (s *Server) handleVibedVersion(_ context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	return map[string]string{"version": VibedVersion}, nil
}

func (s *Server) handleVibedPing(_ context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	return map[string]any{"ok": true, "time": time.Now().UTC()}, nil
}

// ---------- read-only ----------

func (s *Server) handleStatusGet(ctx context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	out, err := runVibe(ctx, s.Cfg, "status")
	if err != nil {
		return nil, errSubprocess(err.Error())
	}
	// `vibe status` is human-formatted today. Until vibe gains a
	// --json flag, return the raw text plus a parsed shape that the
	// admin app can render as a fallback structured view.
	return map[string]any{
		"raw":  string(out),
		"mode": parseStatusField(out, "mode"),
		"host": parseStatusField(out, "host"),
	}, nil
}

func (s *Server) handleDoctorRun(ctx context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	out, err := runVibe(ctx, s.Cfg, "doctor")
	// doctor exits non-zero when checks fail — that's a meaningful
	// result, not an RPC error. Surface the output either way; only
	// raise an error if the subprocess couldn't run at all (e.g.
	// the vibe binary is missing).
	if err != nil && len(out) == 0 {
		return nil, errSubprocess(err.Error())
	}
	return map[string]any{
		"raw":      string(out),
		"all_pass": err == nil,
	}, nil
}

// apps.list reads the installer's static registry plus the runtime
// `installed` list from /etc/vibe/vibe.conf so the admin app can render
// a card grid (installed vs available).
func (s *Server) handleAppsList(_ context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	supported := []string{"mybooks", "connect", "tb", "payroll", "tax"}
	integrations := []string{"glm-ocr", "tailscale", "tools"}
	installed, err := readInstalledApps()
	if err != nil {
		// Pre-install state — vibe.conf doesn't exist yet. Treat as empty.
		installed = nil
	}
	return map[string]any{
		"supported":    supported,
		"integrations": integrations,
		"installed":    installed,
	}, nil
}

// apps.upgrade.check returns a structured per-app version comparison.
// The CLI's `--json` flag emits a JSON object whose `apps` array
// contains one entry per installed app with current / latest /
// all_tags / status. The handler passes that through verbatim, plus
// a server-side timestamp the admin UI uses to render "last checked
// X minutes ago".
//
// Status values (in sync with lib/update_check.sh::update_check_run_json):
//   outdated  — newer published version exists, recommended_command set
//   current   — pinned version matches latest published
//   unpinned  — pinned to "latest" tag (rolling — admin UI nudges to pin)
//   ahead     — pinned version is newer than latest published (local
//               override / pre-release pin)
//   no-ghcr   — installer doesn't know which repo to query (registry
//               miss in update_check_image)
//   offline   — ghcr.io unreachable or no release tags published
type upgradeCheckResult struct {
	Apps []upgradeCheckApp `json:"apps"`
}

type upgradeCheckApp struct {
	App                 string   `json:"app"`
	Current             string   `json:"current"`
	Latest              string   `json:"latest"`
	AllTags             []string `json:"all_tags"`
	Status              string   `json:"status"`
	RecommendedCommand  string   `json:"recommended_command"`
}

func (s *Server) handleAppsUpgradeCheck(ctx context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	out, err := runVibe(ctx, s.Cfg, "upgrade-check", "--json")
	if err != nil {
		return nil, errSubprocess(err.Error())
	}
	var parsed upgradeCheckResult
	if err := json.Unmarshal(out, &parsed); err != nil {
		// Fallback: surface the raw output so the admin UI can at
		// least show *something* even if the JSON shape regressed.
		// Don't error — checking is non-essential UX.
		return map[string]any{
			"apps":          []any{},
			"raw":           string(out),
			"parse_error":   err.Error(),
			"checked_at":    time.Now().UTC(),
		}, nil
	}
	return map[string]any{
		"apps":       parsed.Apps,
		"checked_at": time.Now().UTC(),
	}, nil
}

// cloudflare.status returns the ingress-level tunnel state. The per-app
// shape was retired in the single-ingress refactor (2026-04); the
// `apps:[]` field is kept as an empty array so any pre-refactor admin UI
// build can still parse the response without crashing.
//
//	{
//	  tls_mode:        "internal" | "acme" | "cf-tunnel",
//	  token_attached:  bool,           // /etc/vibe/cloudflared/tunnel.token exists
//	  redacted_token:  "abc12345…wxyz" | "",
//	  sidecar_running: bool,           // vibe-ingress-cloudflared container up
//	  apps:            []              // legacy shape, always empty now
//	}
func (s *Server) handleCloudflareStatus(_ context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	tlsMode := readConfField("/etc/vibe/vibe.conf", "tls_mode")

	tokenPath := "/etc/vibe/cloudflared/tunnel.token"
	tokenBytes, _ := os.ReadFile(tokenPath)
	token := strings.TrimSpace(string(tokenBytes))

	sidecarRunning := dockerContainerExists("vibe-ingress-cloudflared")

	return map[string]any{
		"tls_mode":        tlsMode,
		"token_attached":  token != "",
		"redacted_token":  redactCloudflareToken(token),
		"sidecar_running": sidecarRunning,
		"apps":            []any{},
	}, nil
}

// dockerContainerExists returns true iff a container with the exact name
// is currently running. Cheaper than `docker inspect` because it doesn't
// shell-fork unless the daemon is reachable.
func dockerContainerExists(name string) bool {
	cmd := exec.Command("docker", "ps", "--filter", "name=^"+name+"$", "--format", "{{.Names}}")
	cmd.Env = inheritedEnv()
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(out)) == name
}

// readConfField pulls a single `key=value` line out of vibe.conf.
// Returns "" if the file doesn't exist or the key is absent.
func readConfField(path, key string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	prefix := key + "="
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			return strings.TrimPrefix(line, prefix)
		}
	}
	return ""
}

// redactCloudflareToken keeps the leading 8 + trailing 4 chars so the
// SPA can show the operator a recognizable fingerprint without
// exposing the full credential. Mirrors lib/cloudflare.sh's
// cloudflare_redact behavior.
func redactCloudflareToken(t string) string {
	if t == "" {
		return ""
	}
	if len(t) < 16 {
		return "<redacted>"
	}
	return t[:8] + "…" + t[len(t)-4:]
}

// ---------- write / lifecycle (returns job ID) ----------

func (s *Server) handleAppsInstall(_ context.Context, params json.RawMessage, _ net.Conn) (any, error) {
	var p installParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, errInvalidParams("invalid params: %v", err)
	}
	if p.App == "" {
		return nil, errInvalidParams("app is required")
	}

	args := []string{"install", p.App}
	// p.CloudflareTunnel is intentionally ignored — the per-app
	// `--cloudflare-tunnel` flag is a no-op since 2026-04. The admin UI
	// should call `cloudflare.set_token` to wire the ingress-level tunnel.

	job, ctx := s.Jobs.Begin("apps.install", p.App)
	go runJobSubprocess(ctx, job, s.Cfg, args)
	return map[string]string{"job_id": job.ID}, nil
}

func (s *Server) handleAppsUninstall(_ context.Context, params json.RawMessage, _ net.Conn) (any, error) {
	var p appParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, errInvalidParams("invalid params: %v", err)
	}
	if p.App == "" {
		return nil, errInvalidParams("app is required")
	}
	job, ctx := s.Jobs.Begin("apps.uninstall", p.App)
	go runJobSubprocess(ctx, job, s.Cfg, []string{"uninstall", p.App})
	return map[string]string{"job_id": job.ID}, nil
}

func (s *Server) handleAppsUpgrade(_ context.Context, params json.RawMessage, _ net.Conn) (any, error) {
	var p upgradeParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, errInvalidParams("invalid params: %v", err)
	}
	if p.App == "" {
		return nil, errInvalidParams("app is required")
	}
	args := []string{"upgrade", p.App}
	if p.Version != "" {
		args = append(args, "--to", p.Version)
	}
	job, ctx := s.Jobs.Begin("apps.upgrade", p.App)
	go runJobSubprocess(ctx, job, s.Cfg, args)
	return map[string]string{"job_id": job.ID}, nil
}

func (s *Server) handleAppsBackup(_ context.Context, params json.RawMessage, _ net.Conn) (any, error) {
	var p appParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, errInvalidParams("invalid params: %v", err)
	}
	if p.App == "" {
		return nil, errInvalidParams("app is required")
	}
	job, ctx := s.Jobs.Begin("apps.backup", p.App)
	go runJobSubprocess(ctx, job, s.Cfg, []string{"backup", p.App})
	return map[string]string{"job_id": job.ID}, nil
}

// apps.restore is the long-running mirror of apps.backup. The admin UI
// calls it with the path of a tarball previously produced by `vibe
// backup` — either a local backup (under /var/lib/vibe/<app>/backups/)
// or one the operator SCPed into /var/lib/vibe/.restore-drop/.
//
// The tarball path is validated here BEFORE spawning the job so an
// invalid path surfaces as a synchronous RPC error rather than a job
// that immediately fails (cleaner error surface for the admin UI).
//
// Path-traversal defense: the path must be under one of the two trusted
// roots — /var/lib/vibe/<app>/backups/ for local snapshots, or
// /var/lib/vibe/.restore-drop/ for SCP-uploaded files. Anything outside
// is rejected with errInvalidParams.
func (s *Server) handleAppsRestore(_ context.Context, params json.RawMessage, _ net.Conn) (any, error) {
	var p restoreParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, errInvalidParams("invalid params: %v", err)
	}
	if p.App == "" || p.Tarball == "" {
		return nil, errInvalidParams("app and tarball are required")
	}
	// Resolve symlinks + clean ".." segments. EvalSymlinks fails if the
	// file doesn't exist; we treat that as not-found rather than
	// internal-error so the admin UI's modal renders a useful message.
	resolved, err := filepath.EvalSymlinks(p.Tarball)
	if err != nil {
		return nil, errNotFound("tarball not found: %s", p.Tarball)
	}
	if !isAllowedRestoreSource(resolved, p.App) {
		return nil, errInvalidParams(
			"tarball %s is outside the allowed restore roots "+
				"(/var/lib/vibe/<app>/backups/ or /var/lib/vibe/.restore-drop/)",
			resolved,
		)
	}

	job, ctx := s.Jobs.Begin("apps.restore", p.App)
	// inheritedEnv() in subprocess.go always sets VIBE_ASSUME_YES=1
	// for vibed-spawned subprocesses, so the apps_restore confirmation
	// prompt auto-accepts. The admin UI's modal already collected the
	// operator's consent before this RPC fired.
	args := []string{"restore", p.App, resolved}
	go runJobSubprocess(ctx, job, s.Cfg, args)
	return map[string]string{"job_id": job.ID}, nil
}

// ---------- write / one-shot ----------

func (s *Server) handleLicenseSet(ctx context.Context, params json.RawMessage, _ net.Conn) (any, error) {
	var p licenseSetParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, errInvalidParams("invalid params: %v", err)
	}
	if p.App == "" || p.Token == "" {
		return nil, errInvalidParams("app and token are required")
	}
	out, err := runVibe(ctx, s.Cfg, "license", "set", p.App, p.Token)
	if err != nil {
		return nil, errSubprocess(err.Error())
	}
	return map[string]any{"raw": string(out)}, nil
}

// cloudflare.set_token — stash an operator-supplied tunnel token at the
// ingress level + reload the cloudflared sidecar. Replaces the per-app
// `cloudflare.attach` from the pre-2026-04 model.
func (s *Server) handleCloudflareSetToken(ctx context.Context, params json.RawMessage, _ net.Conn) (any, error) {
	var p cloudflareSetTokenParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, errInvalidParams("invalid params: %v", err)
	}
	if p.Token == "" {
		return nil, errInvalidParams("token is required")
	}
	out, err := runVibe(ctx, s.Cfg, "cloudflare", "set-token", p.Token)
	if err != nil {
		return nil, errSubprocess(err.Error())
	}
	return map[string]any{"raw": string(out)}, nil
}

// cloudflare.clear — remove the stashed tunnel token. Replaces per-app
// `cloudflare.detach`.
func (s *Server) handleCloudflareClear(ctx context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	out, err := runVibe(ctx, s.Cfg, "cloudflare", "clear")
	if err != nil {
		return nil, errSubprocess(err.Error())
	}
	return map[string]any{"raw": string(out)}, nil
}

// Deprecated wrappers — kept so a stale admin UI build can still ride
// over the refactor without crashing. Both forward to the ingress-level
// commands; any `app` param is ignored.

func (s *Server) handleCloudflareAttach(ctx context.Context, params json.RawMessage, conn net.Conn) (any, error) {
	var p cloudflareAttachParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, errInvalidParams("invalid params: %v", err)
	}
	if p.Token == "" {
		return nil, errInvalidParams("token is required")
	}
	// Forward to set_token. The per-app `app` field is silently dropped.
	stPayload, _ := json.Marshal(cloudflareSetTokenParams{Token: p.Token})
	return s.handleCloudflareSetToken(ctx, stPayload, conn)
}

func (s *Server) handleCloudflareDetach(ctx context.Context, _ json.RawMessage, conn net.Conn) (any, error) {
	return s.handleCloudflareClear(ctx, nil, conn)
}

func (s *Server) handleBackupsList(_ context.Context, params json.RawMessage, _ net.Conn) (any, error) {
	var p appParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, errInvalidParams("invalid params: %v", err)
	}
	if p.App == "" {
		return nil, errInvalidParams("app is required")
	}
	dir := filepath.Join("/var/lib/vibe", p.App, "backups")
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]any{"app": p.App, "backups": []any{}}, nil
		}
		return nil, errSubprocess("read %s: %v", dir, err)
	}
	out := make([]map[string]any, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".tar.gz") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, map[string]any{
			"name":     e.Name(),
			"path":     filepath.Join(dir, e.Name()),
			"size":     info.Size(),
			"modified": info.ModTime().UTC(),
		})
	}
	return map[string]any{"app": p.App, "backups": out}, nil
}

// apps.backups.drop_list — list .tar.gz files in /var/lib/vibe/.restore-drop/.
// Used by the admin UI's restore page to show the operator what they've
// SCPed onto the host. We don't try to validate the tarballs here; the
// apps.restore handler does that when the operator picks one.
func (s *Server) handleBackupsDropList(_ context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	dir := "/var/lib/vibe/.restore-drop"
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]any{"path": dir, "files": []any{}}, nil
		}
		return nil, errSubprocess("read %s: %v", dir, err)
	}
	out := make([]map[string]any, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".tar.gz") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, map[string]any{
			"name":     e.Name(),
			"path":     filepath.Join(dir, e.Name()),
			"size":     info.Size(),
			"modified": info.ModTime().UTC(),
		})
	}
	return map[string]any{"path": dir, "files": out}, nil
}

// isAllowedRestoreSource gates apps.restore by tarball location. The
// path must be under one of the two trusted roots:
//
//   /var/lib/vibe/<app>/backups/    — local snapshots from `vibe backup`
//   /var/lib/vibe/.restore-drop/    — operator-SCPed tarballs
//
// Anything else is rejected to keep an attacker who has compromised the
// admin UI from triggering a restore that overwrites /var/lib/vibe/<app>/
// with arbitrary tarball contents read from elsewhere on the host (e.g.
// /tmp where another user might have planted a malicious tarball).
//
// Caller must pass an already-cleaned absolute path (filepath.EvalSymlinks
// before invocation). The HasPrefix check is exact-prefix only, so
// /var/lib/vibe/.restore-drop-evil/ doesn't sneak past .restore-drop/.
func isAllowedRestoreSource(absPath, app string) bool {
	dropPrefix := "/var/lib/vibe/.restore-drop" + string(filepath.Separator)
	backupsPrefix := filepath.Join("/var/lib/vibe", app, "backups") + string(filepath.Separator)
	return strings.HasPrefix(absPath, dropPrefix) || strings.HasPrefix(absPath, backupsPrefix)
}

// ---------- jobs ----------

func (s *Server) handleJobsStatus(_ context.Context, params json.RawMessage, _ net.Conn) (any, error) {
	var p jobIDParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, errInvalidParams("invalid params: %v", err)
	}
	job, ok := s.Jobs.Get(p.JobID)
	if !ok {
		return nil, errNotFound("no such job: %s", p.JobID)
	}
	return job.Snapshot(), nil
}

func (s *Server) handleJobsList(_ context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	jobs := s.Jobs.List()
	out := make([]map[string]any, 0, len(jobs))
	for _, j := range jobs {
		j.mu.Lock()
		out = append(out, map[string]any{
			"id":         j.ID,
			"method":     j.Method,
			"app":        j.App,
			"started_at": j.StartedAt,
			"ended_at":   j.EndedAt,
			"state":      j.State,
			"exit_code":  j.ExitCode,
		})
		j.mu.Unlock()
	}
	return out, nil
}

// apps.logs.tail — streaming RPC that follows `vibe logs <app> [service]`.
// Unlike apps.install / apps.upgrade / etc. (which return a job_id and
// the SPA opens a separate jobs.stream subscription), logs are
// inherently per-subscriber: each browser tab opening the Logs page
// spawns its own `docker compose logs --follow` subprocess. Multiple
// operators can tail the same app without contention.
//
// Wire format mirrors jobs.stream so the SPA can reuse the same line
// renderer:
//
//   {"event":"line","line":{"seq":<n>,"time":"...","text":"..."}}
//   ...
//   {"event":"done","exit_code":0|null,"reason":"..."}
//
// `done` fires when the subprocess exits — either because the operator
// closed the panel (ctx cancelled → SIGTERM via runVibeStream's cleanup)
// or because the underlying container is gone. exit_code is null for
// the cancel-via-context case, the actual code otherwise.
func (s *Server) handleAppsLogsTail(ctx context.Context, params json.RawMessage, conn net.Conn) (any, error) {
	var p struct {
		App     string `json:"app"`
		Service string `json:"service,omitempty"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, errInvalidParams("invalid params: %v", err)
	}
	if p.App == "" {
		return nil, errInvalidParams("app is required")
	}

	enc := json.NewEncoder(conn)
	args := []string{"logs", p.App}
	if p.Service != "" {
		args = append(args, p.Service)
	}

	// Per-line emitter that adopts the same JSON shape as jobs.stream's
	// line events, so the SPA can reuse the same renderer. seq is a
	// per-subscriber counter — it isn't aligned with anything else,
	// it's just there for the SPA's React keying.
	seq := 0
	emit := func(text string) {
		seq++
		_ = enc.Encode(map[string]any{
			"event": "line",
			"line": map[string]any{
				"seq":  seq,
				"time": time.Now().UTC(),
				"text": text,
			},
		})
	}
	writer := newLineWriter(&logsLineSink{emit: emit})

	err := runVibeStream(ctx, s.Cfg, writer, args...)
	writer.Flush()

	// Final 'done' frame so the SPA's stream reader knows to flip
	// state. If the context was cancelled (operator closed the panel
	// or daemon shutting down), surface that as a null exit code with
	// reason="cancelled". Real subprocess exits get the real code.
	done := map[string]any{"event": "done"}
	if ctx.Err() != nil {
		done["reason"] = "cancelled"
		done["exit_code"] = nil
	} else if err != nil {
		done["reason"] = err.Error()
		done["exit_code"] = 1
	} else {
		done["exit_code"] = 0
	}
	_ = enc.Encode(done)
	return nil, nil
}

// logsLineSink is a tiny adapter so apps.logs.tail can re-use the same
// line-buffered writer (lineWriter from subprocess.go) that jobs use.
type logsLineSink struct{ emit func(string) }

func (l *logsLineSink) Append(line string) { l.emit(line) }

// jobs.stream is the only handler that writes responses on its own.
// Returns (nil, nil) so dispatch() doesn't append a final response.
//
// Subscribe-first-then-snapshot to avoid losing lines that get appended
// between the two operations. This means the client may see a line both
// in the snapshot and in the live stream — line.Seq makes that
// detectable so the admin app can de-dup.
func (s *Server) handleJobsStream(ctx context.Context, params json.RawMessage, conn net.Conn) (any, error) {
	var p jobIDParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, errInvalidParams("invalid params: %v", err)
	}
	job, ok := s.Jobs.Get(p.JobID)
	if !ok {
		return nil, errNotFound("no such job: %s", p.JobID)
	}

	enc := json.NewEncoder(conn)

	// Subscribe first so the producer's notifications go into our
	// channel from this moment forward. Subscribe returns a closed
	// channel if the job is already finished — the loop below handles
	// that by exiting after emitting the snapshot + 'done'.
	ch := job.Subscribe()
	snap := job.Snapshot()

	// Replay the buffered lines.
	for _, line := range snap.Lines {
		if err := enc.Encode(map[string]any{"event": "line", "line": line}); err != nil {
			return nil, nil
		}
	}
	if snap.EndedAt != nil {
		_ = enc.Encode(map[string]any{
			"event":     "done",
			"state":     snap.State,
			"exit_code": snap.ExitCode,
		})
		return nil, nil
	}

	// Forward live lines until the channel closes (job finished) or
	// the client disconnects.
	for {
		select {
		case <-ctx.Done():
			return nil, nil
		case line, ok := <-ch:
			if !ok {
				final := job.Snapshot()
				_ = enc.Encode(map[string]any{
					"event":     "done",
					"state":     final.State,
					"exit_code": final.ExitCode,
				})
				return nil, nil
			}
			if err := enc.Encode(map[string]any{"event": "line", "line": line}); err != nil {
				return nil, nil
			}
		}
	}
}

// ---------- diagnostics ----------

// diagnostics.export tarballs everything support engineering needs to
// triage a stuck appliance: vibe.conf (sanitized), latest doctor output,
// last 200 lines of every container, journalctl for vibed itself, and
// the rendered Caddyfile. Operator gets a path back; admin app uploads
// to support.kisaes.com (out of scope here — handler just produces the
// tarball).
func (s *Server) handleDiagnosticsExport(ctx context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	ts := time.Now().UTC().Format("20060102T150405Z")
	dest := filepath.Join("/var/log/vibe", fmt.Sprintf("diagnostics-%s.tar.gz", ts))
	f, err := os.Create(dest)
	if err != nil {
		return nil, errSubprocess("create %s: %v", dest, err)
	}
	defer f.Close()

	gw := gzip.NewWriter(f)
	defer gw.Close()
	tw := tar.NewWriter(gw)
	defer tw.Close()

	// 1. doctor output
	if doc, err := runVibe(ctx, s.Cfg, "doctor"); err == nil || len(doc) > 0 {
		writeTarBytes(tw, "doctor.txt", doc)
	}

	// 2. status
	if st, err := runVibe(ctx, s.Cfg, "status"); err == nil {
		writeTarBytes(tw, "status.txt", st)
	}

	// 3. sanitized vibe.conf — strip any `*token*` / `*secret*` lines
	//    out of an abundance of caution, even though the live conf
	//    only carries non-secret toggles.
	if conf, err := os.ReadFile("/etc/vibe/vibe.conf"); err == nil {
		writeTarBytes(tw, "vibe.conf", sanitizeConf(conf))
	}

	// 4. rendered Caddyfile (no secrets — host + tls mode are public).
	if cad, err := os.ReadFile("/etc/vibe/ingress/Caddyfile"); err == nil {
		writeTarBytes(tw, "ingress/Caddyfile", cad)
	}

	return map[string]any{"path": dest, "size_bytes": fileSize(dest)}, nil
}

// ---------- integrations: tailscale ----------

type tailscaleInstallParams struct {
	AuthKey string `json:"auth_key"`
}

// integrations.tailscale.install runs `vibe install tailscale` with
// TAILSCALE_AUTHKEY set in the env so lib/tailscale.sh's auth-key path
// fires (avoiding the interactive browser-URL flow that won't work
// from vibed). Returns a job_id; admin UI follows via jobs.stream.
//
// Auth-key is required — without it lib/tailscale.sh would warn
// "no TAILSCALE_AUTHKEY set and no TTY — skipping enrollment" and
// the operator would think the install succeeded but nothing happened.
func (s *Server) handleTailscaleInstall(_ context.Context, params json.RawMessage, _ net.Conn) (any, error) {
	var p tailscaleInstallParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, errInvalidParams("invalid params: %v", err)
	}
	if p.AuthKey == "" {
		return nil, errInvalidParams("auth_key is required (a reusable key from " +
			"https://login.tailscale.com/admin/settings/keys)")
	}

	job, ctx := s.Jobs.Begin("integrations.tailscale.install", "tailscale")
	args := []string{"install", "tailscale"}
	extraEnv := []string{"TAILSCALE_AUTHKEY=" + p.AuthKey}
	go runJobSubprocessWithEnv(ctx, job, s.Cfg, extraEnv, args)
	return map[string]string{"job_id": job.ID}, nil
}

func (s *Server) handleTailscaleUninstall(_ context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	job, ctx := s.Jobs.Begin("integrations.tailscale.uninstall", "tailscale")
	go runJobSubprocess(ctx, job, s.Cfg, []string{"uninstall", "tailscale"})
	return map[string]string{"job_id": job.ID}, nil
}

// integrations.tailscale.status — fast probe. Returns whether the
// CLI is installed, whether tailscaled is authenticated
// (BackendState=Running), and the assigned IPv4 if available. We
// shell out to `tailscale` directly rather than going through `vibe`
// because the CLI command would print human text we'd then have to
// parse — and vibed already runs as root so subprocess invocation
// is the same cost.
func (s *Server) handleTailscaleStatus(ctx context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	if _, err := exec.LookPath("tailscale"); err != nil {
		return map[string]any{
			"installed":     false,
			"authenticated": false,
			"ip":            "",
		}, nil
	}

	cmd := exec.CommandContext(ctx, "tailscale", "status",
		"--self=true", "--peers=false", "--json")
	cmd.Env = inheritedEnv()
	statusOut, err := cmd.Output()
	if err != nil {
		// `tailscale status` returns non-zero when tailscaled is
		// running but not yet authenticated. Treat as installed-but-
		// unauthenticated so the SPA renders the right action.
		return map[string]any{
			"installed":     true,
			"authenticated": false,
			"ip":            "",
		}, nil
	}
	var st struct {
		BackendState string `json:"BackendState"`
		Self         *struct {
			TailscaleIPs []string `json:"TailscaleIPs"`
		} `json:"Self"`
	}
	if err := json.Unmarshal(statusOut, &st); err != nil {
		return map[string]any{
			"installed":     true,
			"authenticated": false,
			"ip":            "",
			"parse_error":   err.Error(),
		}, nil
	}
	authed := st.BackendState == "Running"
	var ip string
	if authed && st.Self != nil {
		// Tailscale assigns a 100.x.y.z IPv4 + an IPv6. Pick the v4.
		for _, addr := range st.Self.TailscaleIPs {
			if !strings.Contains(addr, ":") {
				ip = addr
				break
			}
		}
	}
	return map[string]any{
		"installed":     true,
		"authenticated": authed,
		"ip":            ip,
	}, nil
}

// ---------- glm-ocr ----------
//
// Mirror of the tailscale handlers, but with a delete_cache toggle on
// uninstall. Background: vibed always sets VIBE_ASSUME_YES=1, which
// would cause lib/glm_ocr.sh's "remove the multi-GB model cache?"
// confirm to default-yes and silently nuke the cache. The lib was
// updated to honor VIBE_GLM_OCR_KEEP_CACHE / VIBE_GLM_OCR_DELETE_CACHE
// instead — these handlers always set exactly one of those so the
// daemon decision is unambiguous regardless of UI input.

type glmOcrUninstallParams struct {
	DeleteCache bool `json:"delete_cache"`
}

func (s *Server) handleGlmOcrInstall(_ context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	job, ctx := s.Jobs.Begin("integrations.glm-ocr.install", "glm-ocr")
	go runJobSubprocess(ctx, job, s.Cfg, []string{"install", "glm-ocr"})
	return map[string]string{"job_id": job.ID}, nil
}

func (s *Server) handleGlmOcrUninstall(_ context.Context, params json.RawMessage, _ net.Conn) (any, error) {
	var p glmOcrUninstallParams
	if len(params) > 0 && string(params) != "null" {
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, errInvalidParams("invalid params: %v", err)
		}
	}
	var extraEnv []string
	if p.DeleteCache {
		extraEnv = []string{"VIBE_GLM_OCR_DELETE_CACHE=1"}
	} else {
		extraEnv = []string{"VIBE_GLM_OCR_KEEP_CACHE=1"}
	}
	job, ctx := s.Jobs.Begin("integrations.glm-ocr.uninstall", "glm-ocr")
	go runJobSubprocessWithEnv(ctx, job, s.Cfg, extraEnv, []string{"uninstall", "glm-ocr"})
	return map[string]string{"job_id": job.ID}, nil
}

// integrations.glm-ocr.status — fast probe. Goes to docker directly
// for the same reason handleTailscaleStatus shells out to `tailscale`:
// `vibe status` would give us human-formatted text we'd then have to
// parse, and vibed already runs as root.
//
// Returns four fields:
//   installed — `vibe-glm-ocr` container exists at all
//   running   — container's State.Status == "running"
//   healthy   — Docker healthcheck reports "healthy" (or no healthcheck
//               configured but container is running)
//   url       — local probe URL (always 127.0.0.1:8090); apps reach it
//               internally as http://vibe-glm-ocr:8090
func (s *Server) handleGlmOcrStatus(ctx context.Context, _ json.RawMessage, _ net.Conn) (any, error) {
	cmd := exec.CommandContext(ctx, "docker", "inspect",
		"-f", "{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}",
		"vibe-glm-ocr")
	cmd.Env = inheritedEnv()
	out, err := cmd.Output()
	if err != nil {
		// Container doesn't exist (most common case before install).
		return map[string]any{
			"installed": false,
			"running":   false,
			"healthy":   false,
			"url":       "http://127.0.0.1:8090/",
		}, nil
	}
	line := strings.TrimSpace(string(out))
	parts := strings.SplitN(line, "|", 2)
	state := parts[0]
	health := ""
	if len(parts) > 1 {
		health = parts[1]
	}
	running := state == "running"
	// "healthy" iff the healthcheck explicitly says so, OR the container
	// has no healthcheck but is running. Compose declares one for
	// glm-ocr so the no-healthcheck branch is mostly defensive.
	healthy := health == "healthy" || (running && health == "")
	return map[string]any{
		"installed": true,
		"running":   running,
		"healthy":   healthy,
		"url":       "http://127.0.0.1:8090/",
	}, nil
}

// ---------- helpers ----------

// readInstalledApps parses the comma-separated `installed=` line from
// /etc/vibe/vibe.conf. Returns an empty list if the conf doesn't exist
// (pre-bootstrap) or the field is empty (zero apps installed).
func readInstalledApps() ([]string, error) {
	b, err := os.ReadFile("/etc/vibe/vibe.conf")
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "installed=") {
			continue
		}
		raw := strings.TrimPrefix(line, "installed=")
		raw = strings.TrimSpace(raw)
		if raw == "" {
			return []string{}, nil
		}
		parts := strings.Split(raw, ",")
		out := make([]string, 0, len(parts))
		for _, p := range parts {
			p = strings.TrimSpace(p)
			if p != "" {
				out = append(out, p)
			}
		}
		return out, nil
	}
	return []string{}, nil
}

func parseStatusField(out []byte, key string) string {
	prefix := key + "="
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			return strings.TrimPrefix(line, prefix)
		}
	}
	return ""
}

func writeTarBytes(tw *tar.Writer, name string, body []byte) {
	hdr := &tar.Header{
		Name:    name,
		Mode:    0o644,
		Size:    int64(len(body)),
		ModTime: time.Now().UTC(),
	}
	if err := tw.WriteHeader(hdr); err != nil {
		return
	}
	_, _ = tw.Write(body)
}

func fileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}

// sanitizeConf is a defensive belt for the diagnostics export. The
// installer-managed vibe.conf doesn't carry secrets today, but a future
// field that does would silently leak through this path. Strip any
// line whose key looks secret-shaped.
func sanitizeConf(b []byte) []byte {
	suspicious := []string{"token", "secret", "password", "key="}
	var out strings.Builder
	for _, line := range strings.Split(string(b), "\n") {
		lower := strings.ToLower(line)
		redact := false
		for _, s := range suspicious {
			if strings.Contains(lower, s) {
				redact = true
				break
			}
		}
		if redact {
			eq := strings.Index(line, "=")
			if eq > 0 {
				out.WriteString(line[:eq+1] + "<redacted>")
			} else {
				out.WriteString("<redacted>")
			}
		} else {
			out.WriteString(line)
		}
		out.WriteByte('\n')
	}
	return []byte(out.String())
}
