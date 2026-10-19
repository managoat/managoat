package cmd

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/managoat/managoat/cli/internal/api"
	"github.com/managoat/managoat/cli/internal/output"
	"github.com/managoat/managoat/cli/internal/sse"
	"github.com/managoat/managoat/cli/internal/stream"
	"github.com/spf13/cobra"
)

func init() {
	convCmd := &cobra.Command{Use: "conv", Short: "Manage conversations"}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List conversations",
		RunE:  func(cmd *cobra.Command, args []string) error { return convList(cmd) },
	}
	listCmd.Flags().Bool("json", false, "output JSON")

	promptCmd := &cobra.Command{
		Use:   "prompt <id>",
		Short: "Send a prompt to a conversation and stream the result",
		Args:  cobra.ExactArgs(1),
		RunE:  func(cmd *cobra.Command, args []string) error { return convPrompt(cmd, args[0]) },
	}
	promptCmd.Flags().StringP("prompt", "p", "", "prompt text (required)")
	promptCmd.Flags().StringSliceP("image", "i", nil, "image file path (repeatable)")
	promptCmd.Flags().String("client-request-id", "", "caller-provided prompt correlation ID (not an idempotency key)")

	convCmd.AddCommand(
		newConversationCreateCommand(),
		listCmd,
		&cobra.Command{
			Use:   "show <id>",
			Short: "Show a conversation",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return convShow(args[0]) },
		},
		&cobra.Command{
			Use:   "stream <id>",
			Short: "Stream conversation events",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return convStream(args[0]) },
		},
		promptCmd,
		&cobra.Command{
			Use:   "wake <id>",
			Short: "Bring the sandbox up without sending a prompt",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return convWake(args[0]) },
		},
		&cobra.Command{
			Use:   "interrupt <id>",
			Short: "Interrupt the running turn",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return convInterrupt(args[0]) },
		},
		&cobra.Command{
			Use:   "terminate <id>",
			Short: "Terminate a conversation",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return convTerminate(args[0]) },
		},
		&cobra.Command{
			Use:   "delete <id>",
			Short: "Delete a conversation",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return convDelete(args[0]) },
		},
	)
	rootCmd.AddCommand(convCmd)

	// `run` is a top-level shortcut: create + stream until done.
	runCmd := &cobra.Command{
		Use:   "run <agent-name-or-id>",
		Short: "Run an agent (create conversation + stream until done)",
		Args:  cobra.ExactArgs(1),
		RunE:  func(cmd *cobra.Command, args []string) error { return runAgent(cmd, args[0]) },
	}
	runCmd.Flags().StringP("prompt", "p", "", "prompt text (required)")
	runCmd.Flags().String("client-request-id", "", "caller-provided prompt correlation ID (not an idempotency key)")
	runCmd.Flags().String("vault", "", "vault name or id")
	runCmd.Flags().String("environment", "", "environment name or id to provision from, instead of the agent's own")
	runCmd.Flags().String("cwd", "", "working directory inside the sandbox for the agent (absolute, under /home/sprite; created if missing)")
	runCmd.Flags().String("workspace", "", "workspace name or id to run on, beside the conversations already there")
	rootCmd.AddCommand(runCmd)
}

// ── list / show ────────────────────────────────────────────────────────

func convList(cmd *cobra.Command) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/conversations", &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, v := range resp.Data {
		rows = append(rows, []string{
			output.ToString(v["status"]),
			output.ShortID(output.ToString(v["id"])),
			output.ShortID(output.ToString(v["agent_id"])),
			output.ToString(v["runtime"]),
			output.ToString(v["inserted_at"]),
		})
	}
	output.Table([]string{"status", "id", "agent_id", "runtime", "started"}, rows)
	return nil
}

func convShow(id string) error {
	c := activeClient()
	var convResp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Get("/conversations/"+id, &convResp); err != nil {
		Fatal(err.Error())
	}
	var turnResp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/conversations/"+id+"/turns", &turnResp); err != nil {
		Fatal(err.Error())
	}

	conv := convResp.Data
	fmt.Printf("conversation %s\n", output.ToString(conv["id"]))
	fmt.Printf("  status:    %s\n", output.ToString(conv["status"]))
	fmt.Printf("  agent:     %s\n", output.ToString(conv["agent_id"]))
	fmt.Printf("  sandbox:   %s\n", output.ToString(conv["sandbox_id"]))
	fmt.Printf("  machine:   %s\n", machineLabel(conv["sandbox"]))
	fmt.Printf("  runtime:   %s\n", output.ToString(conv["runtime"]))
	fmt.Printf("  inserted:  %s\n", output.ToString(conv["inserted_at"]))
	fmt.Printf("\nturns (%d):\n", len(turnResp.Data))
	for _, t := range turnResp.Data {
		fmt.Printf("  #%s %s exit=%s  %s\n",
			output.ToString(t["turn_number"]),
			output.ToString(t["status"]),
			output.ToString(t["exit_code"]),
			output.Truncate(output.ToString(t["prompt"]), 80),
		)
	}
	return nil
}

