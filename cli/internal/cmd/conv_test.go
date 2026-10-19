package cmd

import (
	"errors"
	"strings"
	"testing"
)

// handleStageEvent is the terminal-condition decision for the stream loop.
// The `data` maps below mirror the SSE payload write_event renders
// (conversation_controller.ex): stage/state at the top level, and the
// publish_stage meta as a JSON-encoded STRING under "data"
// (conversation_server.ex publishes `turn`/`done` with exit_code, turn_id,
// turn_number).
func TestHandleStageEvent(t *testing.T) {
	cases := []struct {
		name     string
		data     map[string]any
		terminal bool
		wantErr  error
	}{
		{
			name: "turn done exit 0 is a clean terminal",
			data: map[string]any{
				"stage": "turn", "state": "done",
				"data": `{"exit_code":0,"turn_id":"t-1","turn_number":2}`,
			},
			terminal: true,
			wantErr:  nil,
		},
		{
			name: "turn done with non-zero exit_code fails",
			data: map[string]any{
				"stage": "turn", "state": "done",
				"data": `{"exit_code":2,"turn_id":"t-1","turn_number":2}`,
			},
			terminal: true,
			wantErr:  errTurnFailed,
		},
		{
			name:     "turn done without payload defaults to clean",
			data:     map[string]any{"stage": "turn", "state": "done"},
			terminal: true,
			wantErr:  nil,
		},
		{
			name:     "turn failed",
			data:     map[string]any{"stage": "turn", "state": "failed", "data": "{}"},
			terminal: true,
			wantErr:  errTurnFailed,
		},
		{
			name: "turn failed with a reason is still errTurnFailed",
			data: map[string]any{
				"stage": "turn", "state": "failed",
				"data": `{"reason":"acp: {:acp_error, :prompt, %{\"code\" => -32000, \"message\" => \"Authentication required\"}}"}`,
			},
			terminal: true,
			wantErr:  errTurnFailed,
		},
		{
			name: "provision failed",
			data: map[string]any{
				"stage": "provision", "state": "failed",
				"data": `{"reason":"provision deadline exceeded"}`,
			},
			terminal: true,
			wantErr:  errProvisionFailed,
		},
		{
			name:     "terminate done is a clean terminal",
			data:     map[string]any{"stage": "terminate", "state": "done", "data": "{}"},
			terminal: true,
			wantErr:  nil,
		},
		{
			name:     "provision started is not terminal",
			data:     map[string]any{"stage": "provision", "state": "started", "data": "{}"},
			terminal: false,
			wantErr:  nil,
		},
		{
			name:     "setup failed is not terminal (a turn may still run)",
			data:     map[string]any{"stage": "setup", "state": "failed", "data": `{"exit_code":1}`},
			terminal: false,
			wantErr:  nil,
		},
		{
			// After `managoat conv interrupt` from another shell, the stream
			// used to sit out the full idle timeout and exit 1.
			name:     "turn interrupted is a clean terminal",
			data:     map[string]any{"stage": "turn", "state": "interrupted", "data": "{}"},
			terminal: true,
			wantErr:  nil,
		},
		{
			// ADR 0097: the ceiling parks a workspace's machine and cuts
			// every running turn on it first; the work did not finish.
			name:     "a turn cut by the ceiling's park fails",
			data:     map[string]any{"stage": "turn", "state": "interrupted", "data": `{"reason":"machine_parked"}`},
			terminal: true,
			wantErr:  errSandboxExpired,
		},
		{
			name:     "a turn cut by its machine's destroy fails",
			data:     map[string]any{"stage": "turn", "state": "interrupted", "data": `{"reason":"machine_destroyed"}`},
			terminal: true,
			wantErr:  errMachineDestroyed,
		},
		{
			// The server stops after publishing this (conversation_server.ex),
			// so nothing more is coming.
			name:     "reattach failed is terminal and fails",
			data:     map[string]any{"stage": "reattach", "state": "failed", "data": `{"reason":"gone"}`},
			terminal: true,
			wantErr:  errReattachFailed,
		},
		{
			// #799: a transient failure leaves the sandbox untouched. Still
			// terminal for the stream — the server stopped — and still an
			// error exit, but the message tells the caller to just retry.
			name:     "transient reattach failure is terminal and fails",
			data:     map[string]any{"stage": "reattach", "state": "failed", "data": `{"reason":"{:unavailable, :nxdomain}","retryable":true}`},
			terminal: true,
			wantErr:  errReattachFailed,
		},
		{
			// A failed provisioning step is followed by provision/failed,
			// which is the terminal one — the stream must keep going.
			name:     "a failed provisioning step is not terminal (provision failed follows)",
			data:     map[string]any{"stage": "packages", "state": "failed", "data": "{}"},
			terminal: false,
			wantErr:  nil,
		},
		{
			// Idle suspend keeps the sprite: a clean end, resumable with
			// the agent's memory intact.
			name:     "sandbox suspended for idleness is a clean terminal",
			data:     map[string]any{"stage": "sandbox", "state": "done", "data": `{"event":"suspended","reason":"idle"}`},
			terminal: true,
			wantErr:  nil,
		},
		{
			// An old server can still send the pre-0017 idle reclaim; it
			// stays a clean exit.
			name:     "legacy idle reclaim is a clean terminal",
			data:     map[string]any{"stage": "sandbox", "state": "done", "data": `{"event":"reclaimed","reason":"idle"}`},
			terminal: true,
			wantErr:  nil,
		},
		{
			// A max-lifetime reclaim can cut a running turn short.
			name:     "sandbox reclaimed at max lifetime fails",
			data:     map[string]any{"stage": "sandbox", "state": "done", "data": `{"event":"reclaimed","reason":"max_lifetime"}`},
			terminal: true,
			wantErr:  errSandboxExpired,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			terminal, err := handleStageEvent(tc.data)
			if terminal != tc.terminal {
				t.Errorf("terminal: got %v, want %v", terminal, tc.terminal)
			}
			if tc.wantErr == nil && err != nil {
				t.Errorf("err: got %v, want nil", err)
			}
			if tc.wantErr != nil && !errors.Is(err, tc.wantErr) {
				t.Errorf("err: got %v, want %v", err, tc.wantErr)
			}
		})
	}
}

