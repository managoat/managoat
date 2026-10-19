package acp

import (
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
)

// fakeNotifier records what the editor would have seen.
type fakeNotifier struct {
	mu       sync.Mutex
	methods  []string
	params   []map[string]any
	rawCalls int
}

func (n *fakeNotifier) Notify(method string, params any) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.rawCalls++
	n.methods = append(n.methods, method)
	if m, ok := params.(map[string]any); ok {
		n.params = append(n.params, m)
	}
}

func acpLine(sessionID, text string) string {
	return `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"` + sessionID +
		`","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"` + text + `"}}}}`
}

func stageEvent(stage, state, meta string) Event {
	return Event{Kind: "stage", Stage: stage, State: state, Data: meta}
}

// promptAgent returns an agent with one open session, ready to prompt.
func promptAgent(t *testing.T, api *fakeAPI) (*Agent, *fakeNotifier) {
	t.Helper()

	api.ref = acpAgentRef()
	if api.convID == "" {
		api.convID = "conv-1"
	}
	a := sessionAgent(t, api, "researcher")
	n := &fakeNotifier{}
	a.SetNotifier(n)

	if _, rpcErr := request(t, a, "session/new", map[string]any{}); rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}
	return a, n
}

func textPrompt(sessionID, text string) map[string]any {
	return map[string]any{
		"sessionId": sessionID,
		"prompt":    []map[string]any{{"type": "text", "text": text}},
	}
}

func TestPromptForwardsUpdatesAndReturnsTheStopReason(t *testing.T) {
	api := &fakeAPI{
		events: []Event{
			{Kind: "output", Stream: "acp", Data: acpLine("sprite-session", "hello")},
			stageEvent("turn", "done", `{"stop_reason":"end_turn"}`),
		},
	}
	a, notifier := promptAgent(t, api)

	result, rpcErr := request(t, a, "session/prompt", textPrompt("conv-1", "do the thing"))
	if rpcErr != nil {
		t.Fatalf("session/prompt failed: %v", rpcErr)
	}
	if result["stopReason"] != "end_turn" {
		t.Errorf("stopReason = %v, want end_turn", result["stopReason"])
	}
	if len(notifier.methods) != 1 || notifier.methods[0] != "session/update" {
		t.Fatalf("notifications = %v, want one session/update", notifier.methods)
	}
	if len(api.prompts) != 1 || api.prompts[0].text != "do the thing" {
		t.Errorf("prompts = %+v, want the text posted once", api.prompts)
	}
}

func TestPromptClientRequestIDBelongsToEachSubmission(t *testing.T) {
	api := &fakeAPI{events: []Event{stageEvent("turn", "done", `{"stop_reason":"end_turn"}`)}}
	a, _ := promptAgent(t, api)

	for _, tc := range []struct {
		name string
		meta map[string]any
		want *string
	}{
		{name: "first", meta: map[string]any{"clientRequestId": "plan-7-step-1"}, want: new("plan-7-step-1")},
		{name: "follow-up", meta: map[string]any{"clientRequestId": " plan-7-步骤-2 "}, want: new(" plan-7-步骤-2 ")},
		{name: "omitted after a named prompt"},
		{name: "unrelated metadata", meta: map[string]any{"editor": "test"}},
		{name: "null", meta: map[string]any{"clientRequestId": nil}},
		{name: "empty stays supplied", meta: map[string]any{"clientRequestId": ""}, want: new("")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			params := textPrompt("conv-1", "continue")
			if tc.meta != nil {
				params["_meta"] = tc.meta
			}
			before := len(api.prompts)
			if _, rpcErr := request(t, a, "session/prompt", params); rpcErr != nil {
				t.Fatal(rpcErr)
			}
			if len(api.prompts) != before+1 {
				t.Fatalf("sent %d prompts, want one", len(api.prompts)-before)
			}
			got := api.prompts[before].clientRequestID
			if tc.want == nil {
				if got != nil {
					t.Fatalf("omitted clientRequestId became %q", *got)
				}
			} else if got == nil || *got != *tc.want {
				t.Fatalf("clientRequestId = %v, want %q", got, *tc.want)
			}
		})
	}
}

func TestPromptRejectsNonStringClientRequestID(t *testing.T) {
	for _, value := range []any{42, true, []string{"id"}, map[string]any{"id": "value"}} {
		api := &fakeAPI{}
		a, _ := promptAgent(t, api)
		params := textPrompt("conv-1", "go")
		params["_meta"] = map[string]any{"clientRequestId": value}
		_, rpcErr := request(t, a, "session/prompt", params)
		if rpcErr == nil || rpcErr.Code != CodeInvalidParams {
			t.Fatalf("clientRequestId %v: got %v, want invalid params", value, rpcErr)
		}
		if len(api.prompts) != 0 {
			t.Fatal("invalid metadata sent a prompt")
		}
	}
}