func machineLabel(v any) string {
	m, ok := v.(map[string]any)
	if !ok {
		return "—"
	}
	// A server from before machine_name (#2108) answers only sprite_name.
	name, _ := m["machine_name"].(string)
	if name == "" {
		name, _ = m["sprite_name"].(string)
	}
	status, _ := m["status"].(string)
	if name == "" {
		return "—"
	}
	return fmt.Sprintf("%s (%s)", name, status)
}

// ── streaming ──────────────────────────────────────────────────────────

func convStream(id string) error {
	// Seed the follow with the current stream head. Starting from zero
	// replayed the entire history, and the first `turn`/`done` in that replay
	// — always a prior turn's on any conversation with a completed turn —
	// ended the command immediately (#398).
	head, err := streamHead(activeClient(), id)
	if err != nil {
		Fatal(err.Error())
	}
	return followUntilIdle(id, head)
}

func convPrompt(cmd *cobra.Command, id string) error {
	prompt, _ := cmd.Flags().GetString("prompt")
	if prompt == "" {
		Fatal("missing -p <prompt>")
	}
	imagePaths, _ := cmd.Flags().GetStringSlice("image")
	images := make([]map[string]string, 0, len(imagePaths))
	for _, p := range imagePaths {
		raw, err := os.ReadFile(p)
		if err != nil {
			Fatalf("read %s: %v", p, err)
		}
		images = append(images, map[string]string{
			"data":       base64.StdEncoding.EncodeToString(raw),
			"media_type": guessMediaType(p),
		})
	}
	c := activeClient()
	// Learn the stream head BEFORE queueing the prompt: every event of the new
	// turn is then guaranteed to arrive after `head`, so the terminal
	// `turn`/`done` we stop on is the turn we just sent, not a replayed one
	// from the conversation's history (#398). POST /prompts returns only
	// {status: "queued"} — no turn id — so this ordering is what scopes the
	// follow to the right turn.
	head, err := streamHead(c, id)
	if err != nil {
		Fatal(err.Error())
	}
	body := map[string]any{"prompt": prompt, "images": images}
	if cmd.Flags().Changed("client-request-id") {
		body["client_request_id"], _ = cmd.Flags().GetString("client-request-id")
	}
	if err := c.Post("/conversations/"+id+"/prompts", body, nil); err != nil {
		Fatal(err.Error())
	}
	return followUntilIdle(id, head, output.ToString(body["client_request_id"]))
}

func guessMediaType(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	default:
		return "image/png"
	}
}

func convWake(id string) error {
	c := activeClient()
	var out struct {
		Status string `json:"status"`
	}
	if err := c.Post("/conversations/"+id+"/wake", map[string]any{}, &out); err != nil {
		Fatal(err.Error())
	}
	if out.Status == "awake" {
		fmt.Printf("%s is already awake\n", id)
	} else {
		fmt.Printf("waking %s\n", id)
	}
	return nil
}

func convInterrupt(id string) error {
	c := activeClient()
	if err := c.Post("/conversations/"+id+"/interrupt", map[string]any{}, nil); err != nil {
		if api.StatusCode(err) == 409 {
			Fatal("no turn running")
		}
		Fatal(err.Error())
	}
	fmt.Printf("interrupted %s\n", id)
	return nil
}

func convTerminate(id string) error {
	c := activeClient()
	if err := c.Post("/conversations/"+id+"/terminate", map[string]any{}, nil); err != nil {
		Fatal(err.Error())
	}
	fmt.Printf("terminated %s\n", id)
	return nil
}

func convDelete(id string) error {
	c := activeClient()
	if err := c.Delete("/conversations/"+id, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(err.Error())
	}
	fmt.Printf("deleted %s\n", id)
	return nil
}

// ── run shortcut ────────────────────────────────────────────────────────

func runAgent(cmd *cobra.Command, target string) error {
	prompt, _ := cmd.Flags().GetString("prompt")
	if prompt == "" {
		Fatal("missing -p <prompt>")
	}
	body, err := runBody(cmd, target, prompt)
	if err != nil {
		Fatal(err.Error())
	}

	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := activeClient().Post("/conversations", body, &resp); err != nil {
		Fatal(explainAPIError(err).Error())
	}
	convID := output.ToString(resp.Data["id"])
	fmt.Fprintf(os.Stderr, "▸ conversation %s\n", convID)
	// Fresh conversation: there is no history to skip, and draining first
	// could miss provisioning events emitted between create and follow.
	return followUntilIdle(convID, "", output.ToString(body["client_request_id"]))
}

