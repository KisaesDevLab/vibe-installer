// Copyright 2026 Kisaes LLC
// Licensed under the PolyForm Internal Use License 1.0.0.

package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// runVibe shells out to the wrapped `vibe` binary and captures the
// combined stdout + stderr. Used for short read-only commands (status,
// doctor, upgrade-check, cloudflare status, etc.). Long-running commands
// go through runVibeJob in jobs.go instead so the client can stream output.
//
// The error returned wraps a non-zero exit code with the captured output
// so a Job's failure surface is "what the operator would see in their
// terminal" — handlers don't need to second-guess what went wrong.
func runVibe(ctx context.Context, cfg *Config, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, cfg.VibeBin, args...)
	// Inherit only the env the vibe CLI actually needs. PATH is required
	// (vibe shells out to docker, jq, openssl); HOME and USER let su-exec
	// / `whoami` calls inside lib/ behave normally; LANG keeps stderr
	// formatting consistent. Anything else (e.g. the daemon's own
	// LISTEN_FDS) gets stripped so a future systemd integration doesn't
	// leak unit context into the subprocess.
	cmd.Env = inheritedEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		// Surface the captured output in the error so the caller can pass
		// it on to the operator rather than the bare exit-status string.
		// Trimming because vibe's logger always ends with "\n".
		return out, fmt.Errorf("vibe %s failed: %w; output:\n%s",
			strings.Join(args, " "), err, strings.TrimRight(string(out), "\n"))
	}
	return out, nil
}

// runVibeStream invokes the vibe binary and copies the combined output
// into the supplied writer line by line. Used by the logs.tail handler
// (which forwards every line to the connection) and by jobs.go (which
// fans every line out to subscribers).
//
// The function returns when the subprocess exits OR when ctx is
// cancelled. Cancellation kills the process group so a running
// `docker compose logs --follow` doesn't outlive the client connection.
func runVibeStream(ctx context.Context, cfg *Config, w io.Writer, args ...string) error {
	return runVibeStreamWithEnv(ctx, cfg, nil, w, args...)
}

// runVibeStreamWithEnv is the env-aware variant. extraEnv is appended
// to the standard inherited env (last-wins on duplicate keys), so
// callers can inject per-call values like TAILSCALE_AUTHKEY without
// leaking them into concurrent goroutines via os.Setenv.
//
// Use case: the integrations.tailscale.install handler needs to pass
// TAILSCALE_AUTHKEY to lib/tailscale.sh so the install runs unattended.
// Modifying the daemon's process env globally would race with every
// other concurrent goroutine; threading per-call keeps the secret
// scoped to the single subprocess.
func runVibeStreamWithEnv(ctx context.Context, cfg *Config, extraEnv []string, w io.Writer, args ...string) error {
	cmd := exec.Command(cfg.VibeBin, args...)
	cmd.Env = append(inheritedEnv(), extraEnv...)
	// SysProcAttr = setpgid so we can kill the whole process group on
	// cancel. `vibe logs` shells out to `docker compose logs --follow`,
	// which spawns its own children; kill -PGID hits all of them.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = cmd.Stdout // merge so the client sees everything

	if err := cmd.Start(); err != nil {
		return err
	}

	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	// Copy stdout → w line-by-line so a slow subprocess can't block
	// indefinitely on a full pipe.
	copyDone := make(chan error, 1)
	go func() {
		_, err := io.Copy(w, bufio.NewReader(stdout))
		copyDone <- err
	}()

	select {
	case <-ctx.Done():
		// Client disconnected or daemon shutting down. Send SIGTERM to
		// the process group; if it's still around 5s later, SIGKILL.
		killGroup(cmd, syscall.SIGTERM)
		t := time.NewTimer(5 * time.Second)
		defer t.Stop()
		select {
		case <-done:
		case <-t.C:
			killGroup(cmd, syscall.SIGKILL)
			<-done
		}
		<-copyDone
		return ctx.Err()
	case err := <-done:
		<-copyDone
		return err
	}
}

func killGroup(cmd *exec.Cmd, sig syscall.Signal) {
	if cmd.Process == nil {
		return
	}
	// Negative PID targets the whole process group. Best-effort — a
	// race where the child has already exited surfaces as ESRCH which
	// is fine to swallow.
	_ = syscall.Kill(-cmd.Process.Pid, sig)
}

