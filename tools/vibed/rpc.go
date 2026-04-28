// Copyright 2026 Kisaes LLC
// Licensed under the PolyForm Internal Use License 1.0.0.

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
)

// JSON-RPC 2.0 wire types. We deliberately don't pull in a full library
// here — the spec is small enough that hand-rolling is fewer LoC than
// the dependency surface.
//
// Wire framing: one JSON object per line ("\n" terminator). bufio.Scanner
// with the default split function handles the read side. The write side
// uses json.Encoder which appends "\n" after each Encode call.
type Request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"` // null for notifications
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type Response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}

type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

// Standard JSON-RPC error codes plus a few application-specific ones.
const (
	ErrParseError     = -32700
	ErrInvalidRequest = -32600
	ErrMethodNotFound = -32601
	ErrInvalidParams  = -32602
	ErrInternalError  = -32603
	// Application-level errors (>= -32000):
	ErrPermissionDenied = -32001 // not used today; reserved for future auth tiers
	ErrSubprocessFailed = -32002 // the wrapped `vibe <cmd>` exited non-zero
	ErrNotFound         = -32003 // referenced app / job / file doesn't exist
	ErrConflict         = -32004 // operation conflicts with current state
)

// HandlerFunc is the signature every RPC method's implementation
// satisfies. Returning a non-nil error becomes an RPCError on the wire;
// the returned `any` becomes the `result` field. Streaming methods (logs,
// jobs.stream) write directly to a per-call sender — see streamer.go.
//
// The context carries cancellation when the client disconnects mid-call.
// Long-running handlers should respect it.
type HandlerFunc func(ctx context.Context, params json.RawMessage, conn net.Conn) (any, error)

// Server is the concrete dispatcher. It holds the handler map plus the
// global config + jobs store every handler needs.
type Server struct {
	Cfg      *Config
	Jobs     *JobStore
	handlers map[string]HandlerFunc
	hMu      sync.RWMutex
}

func (s *Server) RegisterHandlers() {
	s.hMu.Lock()
	defer s.hMu.Unlock()
	s.handlers = map[string]HandlerFunc{
		// --- read-only
		"status.get":         s.handleStatusGet,
		"doctor.run":         s.handleDoctorRun,
		"apps.list":          s.handleAppsList,
		"apps.upgrade.check": s.handleAppsUpgradeCheck,
		"cloudflare.status":  s.handleCloudflareStatus,
		// --- write / lifecycle (long-running, return job IDs)
		"apps.install":   s.handleAppsInstall,
		"apps.uninstall": s.handleAppsUninstall,
		"apps.upgrade":   s.handleAppsUpgrade,
		"apps.backup":    s.handleAppsBackup,
		"apps.restore":   s.handleAppsRestore,
		// --- write / one-shot
		"license.set":            s.handleLicenseSet,
		"cloudflare.attach":      s.handleCloudflareAttach,
		"cloudflare.detach":      s.handleCloudflareDetach,
		"apps.backups.list":      s.handleBackupsList,
		"apps.backups.drop_list": s.handleBackupsDropList,
		// --- jobs
		"jobs.status": s.handleJobsStatus,
		"jobs.list":   s.handleJobsList,
		"jobs.stream": s.handleJobsStream,
		// --- logs (streaming, not job-tracked — each subscription
		//     spawns its own `docker compose logs --follow` process)
		"apps.logs.tail": s.handleAppsLogsTail,
		// --- integrations (host-level extras: tailscale, glm-ocr,
		//     tools). Install/uninstall are long-running (apt-install
		//     + tailscale up); status is a fast probe.
		"integrations.tailscale.install":   s.handleTailscaleInstall,
		"integrations.tailscale.uninstall": s.handleTailscaleUninstall,
		"integrations.tailscale.status":    s.handleTailscaleStatus,
		"integrations.glm-ocr.install":     s.handleGlmOcrInstall,
		"integrations.glm-ocr.uninstall":   s.handleGlmOcrUninstall,
		"integrations.glm-ocr.status":      s.handleGlmOcrStatus,
		// --- diagnostics
		"diagnostics.export": s.handleDiagnosticsExport,
		// --- meta
		"vibed.version": s.handleVibedVersion,
		"vibed.ping":    s.handleVibedPing,
	}
}

