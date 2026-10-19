package cmd

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/managoat/managoat/cli/internal/api"
	"github.com/managoat/managoat/cli/internal/output"
	"github.com/spf13/cobra"
)

// Workspaces (ADR 0097): a machine the caller keeps, set up once from an
// environment and a vault, that any number of conversations then run on
// with `--workspace`, each in a folder of its own. Unlike `sandbox`, these
// are created and deleted here: the workspace, not a conversation, decides
// when its machine ends.

// workspacePollInterval is how often `--wait` reads the workspace again.
// A variable so the tests do not sleep.
var workspacePollInterval = 2 * time.Second

func init() {
	wsCmd := &cobra.Command{
		Use:   "workspace",
		Short: "Manage workspaces: one machine, many conversations",
		Long: `Manage workspaces.

A workspace is a sandbox you keep: set up once from an environment and an
optional vault, then any agent launched into it with --workspace on run or
acp, each conversation in a working directory of its own (--cwd).

Conversations in one workspace share one disk and one user. They can read
each other's files, config homes and tokens, and change what the others run.
For isolation, launch without --workspace: each conversation then gets a
sandbox of its own.`,
	}

	createCmd := &cobra.Command{
		Use:   "create <name>",
		Short: "Create a workspace and start setting up its machine",
		Long: `Create a workspace and start setting up its machine at once: the
environment's packages, repositories and setup script, with the vault's
secrets overriding the environment's. The environment, vault and provider are
fixed for the workspace's life.

Without --wait the command returns as soon as the workspace exists, with
status provisioning. With --wait it follows the setup and exits non-zero if it
fails. Conversations can be launched into a workspace before it is ready;
their first prompt waits for it.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error { return workspaceCreate(cmd, args[0]) },
	}
	createCmd.Flags().String("environment", "", "environment name or id the machine is set up from (required)")
	createCmd.Flags().String("vault", "", "vault name or id whose secrets override the environment's")
	createCmd.Flags().String("provider", "", "sandbox provider: sprites or e2b (default: the instance's)")
	createCmd.Flags().Bool("wait", false, "wait until the workspace is ready, and fail if its setup fails")
	createCmd.Flags().Duration("timeout", 30*time.Minute, "how long --wait waits")
	createCmd.Flags().Bool("json", false, "print the workspace as JSON")
	_ = createCmd.MarkFlagRequired("environment")

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List workspaces",
		RunE:  func(cmd *cobra.Command, args []string) error { return workspaceList(cmd) },
	}
	listCmd.Flags().Bool("implicit", false, "also list implicit workspaces, one per conversation launched without --workspace")
	listCmd.Flags().Bool("json", false, "output JSON")

	showCmd := &cobra.Command{
		Use:   "show <id-or-name>",
		Short: "Show a workspace and its machine",
		Args:  cobra.ExactArgs(1),
		RunE:  func(cmd *cobra.Command, args []string) error { return workspaceShow(cmd, args[0]) },
	}
	showCmd.Flags().Bool("json", false, "output JSON")

	waitCmd := &cobra.Command{
		Use:   "wait <id-or-name>",
		Short: "Wait until a workspace is ready, and fail if its setup fails",
		Args:  cobra.ExactArgs(1),
		RunE:  func(cmd *cobra.Command, args []string) error { return workspaceWaitCmd(cmd, args[0]) },
	}
	waitCmd.Flags().Duration("timeout", 30*time.Minute, "how long to wait")

	wsCmd.AddCommand(
		createCmd,
		listCmd,
		showCmd,
		waitCmd,
		&cobra.Command{
			Use:   "delete <id-or-name>",
			Short: "Delete a workspace: terminate its conversations and destroy its machine",
			Long: `Delete a workspace. Every live conversation in it is terminated (their
transcripts are kept) and its machine is destroyed, with everything on its
disk. It is not refused while conversations are running.`,
			Args: cobra.ExactArgs(1),
			RunE: func(cmd *cobra.Command, args []string) error { return workspaceDelete(args[0]) },
		},
	)
	rootCmd.AddCommand(wsCmd)
}

func workspaceCreate(cmd *cobra.Command, name string) error {
	f := cmd.Flags()
	environment, _ := f.GetString("environment")
	vault, _ := f.GetString("vault")
	provider, _ := f.GetString("provider")
	wait, _ := f.GetBool("wait")
	timeout, _ := f.GetDuration("timeout")
	jsonOut, _ := f.GetBool("json")

	body := map[string]any{"name": name, "environment_id": resolveEnvironmentID(environment)}
	if vault != "" {
		body["vault_id"] = resolveVaultID(vault)
	}
	if provider != "" {
		body["sandbox_provider"] = provider
	}

	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := activeClient().Post("/workspaces", body, &resp); err != nil {
		return explainAPIError(err)
	}
	ws := resp.Data
	id := output.ToString(ws["id"])
	if !jsonOut {
		fmt.Printf("workspace  +  %s (%s)  %s\n", output.ToString(ws["name"]), id, output.ToString(ws["status"]))
	}
	if wait {
		final, err := waitForWorkspace(activeClient(), id, timeout, os.Stderr)
		if final != nil {
			ws = final
		}
		if err != nil {
			if jsonOut {
				_ = output.PrintJSON(ws)
			}
			return err
		}
	}
	if jsonOut {
		return output.PrintJSON(ws)
	}
	return nil
}

func workspaceList(cmd *cobra.Command) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	implicit, _ := cmd.Flags().GetBool("implicit")
	path := "/workspaces"
	if implicit {
		path += "?implicit=true"
	}
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := activeClient().Get(path, &resp); err != nil {
		return explainAPIError(err)
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, w := range resp.Data {
		name := output.ToString(w["name"])
		if b, _ := w["implicit"].(bool); b {
			name = "(implicit)"
		}
		rows = append(rows, []string{
			output.ToString(w["status"]),
			output.ShortID(output.ToString(w["id"])),
			name,
			dash(output.ToString(w["sandbox_status"])),
			output.ToString(w["sandbox_provider"]),
			output.ShortID(output.ToString(w["environment_id"])),
			output.ToString(w["inserted_at"]),
		})
	}
	output.Table([]string{"status", "id", "name", "machine", "provider", "environment", "created"}, rows)
	return nil
}

func workspaceShow(cmd *cobra.Command, target string) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	id, err := resolveWorkspaceID(c, target)
	if err != nil {
		return err
	}
	ws, err := getWorkspace(c, id)
	if err != nil {
		return err
	}
	if jsonOut {
		return output.PrintJSON(ws)
	}
	fmt.Printf("workspace %s\n", output.ToString(ws["id"]))
	fmt.Printf("  name:         %s\n", dash(output.ToString(ws["name"])))
	fmt.Printf("  status:       %s\n", output.ToString(ws["status"]))
	if e := output.ToString(ws["error"]); e != "" {
		fmt.Printf("  error:        %s\n", e)
	}
	fmt.Printf("  machine:      %s\n", workspaceMachineLabel(ws))
	fmt.Printf("  provider:     %s\n", output.ToString(ws["sandbox_provider"]))
	fmt.Printf("  environment:  %s\n", dash(output.ToString(ws["environment_id"])))
	fmt.Printf("  vault:        %s\n", dash(output.ToString(ws["vault_id"])))
	if b, _ := ws["implicit"].(bool); b {
		fmt.Printf("  implicit:     true (ends with its conversation)\n")
	}
	fmt.Printf("  created:      %s\n", output.ToString(ws["inserted_at"]))
	return nil
}

// workspaceMachineLabel says what the workspace's machine is doing: its own
// status beside the sandbox id, or that it has none live, which the next
// prompt into any of its conversations rebuilds.
func workspaceMachineLabel(ws map[string]any) string {
	sandbox := output.ToString(ws["sandbox_id"])
	status := output.ToString(ws["sandbox_status"])
	if sandbox == "" {
		return "none live (the next prompt builds one)"
	}
	if status == "suspended" {
		return sandbox + " (suspended; the next prompt wakes it)"
	}
	return fmt.Sprintf("%s (%s)", sandbox, status)
}

func workspaceWaitCmd(cmd *cobra.Command, target string) error {
	timeout, _ := cmd.Flags().GetDuration("timeout")
	c := activeClient()
	id, err := resolveWorkspaceID(c, target)
	if err != nil {
		return err
	}
	_, err = waitForWorkspace(c, id, timeout, os.Stderr)
	return err
}

func workspaceDelete(target string) error {
	c := activeClient()
	id, err := resolveWorkspaceID(c, target)
	if err != nil {
		return err
	}
	if err := c.Delete("/workspaces/"+id, nil); err != nil {
		if api.StatusCode(err) == 404 {
			return fmt.Errorf("no workspace %s (an implicit workspace ends with its conversation: delete the conversation)", id)
		}
		return explainAPIError(err)
	}
	fmt.Printf("deleted %s\n", id)
	return nil
}

func getWorkspace(c *api.Client, id string) (map[string]any, error) {
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Get("/workspaces/"+id, &resp); err != nil {
		if api.StatusCode(err) == 404 {
			return nil, fmt.Errorf("no workspace %s", id)
		}
		return nil, explainAPIError(err)
	}
	return resp.Data, nil
}

// errWorkspaceFailed is what a wait ends with when the setup failed. The
// workspace keeps its error; a prompt into one of its conversations retries
// the setup.
var errWorkspaceFailed = errors.New("workspace setup failed")

// waitForWorkspace reads the workspace until its status is ready or failed,
// printing each change to progress. It polls rather than following
// `workspace.status` on the account stream: that event is not replayed, so a
// follower has to read the workspace anyway to know where it started, and a
// poll every few seconds is all a setup measured in minutes needs.
//
// A read that fails for a reason worth retrying (the server restarting, a
// network blip) is retried until the deadline; a 4xx is not.
func waitForWorkspace(c *api.Client, id string, timeout time.Duration, progress io.Writer) (map[string]any, error) {
	deadline := time.Now().Add(timeout)
	last := ""
	var ws map[string]any
	for {
		var resp struct {
			Data map[string]any `json:"data"`
		}
		err := c.Get("/workspaces/"+id, &resp)
		switch {
		case err == nil:
			ws = resp.Data
			status := output.ToString(ws["status"])
			if status != last {
				fmt.Fprintf(progress, "▸ workspace %s: %s\n", id, status)
				last = status
			}
			switch status {
			case "ready":
				return ws, nil
			case "failed":
				reason := output.ToString(ws["error"])
				if reason == "" {
					return ws, errWorkspaceFailed
				}
				return ws, fmt.Errorf("%w: %s\n  A prompt into a conversation in it retries the setup; or delete it and create another", errWorkspaceFailed, reason)
			}
		case api.StatusCode(err) == 404:
			return ws, fmt.Errorf("no workspace %s (deleted while waiting?)", id)
		case api.StatusCode(err) >= 400 && api.StatusCode(err) < 500:
			return ws, explainAPIError(err)
		default:
			fmt.Fprintf(progress, "▸ could not read the workspace (%v); retrying\n", err)
		}
		if time.Now().Add(workspacePollInterval).After(deadline) {
			return ws, fmt.Errorf("workspace %s is still %s after %s; `managoat workspace wait %s` waits again", id, dash(last), timeout, id)
		}
		time.Sleep(workspacePollInterval)
	}
}

// resolveWorkspaceID accepts a workspace id or the name of one of the
// caller's explicit workspaces. Names are not unique, so two workspaces
// with the name asked for is an error that lists their ids.
func resolveWorkspaceID(c *api.Client, target string) (string, error) {
	if isUUID(target) {
		return target, nil
	}
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/workspaces", &resp); err != nil {
		return "", explainAPIError(err)
	}
	var ids []string
	for _, w := range resp.Data {
		if output.ToString(w["name"]) == target {
			ids = append(ids, output.ToString(w["id"]))
		}
	}
	switch len(ids) {
	case 0:
		return "", fmt.Errorf("no workspace named %q (managoat workspace list shows them)", target)
	case 1:
		return ids[0], nil
	default:
		return "", fmt.Errorf("%d workspaces are named %q; name one by id: %s", len(ids), target, strings.Join(ids, ", "))
	}
}

// explainAPIError adds, to the refusals a workspace brings, the step that
// gets past them in this CLI's terms. The server's own message stays first:
// it is the precise one, and this only translates field names into flags.
func explainAPIError(err error) error {
	var he *api.HTTPError
	if !errors.As(err, &he) {
		return err
	}
	body, _ := he.Body.(map[string]any)
	code := output.ToString(body["error"])
	if reason := output.ToString(body["reason"]); reason != "" {
		code = reason
	}
	hint := ""
	switch code {
	case "workspace_fixes_environment":
		hint = "A workspace fixes the environment and vault of every conversation in it: drop --environment and --vault, or name the workspace's own."
	case "environment_not_allowed", "vault_not_allowed":
		hint = "The agent's allowlist applies to a workspace's environment and vault too: launch it elsewhere, or add them to the agent's allowed_environment_ids or allowed_vault_ids."
	case "insufficient_scope":
		if output.ToString(body["required_scope"]) == "full" {
			hint = "This key is not a full-scope key. A sandbox's own MANAGOAT_TOKEN cannot use workspaces, so a conversation started from inside a sandbox always gets a sandbox of its own. Use a key from `managoat auth login` or `managoat keys create`."
		}
	case "source_in_use_by_workspace":
		hint = "Delete the workspaces created from it first (`managoat workspace list`, then `managoat workspace delete`)."
	case "invalid_sandbox_api_access":
		hint = "sandbox_api_access \"none\" needs a sandbox of the conversation's own: launch it without a workspace."
	case "machine_name_with_workspace":
		hint = "A workspace names its own machine: drop machine_name."
	case "sandbox_attach_unsupported":
		hint = "To run several conversations on one machine, create a workspace (`managoat workspace create`) and launch each with --workspace."
	}
	if hint == "" {
		return err
	}
	return fmt.Errorf("%s\n  %s", err.Error(), hint)
}

func dash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}
