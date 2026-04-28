// Copyright 2026 Kisaes LLC
// Licensed under the PolyForm Internal Use License 1.0.0.
//
// vibed — long-running daemon that exposes the existing `vibe` CLI as a
// JSON-RPC API over a Unix socket.
//
// Architecture
//
//	The daemon is a thin wrapper around `vibe <subcommand>`. It owns no
//	state beyond an in-memory job table (jobs.go) — all the heavy lifting
//	lives in /opt/vibe-installer/lib/*.sh and is reached via os/exec.
//	Two clients consume vibed today: the existing `vibe` CLI (which keeps
//	working unchanged) and the admin web app (apps/admin in this repo)
//	which speaks JSON-RPC to /run/vibed.sock.
//
// Auth
//
//	Auth is delegated to the kernel via the socket file's owner/group/mode
//	(vibe:vibe, 0660). Only processes whose effective gid includes the
//	`vibe` group can connect. The admin app's container runs in that
//	group; the host operator running `sudo` does too. There is no
//	separate auth in vibed itself — anything that can reach the socket
//	is fully trusted.
//
// Wire format
//
//	JSON-RPC 2.0, framed as one JSON object per line ("\n" terminated).
//	See rpc.go for the request / response shapes.
//
// Long-running calls
//
//	apps.install / apps.upgrade / apps.uninstall / apps.backup return a
//	job ID immediately. The client polls jobs.status or subscribes to
//	jobs.stream for live output. See jobs.go.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
)

// Compile-time defaults. install.sh writes a systemd unit that overrides
// these via flags so a packaged install picks up customer-specific paths
// without recompiling.
const (
	defaultSocketPath = "/run/vibed.sock"
	defaultVibeBin    = "/usr/local/bin/vibe"
	defaultPrefix     = "/opt/vibe-installer"
	defaultSocketMode = 0660
	defaultGroupName  = "vibe"
)

// Global config established at startup. Read-only after Server.Run begins
// so concurrent goroutines can read without locking.
type Config struct {
	SocketPath string
	VibeBin    string
	Prefix     string
	GroupName  string
	Debug      bool
}

func main() {
	cfg := parseFlags()
	if err := run(cfg); err != nil {
		log.Fatalf("vibed: %v", err)
	}
}

func run(cfg *Config) error {
	// Ensure the parent directory of the socket exists. /run is normally
	// a tmpfs that's empty between boots; systemd tmpfiles handles that
	// for us when packaged, but a hand-installed binary needs the safety
	// net so the operator doesn't see "bind: no such file or directory"
	// on first start.
	if err := ensureDir(parentDir(cfg.SocketPath)); err != nil {
		return fmt.Errorf("ensure socket dir: %w", err)
	}

	// Stale socket from a previous unclean shutdown. Removing it before
	// Listen is the standard idiom — `unix.Listen` doesn't unlink old
	// sockets and the second `vibed` start would otherwise fail with
	// "address already in use".
	_ = os.Remove(cfg.SocketPath)

	listener, err := net.Listen("unix", cfg.SocketPath)
	if err != nil {
		return fmt.Errorf("listen %s: %w", cfg.SocketPath, err)
	}
	defer listener.Close()

	// Permissions on the socket file are the only auth gate. We have to
	// chown / chmod after Listen because Go's net package creates the
	// socket with the umask-default mode, which is normally too open.
	if err := applySocketPerms(cfg); err != nil {
		return fmt.Errorf("set socket perms: %w", err)
	}

	jobs := NewJobStore()
	srv := &Server{
		Cfg:  cfg,
		Jobs: jobs,
	}
	srv.RegisterHandlers()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	log.Printf("vibed listening on %s (mode 0%o, group %s)", cfg.SocketPath, defaultSocketMode, cfg.GroupName)

	// Accept loop runs until the context is cancelled (SIGINT/SIGTERM).
	// Each accepted connection gets a goroutine; we WaitGroup them on
	// shutdown so in-flight RPCs finish before the binary exits.
	var wg sync.WaitGroup
	go func() {
		<-ctx.Done()
		log.Printf("vibed: shutdown signal received, closing listener")
		listener.Close()
	}()

	for {
		conn, err := listener.Accept()
		if err != nil {
			// listener.Close() during shutdown surfaces here as a wrapped
			// net.ErrClosed. That's expected — drain workers and return.
			if errors.Is(err, net.ErrClosed) {
				wg.Wait()
				log.Printf("vibed: shut down cleanly")
				return nil
			}
			log.Printf("vibed: accept error: %v", err)
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer conn.Close()
			srv.HandleConn(ctx, conn)
		}()
	}
}

func parseFlags() *Config {
	cfg := &Config{}
	flag.StringVar(&cfg.SocketPath, "socket", defaultSocketPath, "Unix socket path to listen on")
	flag.StringVar(&cfg.VibeBin, "vibe-bin", defaultVibeBin, "Path to the vibe CLI binary")
	flag.StringVar(&cfg.Prefix, "prefix", defaultPrefix, "Path to the vibe-installer repo")
	flag.StringVar(&cfg.GroupName, "group", defaultGroupName, "Group that owns the socket file")
	flag.BoolVar(&cfg.Debug, "debug", false, "Verbose request/response logging")
	flag.Parse()
	return cfg
}
