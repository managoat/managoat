package acp

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
)

// Event is one event from a conversation's SSE stream, already decoded far
// enough for the adapter to act on. The HTTP and SSE details stay in the CLI
// layer; this package sees only what an event says.
type Event struct {
	Kind   string // "output" or "stage"
	Stream string // output only: "acp", "stdout", "stderr"
	Data   string // output: the raw line. stage: JSON-encoded metadata.
	Stage  string // stage only: "turn", "provision", "sandbox", …
	State  string // stage only: "started", "done", "failed", "interrupted"
}

// EventFunc consumes stream events until it reports stop.
type EventFunc func(ev Event) (stop bool, err error)

// Image is one image attached to a prompt, as the API takes it.
type Image struct {
	Data      string // base64
	MediaType string
}

// Notifier sends a notification to the connected client. The connection
// implements it; the agent holds it so a turn's updates can be forwarded as
// they arrive rather than accumulated and sent at the end.
type Notifier interface {
	Notify(method string, params any)
}

// SetNotifier wires the agent to its connection. Separate from NewAgent
// because the connection needs the agent as a handler and the agent needs the
// connection as a notifier.
func (a *Agent) SetNotifier(n Notifier) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.notifier = n
}

func (a *Agent) notify(method string, params any) {
	a.mu.Lock()
	n := a.notifier
	a.mu.Unlock()
	if n != nil {
		n.Notify(method, params)
	}
}

// requester is the connection, when it can carry a request to the client as
// well as notifications. A Notifier that cannot is not an error — it means
// nothing can be asked, and `forwardPermission` says so and lets the request
// be answered by another client or denied by the server's timeout.
func (a *Agent) requester() (Requester, bool) {
	a.mu.Lock()
	n := a.notifier
	a.mu.Unlock()
	r, ok := n.(Requester)
	return r, ok
}

type promptParams struct {
	SessionID string            `json:"sessionId"`
	Prompt    []json.RawMessage `json:"prompt"`
	// ClientRequestID names this submission, not the session or JSON-RPC
	// request. A pointer preserves an explicitly empty value for API validation.
	Meta struct {
		ClientRequestID *string `json:"clientRequestId"`
	} `json:"_meta"`
}

type contentBlock struct {
	Type     string `json:"type"`
	Text     string `json:"text"`
	Data     string `json:"data"`
	MimeType string `json:"mimeType"`
	URI      string `json:"uri"`
	Name     string `json:"name"`
}

// prompt runs one turn and blocks until it ends, which is what ACP requires of
// `session/prompt` — the response IS the turn's outcome.
//
// Fountain's API is post-then-stream, so the turn's end has to be correlated
// out of the event stream. That correlation is the same one `managoat run`
// performs to produce a truthful exit code (#398), including its hardest
// lesson: learn the stream head BEFORE posting the prompt, or the first
// terminal event in the replay of a PRIOR turn ends this one before it starts.
func (a *Agent) prompt(ctx context.Context, raw json.RawMessage) (any, error) {
	var params promptParams
	if err := json.Unmarshal(raw, &params); err != nil {
		return nil, Errorf(CodeInvalidParams, "session/prompt: %s", err)
	}

	if err := a.requireReady(); err != nil {
		return nil, err
	}

	sess, ok := a.sessions.get(params.SessionID)
	if !ok {
		return nil, Errorf(CodeInvalidParams, "unknown session %q", params.SessionID)
	}

	text, images, err := splitPrompt(params.Prompt, a.log)
	if err != nil {
		return nil, err
	}

	head, err := a.api.StreamHead(ctx, sess.ID)
	if err != nil {
		return nil, Errorf(CodeInternalError, "could not read the conversation stream: %s", err)
	}

	if err := a.api.SendPrompt(ctx, sess.ID, text, images, params.Meta.ClientRequestID); err != nil {
		return nil, Errorf(CodeInternalError, "could not send the prompt: %s", err)
	}

	return a.followTurn(ctx, sess, head, params.Meta.ClientRequestID)
}