// The stored update carries the sprite's own session id, which means nothing
// outside the sandbox that holds it (#649). The editor knows this conversation
// by ours.
func TestForwardedUpdateCarriesOurSessionIDNotTheSprites(t *testing.T) {
	api := &fakeAPI{
		events: []Event{
			{Kind: "output", Stream: "acp", Data: acpLine("sprite-session", "hi")},
			stageEvent("turn", "done", `{"stop_reason":"end_turn"}`),
		},
	}
	a, notifier := promptAgent(t, api)

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))

	if len(notifier.params) != 1 {
		t.Fatalf("want one forwarded update, got %d", len(notifier.params))
	}
	if got := notifier.params[0]["sessionId"]; got != "conv-1" {
		t.Errorf("sessionId = %v, want conv-1 (ours), not the sprite's", got)
	}
	// Everything else must survive untouched — the adapter forwards blocks it
	// deliberately does not understand.
	update, ok := notifier.params[0]["update"].(map[string]any)
	if !ok || update["sessionUpdate"] != "agent_message_chunk" {
		t.Errorf("update payload was not forwarded intact: %v", notifier.params[0])
	}
}

// #398, from the other side: the head is learned BEFORE the prompt is posted,
// so a replayed terminal event from a PRIOR turn cannot end this one.
func TestPromptLearnsTheStreamHeadBeforePosting(t *testing.T) {
	api := &fakeAPI{
		head:   "417",
		events: []Event{stageEvent("turn", "done", `{"stop_reason":"end_turn"}`)},
	}
	a, _ := promptAgent(t, api)

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))

	if len(api.followFrom) != 1 || api.followFrom[0] != "417" {
		t.Errorf("followed from %v, want the head learned before the post", api.followFrom)
	}
}

// A refusal is a legitimate ACP stop reason even though the server records the
// turn as failed. Reporting it as an error would tell an editor something
// broke when the agent simply declined.
func TestRefusalIsAStopReasonNotAnError(t *testing.T) {
	api := &fakeAPI{events: []Event{stageEvent("turn", "failed", `{"stop_reason":"refusal"}`)}}
	a, _ := promptAgent(t, api)

	result, rpcErr := request(t, a, "session/prompt", textPrompt("conv-1", "go"))
	if rpcErr != nil {
		t.Fatalf("refusal surfaced as an error: %v", rpcErr)
	}
	if result["stopReason"] != "refusal" {
		t.Errorf("stopReason = %v, want refusal", result["stopReason"])
	}
}

func TestInterruptedTurnIsCancelled(t *testing.T) {
	api := &fakeAPI{events: []Event{stageEvent("turn", "interrupted", `{}`)}}
	a, _ := promptAgent(t, api)

	result, rpcErr := request(t, a, "session/prompt", textPrompt("conv-1", "go"))
	if rpcErr != nil {
		t.Fatalf("interrupt surfaced as an error: %v", rpcErr)
	}
	if result["stopReason"] != "cancelled" {
		t.Errorf("stopReason = %v, want cancelled", result["stopReason"])
	}
}

// The failures ACP has no vocabulary for must not be dressed up as a stop
// reason: "the agent finished" is the one reading that is false.
func TestInfrastructureFailuresAreErrorsNotStopReasons(t *testing.T) {
	cases := []struct {
		name  string
		event Event
		want  string
	}{
		{"provision failed", stageEvent("provision", "failed", `{"reason":"quota"}`), "sandbox never started"},
		{"turn failed", stageEvent("turn", "failed", `{"error":"peer_down"}`), "peer_down"},
		{"reclaimed mid-turn", stageEvent("sandbox", "done", `{"reason":"max_lifetime"}`), "reclaimed"},
		{"terminated", stageEvent("terminate", "done", `{}`), "terminated"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			api := &fakeAPI{events: []Event{tc.event}}
			a, _ := promptAgent(t, api)

			_, rpcErr := request(t, a, "session/prompt", textPrompt("conv-1", "go"))
			if rpcErr == nil {
				t.Fatal("a failed turn reported success")
			}
			if !strings.Contains(rpcErr.Message, tc.want) {
				t.Errorf("message = %q, want it to mention %q", rpcErr.Message, tc.want)
			}
		})
	}
}

