package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/managoat/managoat/cli/internal/api"
	"github.com/managoat/managoat/cli/internal/output"
	"github.com/managoat/managoat/cli/internal/sse"
	"github.com/spf13/cobra"
)

// A workspace's setup output (#3009): `--wait` prints it as it runs, from
// the `workspace.setup` events on the account stream, and `workspace logs`
// reads what the last setup printed, which the server keeps after the
// machine is gone.

// workspaceProgress is where `--wait` writes: the status changes and the
// setup's lines. A variable so the tests can read it.
var workspaceProgress io.Writer = os.Stderr

// setupDrain bounds how long a finished wait keeps reading the stream for
// lines still in flight: the server sends a setup's last lines before it
// says ready or failed, but the poll can see the status first. It stops
// sooner once the stream has been quiet for setupQuiet.
var (
	setupDrain = 2 * time.Second
	setupQuiet = 300 * time.Millisecond
)

// setupRetryDelay is how long the follower waits before reconnecting to a
// stream that closed (the server closes an idle one after a minute).
var setupRetryDelay = time.Second

// setupFollower prints one workspace's setup lines from the account event
// stream. It connects before the workspace is created, so the first lines
// are not missed, and holds whatever arrives before it knows which
// workspace to print (`follow`). The stream is not replayed: lines sent
// while it was reconnecting are only in `workspace logs`.
type setupFollower struct {
	mu      sync.Mutex
	out     io.Writer
	id      string
	held    []map[string]any
	sandbox string
	step    string
	last    time.Time

	cancel context.CancelFunc
	done   chan struct{}
}

// maxHeldSetupFrames bounds what is held before the workspace is known.
const maxHeldSetupFrames = 1000

func startSetupFollower(c *api.Client, out io.Writer) *setupFollower {
	ctx, cancel := context.WithCancel(context.Background())
	f := &setupFollower{out: out, cancel: cancel, done: make(chan struct{})}
	go f.run(ctx, c)
	return f
}

// follow names the workspace whose lines to print, and prints what was held
// for it.
func (f *setupFollower) follow(id string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.id = id
	held := f.held
	f.held = nil
	for _, frame := range held {
		f.printLocked(frame)
	}
}

// stop ends the follow once lines in flight have had a moment to arrive.
func (f *setupFollower) stop() {
	deadline := time.Now().Add(setupDrain)
	for time.Now().Before(deadline) {
		f.mu.Lock()
		quiet := time.Since(f.last) >= setupQuiet
		f.mu.Unlock()
		if quiet {
			break
		}
		time.Sleep(setupQuiet / 4)
	}
	f.cancel()
	<-f.done
}

func (f *setupFollower) run(ctx context.Context, c *api.Client) {
	defer close(f.done)
	for ctx.Err() == nil {
		err := f.once(ctx, c)
		var permanent permanentStreamError
		if errors.As(err, &permanent) {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(setupRetryDelay):
		}
	}
}

type permanentStreamError struct{ error }

func (f *setupFollower) once(ctx context.Context, c *api.Client) error {
	req, err := c.NewStreamRequest(ctx, "/events/stream", "")
	if err != nil {
		return permanentStreamError{err}
	}
	resp, err := (&http.Client{}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		err := fmt.Errorf("event stream HTTP %d", resp.StatusCode)
		// A key that may not read the account stream, or a server without
		// one: the wait goes on without the lines.
		if resp.StatusCode < 500 {
			return permanentStreamError{err}
		}
		return err
	}

	buf := make([]byte, 8192)
	pending := ""
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			var events []sse.Event
			events, pending = sse.Feed(pending + string(buf[:n]))
			for _, ev := range events {
				if ev.Event != "workspace.setup" {
					continue
				}
				if frame, ok := ev.Data.(map[string]any); ok {
					f.take(frame)
				}
			}
		}
		if err != nil {
			return err
		}
	}
}

func (f *setupFollower) take(frame map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.last = time.Now()
	switch {
	case f.id == "":
		if len(f.held) < maxHeldSetupFrames {
			f.held = append(f.held, frame)
		}
	case output.ToString(frame["workspace_id"]) == f.id:
		f.printLocked(frame)
	}
}