// followTurn forwards the turn's updates to the editor and returns its stop
// reason.
func (a *Agent) followTurn(ctx context.Context, sess Session, head string, submittedID *string) (any, error) {
	started := false
	var outcome turnOutcome

	err := a.api.Follow(ctx, sess.ID, head, func(ev Event) (bool, error) {
		switch {
		case ev.Kind == "output" && ev.Stream == "acp":
			if req, ok := a.decodePermission(ev.Data); ok {
				// The agent is blocked in the sandbox until someone answers.
				// Asking runs on its own goroutine so the stream keeps being
				// read — the resolution arrives on it, and so does the turn's
				// end if another client answers first.
				go a.forwardPermission(ctx, sess, ev.Data)
				a.log.Debug("forwarding a permission request", "request", requestID(req.ID))
				return false, nil
			}
			a.forwardUpdate(sess, ev.Data)
			return false, nil

		case ev.Kind == "output":
			// stdout/stderr on an ACP conversation is the adapter's own
			// diagnostics, not the agent talking. It belongs in the log, not
			// in the editor's transcript.
			a.log.Debug("runtime output outside the protocol", "stream", ev.Stream, "data", ev.Data)
			return false, nil

		case ev.Kind == "stage":
			if ev.Stage == "turn" && ev.State == "started" {
				started = true
			}
			if ev.Stage == "wake" && ev.State == "failed" {
				meta := decodeMeta(ev.Data)
				actual, _ := meta["client_request_id"].(string)
				if started || (submittedID != nil && actual != "" && actual != *submittedID) {
					return false, nil
				}
			}
			out, terminal := classifyStage(ev)
			if !terminal {
				// A refused model is the one non-terminal stage worth raising:
				// the turn continues on the runtime's default, so the editor
				// would otherwise have no way to know a different model
				// answered (#724).
				if ev.Stage == "model" && ev.State == "failed" {
					meta := decodeMeta(ev.Data)
					a.log.Warn("the runtime refused the agent's model; its default is in use",
						"requested", meta["requested"], "detail", meta["detail"])
				} else {
					a.log.Debug("stage", "stage", ev.Stage, "state", ev.State)
				}
				return false, nil
			}
			outcome = out
			return true, nil
		}
		return false, nil
	})

	if err != nil {
		// A transport failure after the prompt was accepted: the turn is still
		// running server-side. Saying so is the honest answer — the editor's
		// alternative reading, that the agent stopped, is the one thing we
		// know to be false.
		return nil, Errorf(CodeInternalError,
			"lost the conversation stream (%s) — the turn may still be running; it is conversation %s",
			err, sess.ID)
	}

	if outcome.err != "" {
		return nil, Errorf(CodeInternalError, "%s", outcome.err)
	}
	return map[string]any{"stopReason": outcome.stopReason}, nil
}