// runBody is the launch request `run` sends, from its flags.
func runBody(cmd *cobra.Command, target, prompt string) (map[string]any, error) {
	vault, _ := cmd.Flags().GetString("vault")
	environment, _ := cmd.Flags().GetString("environment")

	agentID := resolveAgentID(target)
	body := map[string]any{"agent_id": agentID, "prompt": prompt}
	if cmd.Flags().Changed("client-request-id") {
		body["client_request_id"], _ = cmd.Flags().GetString("client-request-id")
	}
	if vault != "" {
		body["vault_id"] = resolveVaultID(vault)
	}
	if environment != "" {
		body["environment_id"] = resolveEnvironmentID(environment)
	}
	if cwd, _ := cmd.Flags().GetString("cwd"); cwd != "" {
		body["cwd"] = cwd
	}
	// A workspace supplies the environment and vault, so the two flags are
	// only accepted when they name its own; the server says so if not.
	if workspace, _ := cmd.Flags().GetString("workspace"); workspace != "" {
		id, err := resolveWorkspaceID(activeClient(), workspace)
		if err != nil {
			return nil, err
		}
		body["workspace_id"] = id
	}
	return body, nil
}

// ── stream loop ─────────────────────────────────────────────────────────

// streamHead drains the conversation's buffered events with `?wait=false`
// (the server replays history and closes immediately — conversation_controller.ex)
// and returns the id of the last buffered event, or "" when there is none.
// Seeding the live follow with it skips the full-history replay.
func streamHead(c *api.Client, convID string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	req, err := c.NewStreamRequest(ctx, "/conversations/"+convID+"/stream?wait=false", "")
	if err != nil {
		return "", err
	}
	resp, err := (&http.Client{}).Do(req)
	if err != nil {
		return "", fmt.Errorf("drain stream: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("drain stream: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("drain stream HTTP %d: %s", resp.StatusCode, body)
	}
	return lastEventIDIn(string(body)), nil
}

// lastEventIDIn returns the highest event id in a fully-drained SSE body, or
// "" when no event carries an id. The trailing blank line is appended so the
// final event parses even if the body did not end with one.
func lastEventIDIn(body string) string {
	events, _ := sse.Feed(body + "\n\n")
	last := 0
	for _, ev := range events {
		if ev.ID > last {
			last = ev.ID
		}
	}
	if last == 0 {
		return ""
	}
	return strconv.Itoa(last)
}

// followUntilIdle streams conv `id` until the turn reaches a terminal state,
// reconnecting across server-side idle disconnects. See stream.go.
// lastEventID seeds the first connection (empty means from the beginning).
func followUntilIdle(convID, lastEventID string, requestID ...string) error {
	c := activeClient()

	open := func(ctx context.Context, lastEventID string) (io.ReadCloser, error) {
		req, err := c.NewStreamRequest(ctx, "/conversations/"+convID+"/stream", lastEventID)
		if err != nil {
			return nil, err
		}
		// No client timeout: streams are long-lived and the idle watchdog in
		// followStream is what bounds them.
		resp, err := (&http.Client{}).Do(req)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			// Auth and not-found are not worth retrying.
			if resp.StatusCode < 500 {
				return nil, stream.Permanent(fmt.Errorf("stream HTTP %d: %s", resp.StatusCode, body))
			}
			return nil, fmt.Errorf("stream HTTP %d: %s", resp.StatusCode, body)
		}
		return resp.Body, nil
	}

	return followStream(open, streamIdleTimeout(), convID, lastEventID, requestID...)
}

// handleEvent prints output and reports whether the event is terminal for the
// stream. A non-nil error is the terminal outcome to exit non-zero with; nil
// with terminal=true is a clean completion.
func handleEvent(ev sse.Event) (bool, error) {
	switch ev.Event {
	case "stage":
		data, ok := ev.Data.(map[string]any)
		if !ok {
			return false, nil
		}
		return handleStageEvent(data)
	case "output":
		data, ok := ev.Data.(map[string]any)
		if !ok {
			return false, nil
		}
		text := formatOutput(data)
		if text != "" {
			fmt.Print(text)
		}
	}
	return false, nil
}