// Setup and provisioning stages log raw text. Routing everything through the JSON formatter made a failing
// `apt install` or `git clone` produce zero visible output.
func TestFormatOutputByStage(t *testing.T) {
	setup := map[string]any{
		"stream": "stdout",
		"stage":  "setup",
		"data":   "E: Unable to locate package libweird",
	}
	if got := formatOutput(setup); got != "E: Unable to locate package libweird\n" {
		t.Errorf("setup-stage output was not passed through verbatim: %q", got)
	}

	packages := map[string]any{
		"stream": "stdout",
		"stage":  "packages",
		"data":   "installing 3 packages\n",
	}
	if got := formatOutput(packages); got != "installing 3 packages\n" {
		t.Errorf("packages-stage output was not passed through: %q", got)
	}

}

// lastEventIDIn extracts the stream head from a `?wait=false` drain, which is
// what lets conv prompt / conv stream skip the history replay (#398).
func TestLastEventIDIn(t *testing.T) {
	drained := "id: 1\nevent: stage\ndata: {\"stage\":\"provision\",\"state\":\"done\"}\n\n" +
		"id: 2\nevent: output\ndata: {\"stream\":\"stdout\",\"data\":\"hi\"}\n\n" +
		"id: 3\nevent: stage\ndata: {\"stage\":\"turn\",\"state\":\"done\"}\n\n"

	if got := lastEventIDIn(drained); got != "3" {
		t.Errorf("head: got %q, want \"3\"", got)
	}
	if got := lastEventIDIn(""); got != "" {
		t.Errorf("empty drain should have no head, got %q", got)
	}
	// A body whose final event lacks the trailing blank line still counts.
	if got := lastEventIDIn("id: 7\nevent: stage\ndata: {}"); got != "7" {
		t.Errorf("unterminated final event: got %q, want \"7\"", got)
	}
	// Heartbeat comments carry no id and must not confuse the head.
	if got := lastEventIDIn(": heartbeat\n\n"); got != "" {
		t.Errorf("heartbeat-only drain should have no head, got %q", got)
	}
}

// A turn that fails because the runtime was started with no provider
// credential reports "Authentication required"; the CLI names the fix rather
// than leaving a bare "turn failed" (the quickstart's inference-key step).
func TestTurnFailureHint(t *testing.T) {
	reason := `acp: {:acp_error, :prompt, %{"code" => -32000, "message" => "Authentication required"}}`
	if hint := turnFailureHint(reason); !strings.Contains(hint, "Inference keys") {
		t.Fatalf("expected an inference-key hint, got %q", hint)
	}
	if hint := turnFailureHint("acp: peer closed"); hint != "" {
		t.Fatalf("expected no hint for an unrelated reason, got %q", hint)
	}
}