// printLocked writes a frame: a header when a step starts, its lines
// indented, and a note when a step fails or lines were left out.
func (f *setupFollower) printLocked(frame map[string]any) {
	if output.ToString(frame["workspace_id"]) != f.id {
		return
	}
	sandbox := output.ToString(frame["sandbox_id"])
	step := output.ToString(frame["step"])
	status := output.ToString(frame["status"])
	if sandbox != f.sandbox {
		// A new setup (a retry, a rebuild) starts over.
		f.sandbox, f.step = sandbox, ""
	}
	if step != f.step {
		fmt.Fprintf(f.out, "▸ setup: %s\n", setupStepLabel(step))
		f.step = step
	}
	if n, _ := frame["omitted_lines"].(float64); n > 0 {
		fmt.Fprintf(f.out, "  … %d lines not shown (`managoat workspace logs` has the last 64 KiB of each step)\n", int(n))
	}
	if lines, ok := frame["lines"].([]any); ok {
		for _, line := range lines {
			fmt.Fprintf(f.out, "  %s\n", output.ToString(line))
		}
	}
	if status == "failed" {
		fmt.Fprintf(f.out, "▸ setup: %s failed\n", setupStepLabel(step))
	}
}

// setupStepLabel says what a setup step is doing, in words.
func setupStepLabel(step string) string {
	switch step {
	case "machine":
		return "creating the machine"
	case "broker":
		return "settling the egress broker (floor, CA, relay)"
	case "environment":
		return "writing the environment's and vault's variables"
	case "packages":
		return "installing packages"
	case "repositories":
		return "cloning repositories"
	case "setup_script":
		return "running the setup script"
	case "runtime_template":
		return "copying the runtime template"
	default:
		return step
	}
}

// workspaceLogsCmd is `managoat workspace logs`.
func workspaceLogsCmd() *cobra.Command {
	logsCmd := &cobra.Command{
		Use:   "logs <id-or-name>",
		Short: "Show what a workspace's last setup printed",
		Long: `Show the output of a workspace's last setup, step by step: on create, a
retry, a rebuild after a loss, or ` + "`managoat workspace rebuild`" + `. Each setup
replaces the previous one's log. Managoat keeps it, not the machine, so it is
there while the setup runs and after the machine is gone.

The output is redacted like a transcript. Each step keeps its last 64 KiB and
says how many earlier lines it dropped. An implicit workspace's setup is in its
conversation's transcript instead.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error { return workspaceLogs(cmd, args[0]) },
	}
	logsCmd.Flags().String("step", "", "show only this step (machine, broker, environment, packages, repositories, setup_script, runtime_template)")
	logsCmd.Flags().Bool("json", false, "print the log as JSON")
	return logsCmd
}

func workspaceLogs(cmd *cobra.Command, target string) error {
	only, _ := cmd.Flags().GetString("step")
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	id, err := resolveWorkspaceID(c, target)
	if err != nil {
		return err
	}
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Get("/workspaces/"+id+"/setup-log", &resp); err != nil {
		if api.StatusCode(err) == 404 {
			return fmt.Errorf("no workspace %s (an implicit workspace's setup is in its conversation's transcript: `managoat conv events`)", id)
		}
		return explainAPIError(err)
	}
	log := resp.Data
	if jsonOut {
		return output.PrintJSON(log)
	}
	if log == nil {
		fmt.Printf("no setup log for workspace %s yet\n", id)
		return nil
	}
	fmt.Printf("setup %s  (machine %s, started %s", output.ToString(log["status"]), output.ToString(log["sandbox_id"]), output.ToString(log["started_at"]))
	if finished := output.ToString(log["finished_at"]); finished != "" {
		fmt.Printf(", finished %s", finished)
	}
	fmt.Println(")")
	steps, _ := log["steps"].([]any)
	shown := 0
	for _, raw := range steps {
		step, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		name := output.ToString(step["step"])
		if only != "" && name != only {
			continue
		}
		shown++
		fmt.Printf("\n── %s: %s\n", name, output.ToString(step["status"]))
		if n, _ := step["omitted_lines"].(float64); n > 0 {
			fmt.Printf("  … %d earlier lines dropped\n", int(n))
		}
		for _, line := range strings.SplitAfter(output.ToString(step["output"]), "\n") {
			if line != "" {
				fmt.Print("  " + line)
			}
		}
	}
	if only != "" && shown == 0 {
		return fmt.Errorf("the last setup has no %s step", only)
	}
	return nil
}