// inheritedEnv returns the minimal env every vibe subprocess needs.
// Built per-call rather than cached so a daemon restart picks up any
// env changes the operator made (rare, but worth not surprising them).
func inheritedEnv() []string {
	keep := []string{"PATH", "HOME", "USER", "LANG", "LC_ALL", "TZ"}
	out := make([]string, 0, len(keep))
	for _, k := range keep {
		if v, ok := os.LookupEnv(k); ok {
			out = append(out, k+"="+v)
		}
	}
	// Hard fallback for PATH so vibe always finds docker / openssl /
	// jq even if the daemon was started with a stripped env.
	if !envHas(out, "PATH=") {
		out = append(out, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
	}
	// Auto-confirm prompts. vibed is the canonical "no human watching"
	// caller — every confirm() prompt in lib/*.sh would otherwise
	// deadlock on a missing TTY. The admin UI's modal collects operator
	// consent before any RPC fires; the daemon just speaks to the CLI.
	out = append(out, "VIBE_ASSUME_YES=1")
	return out
}

func envHas(env []string, prefix string) bool {
	for _, e := range env {
		if strings.HasPrefix(e, prefix) {
			return true
		}
	}
	return false
}

// captureStream is a small adapter that bufio.Reader-line-splits writes
// from a subprocess and forwards each line to a sink. Used by both
// runVibeStream and jobs.go's runner.
type lineSink interface {
	Append(line string)
}

type lineWriter struct {
	sink lineSink
	buf  bytes.Buffer
}

func newLineWriter(s lineSink) *lineWriter { return &lineWriter{sink: s} }

func (lw *lineWriter) Write(p []byte) (int, error) {
	n := len(p)
	lw.buf.Write(p)
	for {
		idx := bytes.IndexByte(lw.buf.Bytes(), '\n')
		if idx < 0 {
			break
		}
		line := lw.buf.Next(idx + 1)
		// Strip the terminator so subscribers can re-add their own.
		lw.sink.Append(strings.TrimRight(string(line), "\r\n"))
	}
	return n, nil
}

// Flush emits any partial trailing line that didn't end in \n. Called
// once after the subprocess exits so progress messages without a
// terminator (e.g. "[install] pulling..." overwritten in place) still
// show up in the job log.
func (lw *lineWriter) Flush() {
	if lw.buf.Len() == 0 {
		return
	}
	lw.sink.Append(strings.TrimRight(lw.buf.String(), "\r\n"))
	lw.buf.Reset()
}

// ---------- helpers used by main.go ----------

func ensureDir(path string) error {
	if path == "" || path == "/" {
		return nil
	}
	return os.MkdirAll(path, 0o755)
}

func parentDir(p string) string { return filepath.Dir(p) }

// isClosedConnErr handles the platform-specific ways "the other end
// hung up" gets surfaced. Modern Go (>= 1.16) has net.ErrClosed but
// some flavors of read-from-EOF socket still come back with a wrapped
// EOF; both should terminate the read loop quietly.
func isClosedConnErr(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "use of closed network connection") ||
		strings.Contains(s, "connection reset by peer") ||
		strings.Contains(s, "broken pipe")
}

// ---------- socket auth helpers ----------

// applySocketPerms chowns + chmods the listening socket so only members
// of the configured group can connect. Failure here is fatal — without
// the perms, the daemon would silently expose a privileged endpoint to
// every user on the host.
func applySocketPerms(cfg *Config) error {
	gid, err := lookupGid(cfg.GroupName)
	if err != nil {
		return fmt.Errorf("look up group %q: %w", cfg.GroupName, err)
	}
	// The socket file is owned by the calling user (root in production
	// when systemd starts vibed; the user's UID otherwise). Group goes
	// to vibe so the admin app's container — which runs as `vibe:vibe`
	// — can connect.
	if err := os.Chown(cfg.SocketPath, -1, gid); err != nil {
		return fmt.Errorf("chown %s: %w", cfg.SocketPath, err)
	}
	if err := os.Chmod(cfg.SocketPath, defaultSocketMode); err != nil {
		return fmt.Errorf("chmod %s: %w", cfg.SocketPath, err)
	}
	return nil
}

// Connection-level peer-credential check (Linux). Returns the connecting
// process's UID + GIDs so future tiered auth (e.g. "only root may run
// install") has the data it needs. Today every call is permitted as
// long as the socket file's group perm let the connect happen.
func peerCreds(conn net.Conn) (*syscall.Ucred, error) {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return nil, fmt.Errorf("not a unix conn")
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return nil, err
	}
	var cred *syscall.Ucred
	var operr error
	err = raw.Control(func(fd uintptr) {
		cred, operr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	})
	if err != nil {
		return nil, err
	}
	return cred, operr
}
