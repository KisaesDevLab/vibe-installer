// Copyright 2026 Kisaes LLC
// Licensed under the PolyForm Internal Use License 1.0.0.

package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"sync"
	"time"
)

// Long-running RPCs (apps.install, apps.upgrade, apps.uninstall,
// apps.backup) return immediately with a job ID. The actual `vibe ...`
// invocation runs in a background goroutine that streams its output into
// a Job's line buffer. Clients poll jobs.status (snapshot) or subscribe
// via jobs.stream (live).
//
// Design notes
//   - Job state is in-memory only. A daemon restart loses the history;
//     jobs that were running at restart time are reaped (their orphan
//     subprocess is killed by the kernel when the daemon's process group
//     dies, since cmd.Setpgid was set).
//   - The Lines slice keeps at most maxJobLines; older lines are
//     dropped. This is a soft cap so a runaway logger can't OOM the
//     daemon.
//   - Subscribers are channel-based, with a small buffer so a slow
//     consumer doesn't stall the producer. If the buffer fills, the
//     subscriber is dropped — the operator can re-subscribe and pick
//     up the snapshot.

const (
	maxJobLines        = 5000 // ~5 MB of log per job at average line length
	subscriberBuffer   = 64
	finishedRetention  = 10 * time.Minute
)

type JobState string

const (
	JobPending  JobState = "pending"
	JobRunning  JobState = "running"
	JobSucceeded JobState = "succeeded"
	JobFailed   JobState = "failed"
	JobCancelled JobState = "cancelled"
)

// Job is the tracker for a single long-running RPC. Methods that return
// a Job snapshot are safe to call concurrently with the producer.
type Job struct {
	ID        string    `json:"id"`
	Method    string    `json:"method"`         // "apps.install", "apps.upgrade", etc.
	App       string    `json:"app,omitempty"`  // app name when the method is per-app
	StartedAt time.Time `json:"started_at"`
	EndedAt   *time.Time `json:"ended_at,omitempty"`
	State     JobState  `json:"state"`
	ExitCode  *int      `json:"exit_code,omitempty"`

	mu          sync.Mutex
	lines       []jobLine
	subscribers []chan jobLine
	cancel      context.CancelFunc
	dropped     int // count of lines dropped due to maxJobLines
}

type jobLine struct {
	Seq  int       `json:"seq"`
	Time time.Time `json:"time"`
	Text string    `json:"text"`
}

// JobSnapshot is the wire representation served by jobs.status. It's a
// JSON-serializable copy that doesn't expose the mutex / channels.
// Defined with explicit fields rather than embedding Job to avoid the
// `go vet` "passes lock by value" warning that embedding-by-value would
// trigger because Job carries a sync.Mutex.
type JobSnapshot struct {
	ID        string     `json:"id"`
	Method    string     `json:"method"`
	App       string     `json:"app,omitempty"`
	StartedAt time.Time  `json:"started_at"`
	EndedAt   *time.Time `json:"ended_at,omitempty"`
	State     JobState   `json:"state"`
	ExitCode  *int       `json:"exit_code,omitempty"`
	Lines     []jobLine  `json:"lines"`
	Dropped   int        `json:"dropped_lines"`
	LineCount int        `json:"line_count"`
}

// JobStore owns every Job in flight. It's safe to call concurrently
// from multiple HandleConn goroutines.
type JobStore struct {
	mu   sync.Mutex
	jobs map[string]*Job
}

func NewJobStore() *JobStore {
	js := &JobStore{jobs: make(map[string]*Job)}
	go js.gc()
	return js
}

// Begin creates and registers a new Job. The returned cancel func should
// be wired to the goroutine's ctx so jobs.cancel can stop the subprocess.
func (s *JobStore) Begin(method, app string) (*Job, context.Context) {
	id := newJobID()
	ctx, cancel := context.WithCancel(context.Background())
	j := &Job{
		ID:        id,
		Method:    method,
		App:       app,
		StartedAt: time.Now().UTC(),
		State:     JobPending,
		cancel:    cancel,
	}
	s.mu.Lock()
	s.jobs[id] = j
	s.mu.Unlock()
	return j, ctx
}

func (s *JobStore) Get(id string) (*Job, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	j, ok := s.jobs[id]
	return j, ok
}

func (s *JobStore) List() []*Job {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*Job, 0, len(s.jobs))
	for _, j := range s.jobs {
		out = append(out, j)
	}
	return out
}

// gc periodically reaps finished jobs older than finishedRetention.
// Keeps the daemon's memory bounded under heavy churn while still
// giving a slow operator time to fetch the final logs.
func (s *JobStore) gc() {
	t := time.NewTicker(finishedRetention / 2)
	defer t.Stop()
	for range t.C {
		now := time.Now()
		s.mu.Lock()
		for id, j := range s.jobs {
			j.mu.Lock()
			finished := j.EndedAt != nil && now.Sub(*j.EndedAt) > finishedRetention
			j.mu.Unlock()
			if finished {
				delete(s.jobs, id)
			}
		}
		s.mu.Unlock()
	}
}

// ---------- Job methods ----------

// MarkRunning transitions Pending → Running. Called by the runner
// goroutine just before it spawns the subprocess.
func (j *Job) MarkRunning() {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.State = JobRunning
}