// handleStageEvent decides whether a stage event ends the stream, and how.
// Failure terminals return an error so the CLI exits non-zero — before #398
// they all exited 0, so `managoat run` in CI reported success for a crashed
// agent or a sandbox that never provisioned.
func handleStageEvent(data map[string]any) (bool, error) {
	stage, _ := data["stage"].(string)
	state, _ := data["state"].(string)

	switch {
	case stage == "turn" && state == "done":
		exit := exitCodeFromStageDone(data)
		fmt.Fprintf(os.Stderr, "▸ turn done (exit_code=%s)\n", exit)
		// The server publishes `turn`/`done` even when the command failed;
		// the exit_code is the verdict (conversation_server.ex).
		if exit != "" && exit != "0" {
			return true, fmt.Errorf("%w: exit_code=%s", errTurnFailed, exit)
		}
		return true, nil

	// Terminal states where no turn will ever complete. Without these the
	// stream would reconnect and wait out the idle timeout for a turn that
	// is never coming.
	case stage == "turn" && state == "failed":
		// The server puts why in the payload (conversation_server.ex
		// publish_stage of "turn"/"failed"); a bare "turn failed" left a
		// first-time user whose only mistake was skipping the inference
		// key with nothing to act on.
		if reason := innerDataString(data, "reason"); reason != "" {
			fmt.Fprintf(os.Stderr, "▸ turn failed: %s\n", reason)
			if hint := turnFailureHint(reason); hint != "" {
				fmt.Fprintf(os.Stderr, "  %s\n", hint)
			}
		} else {
			fmt.Fprintf(os.Stderr, "▸ turn failed\n")
		}
		return true, errTurnFailed

	case stage == "wake" && state == "failed":
		reason := innerDataString(data, "reason")
		retryable := innerDataString(data, "retryable")
		return true, fmt.Errorf("prompt did not run: %s (retryable=%s); no prompt was replayed", reason, retryable)

	case stage == "provision" && state == "failed":
		fmt.Fprintf(os.Stderr, "▸ provisioning failed — the sandbox never started\n")
		return true, errProvisionFailed

	case stage == "reattach" && state == "failed":
		// The server stops after this (conversation_server.ex); no more
		// events are coming. The conversation itself stays promptable.
		// Since #799 the event says which kind of failure it was: a
		// transient one (provider unreachable) left the sandbox as it was
		// and the next prompt reattaches again; a definitive not-found
		// retired it and the next prompt provisions fresh.
		if innerDataString(data, "retryable") == "true" {
			fmt.Fprintf(os.Stderr, "▸ reattach failed (%s) — the sandbox is untouched; prompt again to retry\n", innerDataString(data, "reason"))
			return true, errReattachFailed
		}
		fmt.Fprintf(os.Stderr, "▸ reattach failed — prompt again to provision a fresh sandbox\n")
		return true, errReattachFailed

	case stage == "terminate" && state == "done":
		fmt.Fprintf(os.Stderr, "▸ conversation terminated\n")
		return true, nil

	case stage == "turn" && state == "interrupted":
		// The machine ending under a running turn interrupts it too, and that
		// is not the clean exit a deliberate interrupt is: the work did not
		// finish (ADR 0097). At the max-lifetime ceiling a workspace's
		// machine is parked with its disk, and a deleted workspace's machine
		// is destroyed with it.
		switch innerDataString(data, "reason") {
		case "machine_parked":
			fmt.Fprintf(os.Stderr, "▸ turn cut off: the machine reached its max lifetime and was parked — its disk and sessions are kept, and the next prompt wakes it\n")
			return true, errSandboxExpired
		case "machine_destroyed":
			fmt.Fprintf(os.Stderr, "▸ turn cut off: its machine was destroyed or replaced (a deleted workspace, a rebuild after a loss, the lifetime ceiling, or an operator's reap)\n")
			return true, errMachineDestroyed
		}
		// Deliberate `managoat conv interrupt` (possibly from another
		// shell). Clean exit: without this case the stream sat out the
		// full idle timeout waiting for a turn/done that never comes.
		fmt.Fprintf(os.Stderr, "▸ turn interrupted\n")
		return true, nil

	case stage == "sandbox" && state == "done":
		reason := innerDataString(data, "reason")
		switch innerDataString(data, "event") {
		case "admission_refused", "at_capacity":
			// The prompt never started; the sandbox was not reclaimed.
			fmt.Fprintf(os.Stderr, "▸ prompt was not started (%s) — send it again shortly\n", reason)
			return true, errPromptNotStarted
		case "suspended":
			// Idle suspend keeps the sprite and the next prompt resumes it.
			fmt.Fprintf(os.Stderr, "▸ sandbox suspended (%s) — send another prompt to resume where you left off\n", reason)
			return true, nil
		}
		// A max-lifetime reclaim can cut a running turn short.
		fmt.Fprintf(os.Stderr, "▸ sandbox reclaimed (%s) — the conversation stays resumable\n", reason)
		if reason == "max_lifetime" {
			return true, errSandboxExpired
		}
		return true, nil
	}

	fmt.Fprintf(os.Stderr, "▸ %s: %s\n", stage, state)
	return false, nil
}

