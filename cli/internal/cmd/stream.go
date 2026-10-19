package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/managoat/managoat/cli/internal/sse"
	"github.com/managoat/managoat/cli/internal/stream"
)

// streamOpener opens an SSE body, resuming after lastEventID when non-empty.
type streamOpener = stream.Opener

// The follow loop itself lives in internal/stream — `managoat acp` needs the
// same reconnect behaviour, and #398 is not a bug worth having two chances to
// reintroduce. What stays here is what the CLI means by an event: exit codes,
// the human lines, and the terminal outcomes below.
var (
	errIdleTimeout = stream.ErrIdleTimeout

	// Terminal outcomes that must surface as a non-zero exit (#398). Before
	// this, `turn`/`failed`, `provision`/`failed` and a `turn`/`done` with a
	// non-zero exit_code all returned nil, so `managoat run` in CI reported
	// success for a crashed agent or a sandbox that never came up.
	errTurnFailed       = errors.New("turn failed")
	errProvisionFailed  = errors.New("provisioning failed — the sandbox never started")
	errReattachFailed   = errors.New("reattach failed — the sandbox could not be re-armed")
	errSandboxExpired   = errors.New("sandbox hit its max lifetime")
	errMachineDestroyed = errors.New("the turn's machine was destroyed")
	errPromptNotStarted = errors.New("prompt was not started — send it again shortly")
)

// streamIdleTimeout allows the wait to be widened or narrowed without a rebuild.
func streamIdleTimeout() time.Duration { return stream.IdleTimeout() }

// followStream consumes an SSE stream until the turn reaches a terminal state,
// printing output as it goes. See internal/stream for the reconnect semantics
// and handleEvent (conv.go) for what the CLI does with each event.
func followStream(open streamOpener, idle time.Duration, convID, lastEventID string, requestID ...string) error {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	reported := false
	started := false
	handler := func(ev sse.Event) (bool, error) {
		if data, ok := ev.Data.(map[string]any); ok && ev.Event == "stage" {
			if data["stage"] == "turn" && data["state"] == "started" {
				started = true
			}
			if data["stage"] == "wake" && data["state"] == "failed" {
				if started {
					return false, nil
				}
				actual := innerDataString(data, "client_request_id")
				if len(requestID) > 0 && requestID[0] != "" && actual != "" && actual != requestID[0] {
					return false, nil
				}
			}
		}
		return handleEvent(ev)
	}
	return stream.Follow(ctx, open, idle, convID, lastEventID, handler, func(attempt int, delay time.Duration, err error) {
		if !reported {
			reported = true
			fmt.Fprintf(os.Stderr, "▸ stream temporarily unavailable; reconnecting for up to %s without replaying the prompt: %v\n", stream.RecoveryTimeout(), err)
		}
	})
}

// Compile-time proof the opener signature has not drifted from the package it
// now comes from; the alias above would otherwise fail far from here.
var _ func(context.Context, string) (io.ReadCloser, error) = (streamOpener)(nil)