// Append adds a line to the buffer and fans out to subscribers. Drops
// the line if the cap is exceeded; a slow subscriber gets dropped from
// the list (their channel is closed) instead of stalling the producer.
func (j *Job) Append(text string) {
	now := time.Now().UTC()
	j.mu.Lock()
	defer j.mu.Unlock()

	seq := len(j.lines) + j.dropped
	line := jobLine{Seq: seq, Time: now, Text: text}

	if len(j.lines) >= maxJobLines {
		// Drop the oldest line to keep the cap. The dropped counter
		// makes the loss visible in JobSnapshot.
		j.lines = j.lines[1:]
		j.dropped++
	}
	j.lines = append(j.lines, line)

	// Fan out to subscribers. Build a new slice excluding any whose
	// channels are full (we treat those as dropped).
	var live []chan jobLine
	for _, ch := range j.subscribers {
		select {
		case ch <- line:
			live = append(live, ch)
		default:
			close(ch)
		}
	}
	j.subscribers = live
}

// Finish marks the job done. exitCode == 0 → succeeded; non-zero or err
// non-nil → failed. Closes every subscriber so jobs.stream callers
// know to disconnect.
func (j *Job) Finish(exitCode int, err error) {
	now := time.Now().UTC()
	j.mu.Lock()
	defer j.mu.Unlock()
	j.EndedAt = &now
	j.ExitCode = &exitCode
	switch {
	case err != nil:
		j.State = JobFailed
	case exitCode == 0:
		j.State = JobSucceeded
	default:
		j.State = JobFailed
	}
	for _, ch := range j.subscribers {
		close(ch)
	}
	j.subscribers = nil
}

// Cancel aborts the underlying subprocess. Idempotent; multiple calls
// from concurrent jobs.cancel RPCs all converge on the same outcome.
func (j *Job) Cancel() {
	j.mu.Lock()
	c := j.cancel
	j.State = JobCancelled
	j.mu.Unlock()
	if c != nil {
		c()
	}
}

// Subscribe returns a channel that will receive every subsequent Append
// until the job finishes (then the channel is closed). The buffer is
// small; a slow consumer gets dropped without blocking the producer.
//
// Use case: jobs.stream — the handler reads from the returned chan and
// forwards each line to the connection.
func (j *Job) Subscribe() chan jobLine {
	ch := make(chan jobLine, subscriberBuffer)
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.EndedAt != nil {
		// Job already finished — return a closed channel so the caller's
		// range loop exits immediately. The Snapshot they fetched before
		// subscribing already has the final lines.
		close(ch)
		return ch
	}
	j.subscribers = append(j.subscribers, ch)
	return ch
}

// Snapshot returns a JSON-serializable copy of the job state, including
// every line currently buffered.
func (j *Job) Snapshot() JobSnapshot {
	j.mu.Lock()
	defer j.mu.Unlock()
	cpyLines := make([]jobLine, len(j.lines))
	copy(cpyLines, j.lines)
	return JobSnapshot{
		ID:        j.ID,
		Method:    j.Method,
		App:       j.App,
		StartedAt: j.StartedAt,
		EndedAt:   j.EndedAt,
		State:     j.State,
		ExitCode:  j.ExitCode,
		Lines:     cpyLines,
		Dropped:   j.dropped,
		LineCount: len(cpyLines),
	}
}

// ---------- helpers ----------

// newJobID returns a 16-hex-char (8-byte) random identifier. Sufficient
// uniqueness: 2^64 space, jobs are short-lived (~minutes), collisions
// would surface as a lookup miss not data corruption.
func newJobID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand failure is unrecoverable — vibed can't generate
		// safe IDs. Fall back to a time-based ID and trust that no
		// admin app will see the collision.
		return "fallback-" + time.Now().UTC().Format("20060102T150405.000000")
	}
	return hex.EncodeToString(b[:])
}

// runJobSubprocess is the canonical "long-running vibe call" worker. It
// invokes runVibeStream, fans every line into the job, and Finishes the
// job on exit. The handler that called Begin should call this in a
// goroutine and return the job ID immediately.
func runJobSubprocess(ctx context.Context, j *Job, cfg *Config, args []string) {
	runJobSubprocessWithEnv(ctx, j, cfg, nil, args)
}

// runJobSubprocessWithEnv is the env-aware variant of runJobSubprocess.
// Use it when a handler needs to inject a per-call secret (e.g.
// TAILSCALE_AUTHKEY for integrations.tailscale.install) without
// touching the daemon's global env. The extra env vars are appended
// to inheritedEnv() — last-wins on duplicate keys.
func runJobSubprocessWithEnv(ctx context.Context, j *Job, cfg *Config, extraEnv []string, args []string) {
	j.MarkRunning()
	j.Append("[vibed] running: vibe " + joinArgs(args))

	w := newLineWriter(j)
	err := runVibeStreamWithEnv(ctx, cfg, extraEnv, w, args...)
	w.Flush()

	exit := 0
	if err != nil {
		exit = 1
		j.Append("[vibed] error: " + err.Error())
	}
	j.Finish(exit, err)
}

func joinArgs(args []string) string {
	out := ""
	for i, a := range args {
		if i > 0 {
			out += " "
		}
		out += a
	}
	return out
}