// exitCodeFromStageDone digs `data.data.exit_code` out of a turn-done event.
func exitCodeFromStageDone(data map[string]any) string {
	return innerDataString(data, "exit_code")
}

// innerDataString digs `data.data.<key>` out of a stage event. The Elixir
// code JSON-encodes the stage metadata into the inner `data`, so we accept
// either a nested map or a JSON string.
// turnFailureHint turns a failure reason the runtime reported into the one
// step that fixes it, where there is such a step. The ACP runtimes answer a
// prompt with "Authentication required" when they were started with no
// provider credential at all, which is what a run looks like when the
// inference-key step of the quickstart was skipped.
func turnFailureHint(reason string) string {
	if strings.Contains(reason, "Authentication required") {
		return "The runtime has no inference credential. Add one in the console under Account, then Inference keys, and prompt again."
	}
	return ""
}

func innerDataString(data map[string]any, key string) string {
	inner := data["data"]
	if s, ok := inner.(string); ok {
		var m map[string]any
		if json.Unmarshal([]byte(s), &m) == nil {
			return output.ToString(m[key])
		}
	}
	if m, ok := inner.(map[string]any); ok {
		return output.ToString(m[key])
	}
	return ""
}

func formatOutput(data map[string]any) string {
	stream, _ := data["stream"].(string)
	raw, _ := data["data"].(string)
	if stream == "stderr" {
		return "\x1b[31m" + raw + "\x1b[0m"
	}
	if raw == "" {
		return ""
	}
	// ACP conversations store the protocol itself, one `session/update` per
	// line. Since #674 made ACP the only path for the coding-agent runtimes,
	// this is what a turn's output *is* — and rendering it as stream-json
	// produced nothing at all, so `managoat run` printed a turn starting and
	// finishing with silence in between (#723).
	if stream == "acp" {
		var b strings.Builder
		for _, line := range strings.Split(raw, "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			b.WriteString(formatACPLine(line))
		}
		return b.String()
	}
	// Setup and provisioning stages log raw diagnostics. Historical vendor
	// stdout has no transcript renderer; its data remains in the events API.
	if stage, _ := data["stage"].(string); stage != "" && stage != "turn" {
		if strings.HasSuffix(raw, "\n") {
			return raw
		}
		return raw + "\n"
	}
	return ""
}

// formatACPLine renders one stored `session/update` for a human: assistant
// text plain, thinking dimmed, and tool calls in cyan. ACP is the protocol
// every supported runtime speaks; vendor stdout dialects are not interpreted.
func formatACPLine(line string) string {
	var msg struct {
		Method string `json:"method"`
		Params struct {
			Update map[string]any `json:"update"`
		} `json:"params"`
	}
	if json.Unmarshal([]byte(line), &msg) != nil || msg.Method != "session/update" {
		return ""
	}

	update := msg.Params.Update
	kind, _ := update["sessionUpdate"].(string)

	switch kind {
	case "agent_message_chunk":
		return acpContentText(update)

	case "agent_thought_chunk":
		// Thinking is dimmed rather than dropped: it is often the only output
		// a long tool-heavy turn produces, and a silent terminal reads as a
		// hung agent.
		if text := acpContentText(update); text != "" {
			return "\x1b[2m" + text + "\x1b[0m"
		}

	case "tool_call":
		title, _ := update["title"].(string)
		if title == "" {
			title, _ = update["kind"].(string)
		}
		return "\n\x1b[36m[" + title + "]\x1b[0m\n"

	case "tool_call_update":
		// Only terminal statuses: in-flight updates carry progress, and a line
		// per `in_progress` would bury the agent's own words.
		status, _ := update["status"].(string)
		switch status {
		case "failed":
			return "\x1b[31m  ✗ " + status + "\x1b[0m\n"
		case "completed", "cancelled":
			return "\x1b[2m  ✓ " + status + "\x1b[0m\n"
		}
	}

	return ""
}

// acpContentText pulls the text out of an update's `content` block, which ACP
// shapes as `{"type": "text", "text": "..."}`.
func acpContentText(update map[string]any) string {
	content, ok := update["content"].(map[string]any)
	if !ok {
		return ""
	}
	text, _ := content["text"].(string)
	return text
}