// Admission refusal happens before a turn starts. It must reach the editor as
// an error with a retry hint, without claiming the sandbox was reclaimed.
func TestAdmissionRefusalIsAnErrorWithRetryHint(t *testing.T) {
	for _, tc := range []struct {
		event  string
		reason string
	}{
		{"admission_refused", "sandbox_unavailable"},
		{"at_capacity", "sandbox_at_capacity"},
	} {
		t.Run(tc.event, func(t *testing.T) {
			meta, err := json.Marshal(map[string]string{"event": tc.event, "reason": tc.reason})
			if err != nil {
				t.Fatal(err)
			}
			api := &fakeAPI{events: []Event{
				stageEvent("sandbox", "done", string(meta)),
				stageEvent("turn", "done", `{}`),
			}}
			a, _ := promptAgent(t, api)

			_, rpcErr := request(t, a, "session/prompt", textPrompt("conv-1", "go"))
			if rpcErr == nil {
				t.Fatal("refused admission reported a completed turn")
			}
			if rpcErr.Code != CodeInternalError {
				t.Errorf("error code = %d, want %d", rpcErr.Code, CodeInternalError)
			}
			for _, want := range []string{"prompt was not started", tc.reason, "send it again shortly"} {
				if !strings.Contains(rpcErr.Message, want) {
					t.Errorf("message = %q, want %q", rpcErr.Message, want)
				}
			}
			if strings.Contains(rpcErr.Message, "reclaimed") {
				t.Errorf("refused admission reported a sandbox reclaim: %s", rpcErr.Message)
			}
		})
	}
}

// A suspend keeps the sprite and the next prompt resumes it — an end, not a
// failure.
func TestSuspendedSandboxEndsTheTurnCleanly(t *testing.T) {
	api := &fakeAPI{events: []Event{stageEvent("sandbox", "done", `{"event":"suspended","reason":"idle"}`)}}
	a, _ := promptAgent(t, api)

	result, rpcErr := request(t, a, "session/prompt", textPrompt("conv-1", "go"))
	if rpcErr != nil {
		t.Fatalf("a suspend surfaced as an error: %v", rpcErr)
	}
	if result["stopReason"] != "end_turn" {
		t.Errorf("stopReason = %v, want end_turn", result["stopReason"])
	}
}

// A lost stream is not a finished turn. The turn keeps running server-side, so
// the answer says so and names the conversation to reattach to.
func TestLostStreamSaysTheTurnMayStillBeRunning(t *testing.T) {
	api := &fakeAPI{followErr: errors.New("stream failed after 5 attempts")}
	a, _ := promptAgent(t, api)

	_, rpcErr := request(t, a, "session/prompt", textPrompt("conv-1", "go"))
	if rpcErr == nil {
		t.Fatal("a lost stream reported a completed turn")
	}
	if !strings.Contains(rpcErr.Message, "may still be running") {
		t.Errorf("message = %q, want it to say the turn may still be running", rpcErr.Message)
	}
	if !strings.Contains(rpcErr.Message, "conv-1") {
		t.Errorf("message = %q, want it to name the conversation", rpcErr.Message)
	}
}

func TestPromptForAnUnknownSessionIsRefused(t *testing.T) {
	api := &fakeAPI{events: []Event{stageEvent("turn", "done", `{}`)}}
	a, _ := promptAgent(t, api)

	_, rpcErr := request(t, a, "session/prompt", textPrompt("conv-not-mine", "go"))
	if rpcErr == nil || rpcErr.Code != CodeInvalidParams {
		t.Fatalf("want invalid params for an unknown session, got %v", rpcErr)
	}
	if len(api.prompts) != 0 {
		t.Errorf("prompted a session that does not exist: %v", api.prompts)
	}
}

func TestPromptCarriesImages(t *testing.T) {
	api := &fakeAPI{events: []Event{stageEvent("turn", "done", `{"stop_reason":"end_turn"}`)}}
	a, _ := promptAgent(t, api)

	_, rpcErr := request(t, a, "session/prompt", map[string]any{
		"sessionId": "conv-1",
		"prompt": []map[string]any{
			{"type": "text", "text": "what is this"},
			{"type": "image", "data": "aGVsbG8=", "mimeType": "image/png"},
		},
	})
	if rpcErr != nil {
		t.Fatalf("session/prompt failed: %v", rpcErr)
	}

	sent := api.prompts[0]
	if len(sent.images) != 1 || sent.images[0].MediaType != "image/png" || sent.images[0].Data != "aGVsbG8=" {
		t.Errorf("images = %+v, want the one image carried through", sent.images)
	}
	if sent.text != "what is this" {
		t.Errorf("text = %q, want the text block only", sent.text)
	}
}