// HandleConn reads JSON-RPC requests one per line and dispatches each in
// the calling goroutine. Streaming methods own the connection for the
// duration of their stream, so we don't pipeline — one method at a time
// per connection. (The admin app opens a separate connection per
// streaming subscription.)
func (s *Server) HandleConn(ctx context.Context, conn net.Conn) {
	r := bufio.NewReader(conn)
	enc := json.NewEncoder(conn)

	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			if err != io.EOF && !isClosedConnErr(err) {
				log.Printf("vibed: read error: %v", err)
			}
			return
		}
		// Allow blank lines (clients may send keepalives).
		if isBlank(line) {
			continue
		}

		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			s.writeErr(enc, nil, ErrParseError, "invalid JSON: "+err.Error())
			continue
		}
		if req.JSONRPC != "2.0" {
			s.writeErr(enc, req.ID, ErrInvalidRequest, "jsonrpc must be \"2.0\"")
			continue
		}

		s.dispatch(ctx, &req, enc, conn)
	}
}

func (s *Server) dispatch(ctx context.Context, req *Request, enc *json.Encoder, conn net.Conn) {
	s.hMu.RLock()
	h, ok := s.handlers[req.Method]
	s.hMu.RUnlock()

	if s.Cfg.Debug {
		log.Printf("vibed: rpc %s (id=%s)", req.Method, string(req.ID))
	}

	if !ok {
		s.writeErr(enc, req.ID, ErrMethodNotFound, "method not found: "+req.Method)
		return
	}

	result, err := h(ctx, req.Params, conn)
	if err != nil {
		// If the handler already wrote a streaming response, it returns
		// (nil, nil) and we don't write anything else. (nil, err) is the
		// "I want a normal error response" case.
		s.writeErr(enc, req.ID, errCode(err), err.Error())
		return
	}
	if result == nil {
		// Streaming handler — already wrote everything. Don't send a
		// trailing response.
		return
	}
	resp := Response{JSONRPC: "2.0", ID: req.ID, Result: result}
	if err := enc.Encode(resp); err != nil {
		log.Printf("vibed: write response: %v", err)
	}
}

func (s *Server) writeErr(enc *json.Encoder, id json.RawMessage, code int, msg string) {
	resp := Response{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &RPCError{Code: code, Message: msg},
	}
	if err := enc.Encode(resp); err != nil {
		log.Printf("vibed: write error response: %v", err)
	}
}

// isBlank reports whether b is empty or only whitespace. Newlines, tabs,
// and spaces are accepted as keepalives.
func isBlank(b []byte) bool {
	for _, c := range b {
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' {
			return false
		}
	}
	return true
}

// errCode pulls a structured error code out of err if the handler
// returned a *codedError; otherwise falls back to the generic internal
// error code. Lets handlers signal "invalid params" / "not found" / etc.
// without hand-encoding RPCError every time.
func errCode(err error) int {
	type coded interface{ Code() int }
	if c, ok := err.(coded); ok {
		return c.Code()
	}
	return ErrInternalError
}

// codedError is a small helper for handlers that want to signal a
// specific JSON-RPC error code. Wrap the underlying error and pass it
// along through normal `return nil, err` flow.
type codedError struct {
	code int
	msg  string
}

func (e *codedError) Error() string { return e.msg }
func (e *codedError) Code() int     { return e.code }

func errInvalidParams(format string, args ...any) error {
	return &codedError{code: ErrInvalidParams, msg: fmt.Sprintf(format, args...)}
}
func errNotFound(format string, args ...any) error {
	return &codedError{code: ErrNotFound, msg: fmt.Sprintf(format, args...)}
}
func errConflict(format string, args ...any) error {
	return &codedError{code: ErrConflict, msg: fmt.Sprintf(format, args...)}
}
func errSubprocess(format string, args ...any) error {
	return &codedError{code: ErrSubprocessFailed, msg: fmt.Sprintf(format, args...)}
}