// forwardUpdate re-emits one stored ACP line to the editor.
//
// This is the whole payoff of #644: the line is already a `session/update`
// notification, because the server stored what the sprite's adapter said,
// verbatim. The adapter forwards it rather than translating it, and no
// runtime dialect is parsed anywhere in this binary.
//
// One field must change. The stored update carries the *sprite's* session id —
// the runtime's own, which means nothing outside the sandbox holding it and
// does not survive a reclaim (#649). The editor knows this conversation by our
// session id, so that is what leaves this process.
func (a *Agent) forwardUpdate(sess Session, line string) {
	var msg struct {
		Method string         `json:"method"`
		Params map[string]any `json:"params"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &msg); err != nil {
		a.log.Warn("dropping unparseable stored line", "err", err)
		return
	}

	if msg.Method != "session/update" {
		// A `session/request_permission` is a *request*, not an update: it is
		// forwarded from the live turn loop (see followTurn), where there is a
		// context to answer within. Anything else the sprite's adapter sent
		// upward is not ours to relay.
		a.log.Debug("not forwarding a non-update message", "method", msg.Method)
		return
	}

	if msg.Params == nil {
		msg.Params = map[string]any{}
	}
	msg.Params["sessionId"] = sess.ID
	a.moveSandboxLocations(msg.Params)
	a.notify("session/update", msg.Params)
}

// MetaSandboxLocations is where a tool call's file locations go instead of
// `locations`. An editor that learns to read it can show them as remote; every
// other editor simply does not act on paths it never received.
const MetaSandboxLocations = "managoat.sandboxLocations"

// moveSandboxLocations takes `locations` off a tool call and files it under
// `_meta`.
//
// ACP's `tool_call.locations` exists so an editor can follow along: open the
// file, jump to the line. Every path a Fountain agent reports is a path in the
// **sandbox**, on a checkout the sprite made, on a machine that is not the
// developer's. An editor that takes `/workspace/lib/foo.ex` at face value
// either opens the wrong file or silently fails, and the developer concludes
// the agent is editing their project. ADR 0015: "Every design that pretends
// otherwise produces an agent that appears to be editing the open project and
// is not."
//
// The protocol has no way to say "this path is somewhere else", so the honest
// options were to label or to remove. This removes — and keeps the paths under
// `_meta`, so nothing is lost for a client that grows the ability to fetch a
// sandbox file (the read-through escalation ADR 0015 parks as a separate
// decision), and nothing is actionable for one that has not.
//
// The paths remain visible to the human either way: the sprite's own tool
// title and raw input carry them, and the server's block translation already
// falls back to `rawInput` when there are no locations.
func (a *Agent) moveSandboxLocations(params map[string]any) {
	update, ok := params["update"].(map[string]any)
	if !ok {
		return
	}
	locations, ok := update["locations"]
	if !ok || locations == nil {
		return
	}

	delete(update, "locations")

	meta, ok := update["_meta"].(map[string]any)
	if !ok {
		meta = map[string]any{}
	}
	meta[MetaSandboxLocations] = locations
	update["_meta"] = meta

	a.log.Debug("moved sandbox paths out of tool_call.locations",
		"why", "they name files in the sandbox, not on this machine")
}

type turnOutcome struct {
	stopReason string
	err        string // non-empty means the turn did not end, it failed
}

// classifyStage decides whether a stage event ends the turn, and how.
//
// The stop reason is not invented here: the server publishes the sprite
// adapter's own ACP stop reason on the terminal stage event, so a refusal
// arrives as "refusal" and an ordinary finish as "end_turn". What this adds is
// the cases ACP has no vocabulary for — a sandbox that never provisioned, a
// reclaim mid-turn — which are reported as errors rather than dressed up as a
// stop reason, because "the agent finished" is the one reading that is false.
func classifyStage(ev Event) (turnOutcome, bool) {
	meta := decodeMeta(ev.Data)
	stopReason, _ := meta["stop_reason"].(string)

	switch {
	case ev.Stage == "turn" && ev.State == "done":
		if stopReason == "" {
			stopReason = "end_turn"
		}
		return turnOutcome{stopReason: stopReason}, true

	case ev.Stage == "turn" && ev.State == "failed":
		// A refusal and a cancellation are reported as failures server-side
		// (conversation_server.ex) but they ARE ACP stop reasons — an editor
		// should render "the agent declined", not "something broke".
		if stopReason != "" {
			return turnOutcome{stopReason: stopReason}, true
		}
		return turnOutcome{err: "the turn failed: " + reasonText(meta)}, true

	case ev.Stage == "turn" && ev.State == "interrupted":
		return turnOutcome{stopReason: "cancelled"}, true

	case ev.Stage == "wake" && ev.State == "failed":
		err := fmt.Sprintf("prompt did not run: %s (retryable=%v); no prompt was replayed", reasonText(meta), meta["retryable"])
		// What to change, when the refusal says (#3004).
		if advice, ok := meta["advice"].(string); ok && advice != "" {
			err += " — " + advice
		}
		return turnOutcome{err: err}, true

	case ev.Stage == "provision" && ev.State == "failed":
		return turnOutcome{err: "the sandbox never started: " + reasonText(meta)}, true

	case ev.Stage == "reattach" && ev.State == "failed":
		// A refusal that says what to change, such as the machine's provider
		// having been disabled, which no prompt again gets past (#3004).
		if advice, ok := meta["advice"].(string); ok && advice != "" {
			return turnOutcome{err: "could not reattach to the sandbox: " + reasonText(meta) + " — " + advice}, true
		}
		return turnOutcome{err: "could not reattach to the sandbox — prompt again to provision a fresh one"}, true

	case ev.Stage == "terminate" && ev.State == "done":
		return turnOutcome{err: "the conversation was terminated"}, true

	case ev.Stage == "sandbox" && ev.State == "done":
		switch event, _ := meta["event"].(string); event {
		case "admission_refused", "at_capacity":
			return turnOutcome{err: "the prompt was not started (" + reasonText(meta) + ") — send it again shortly"}, true
		case "suspended":
			// Idle suspend keeps the sprite and the next prompt resumes it.
			return turnOutcome{stopReason: "end_turn"}, true
		}
		// A max-lifetime reclaim can cut a running turn short.
		return turnOutcome{err: "the sandbox was reclaimed mid-turn: " + reasonText(meta)}, true
	}

	return turnOutcome{}, false
}

// decodeMeta reads a stage event's metadata, which the server JSON-encodes
// into the event's data field.
func decodeMeta(data string) map[string]any {
	if data == "" {
		return map[string]any{}
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(data), &m); err != nil {
		return map[string]any{}
	}
	return m
}

func reasonText(meta map[string]any) string {
	for _, key := range []string{"reason", "error", "exit_code"} {
		if v, ok := meta[key]; ok && v != nil {
			return fmt.Sprintf("%v", v)
		}
	}
	return "no reason given"
}

// splitPrompt turns ACP content blocks into what the API takes.
//
// Blocks that name something on the developer's machine — a resource link, an
// embedded resource — are dropped with a log line rather than pasted into the
// prompt as a path. The agent works in a sandbox with a different filesystem,
// and handing it a path that resolves to nothing there produces a turn spent
// looking for a file that was never going to be present.
func splitPrompt(blocks []json.RawMessage, log *slog.Logger) (string, []Image, error) {
	var (
		texts   []string
		images  []Image
		skipped []string
	)

	for _, raw := range blocks {
		var b contentBlock
		if err := json.Unmarshal(raw, &b); err != nil {
			return "", nil, Errorf(CodeInvalidParams, "session/prompt: bad content block: %s", err)
		}

		switch b.Type {
		case "text":
			if b.Text != "" {
				texts = append(texts, b.Text)
			}
		case "image":
			if b.Data == "" {
				skipped = append(skipped, "image without data")
				continue
			}
			images = append(images, Image{Data: b.Data, MediaType: b.MimeType})
		default:
			skipped = append(skipped, b.Type)
		}
	}

	if len(skipped) > 0 {
		log.Warn("dropped prompt content this agent cannot use",
			"blocks", strings.Join(skipped, ","),
			"why", "the agent runs in a sandbox, not on this machine")
	}

	text := strings.Join(texts, "\n")
	if strings.TrimSpace(text) == "" && len(images) == 0 {
		return "", nil, Errorf(CodeInvalidParams, "session/prompt carried no text or image content")
	}
	return text, images, nil
}