// A resource link names a file on the developer's machine. Pasting its path
// into the prompt would send the agent looking for something that is not in
// its sandbox, so it is dropped — but the turn still runs.
func TestLocalResourceBlocksAreDroppedNotSent(t *testing.T) {
	api := &fakeAPI{events: []Event{stageEvent("turn", "done", `{"stop_reason":"end_turn"}`)}}
	a, _ := promptAgent(t, api)

	_, rpcErr := request(t, a, "session/prompt", map[string]any{
		"sessionId": "conv-1",
		"prompt": []map[string]any{
			{"type": "text", "text": "review this"},
			{"type": "resource_link", "uri": "file:///home/dev/proj/main.go", "name": "main.go"},
		},
	})
	if rpcErr != nil {
		t.Fatalf("session/prompt failed: %v", rpcErr)
	}
	if got := api.prompts[0].text; got != "review this" {
		t.Errorf("text = %q, want the local path left out", got)
	}
}

func TestEmptyPromptIsRefused(t *testing.T) {
	api := &fakeAPI{}
	a, _ := promptAgent(t, api)

	_, rpcErr := request(t, a, "session/prompt", map[string]any{
		"sessionId": "conv-1",
		"prompt":    []map[string]any{},
	})
	if rpcErr == nil || rpcErr.Code != CodeInvalidParams {
		t.Fatalf("want invalid params for an empty prompt, got %v", rpcErr)
	}
	if len(api.prompts) != 0 {
		t.Errorf("posted an empty prompt: %v", api.prompts)
	}
}

// Runtime output that is not protocol is the adapter's own noise — a stack
// trace, an npm notice. It belongs in the log, not in the editor's transcript.
func TestNonProtocolOutputIsNotForwarded(t *testing.T) {
	api := &fakeAPI{
		events: []Event{
			{Kind: "output", Stream: "stderr", Data: "npm warn deprecated foo@1.0.0"},
			stageEvent("turn", "done", `{"stop_reason":"end_turn"}`),
		},
	}
	a, notifier := promptAgent(t, api)

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))

	if notifier.rawCalls != 0 {
		t.Errorf("forwarded %d notifications for non-protocol output, want 0", notifier.rawCalls)
	}
}

// A request from the sprite (session/request_permission) is not an update, and
// forwarding it as one would put a question in the transcript that nothing can
// answer. Answering it across two hops is #708.
func TestSpriteRequestsAreNotForwardedAsUpdates(t *testing.T) {
	api := &fakeAPI{
		events: []Event{
			{Kind: "output", Stream: "acp", Data: `{"jsonrpc":"2.0","id":4,"method":"session/request_permission","params":{}}`},
			stageEvent("turn", "done", `{"stop_reason":"end_turn"}`),
		},
	}
	a, notifier := promptAgent(t, api)

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))

	if notifier.rawCalls != 0 {
		t.Errorf("forwarded %d messages that were not updates, want 0", notifier.rawCalls)
	}
}

// #724: a refused model does not end the turn — the runtime answers on its
// default — so the stage must not be treated as terminal. It is surfaced in
// the adapter's log instead, which is where an editor's agent-server output
// goes.
func TestARefusedModelDoesNotEndTheTurn(t *testing.T) {
	api := &fakeAPI{
		events: []Event{
			stageEvent("model", "failed", `{"requested":"claude-sonnet-4-6","detail":"Invalid value"}`),
			{Kind: "output", Stream: "acp", Data: acpLine("sprite-session", "answered anyway")},
			stageEvent("turn", "done", `{"stop_reason":"end_turn"}`),
		},
	}
	a, notifier := promptAgent(t, api)

	result, rpcErr := request(t, a, "session/prompt", textPrompt("conv-1", "go"))
	if rpcErr != nil {
		t.Fatalf("a refused model failed the turn: %v", rpcErr)
	}
	if result["stopReason"] != "end_turn" {
		t.Errorf("stopReason = %v, want end_turn", result["stopReason"])
	}
	if len(notifier.methods) != 1 {
		t.Errorf("forwarded %d updates, want the one that came after the refusal", len(notifier.methods))
	}
}

func TestWakeFailureReportsUnrunPrompt(t *testing.T) {
	outcome, terminal := classifyStage(Event{Stage: "wake", State: "failed", Data: `{"reason":"deployment_interrupted","retryable":true}`})
	if !terminal || outcome.err != "prompt did not run: deployment_interrupted (retryable=true); no prompt was replayed" {
		t.Fatalf("terminal=%v outcome=%+v", terminal, outcome)
	}
}

func TestWakeFailureCarriesItsAdvice(t *testing.T) {
	outcome, terminal := classifyStage(Event{Stage: "wake", State: "failed", Data: `{"reason":"sandbox_provider_disabled","retryable":false,"advice":"set its credentials"}`})
	want := "prompt did not run: sandbox_provider_disabled (retryable=false); no prompt was replayed — set its credentials"
	if !terminal || outcome.err != want {
		t.Fatalf("terminal=%v outcome=%+v", terminal, outcome)
	}
}
