package cmd

import (
	"fmt"

	"github.com/managoat/managoat/cli/internal/api"
	"github.com/managoat/managoat/cli/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	envCmd := &cobra.Command{Use: "env", Short: "Manage environments"}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List environments",
		RunE:  func(cmd *cobra.Command, args []string) error { return envList(cmd) },
	}
	listCmd.Flags().Bool("json", false, "output JSON")

	createCmd := &cobra.Command{
		Use:   "create <name>",
		Short: "Create an environment",
		Long: "Create an environment from flags. Packages and repositories are set with\n" +
			"`managoat apply`.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error { return envCreate(cmd, args[0]) },
	}
	addEnvFlags(createCmd)

	updateCmd := &cobra.Command{
		Use:   "update <id-or-name>",
		Short: "Update an environment",
		Long: "Change the fields named by flags and leave the rest as they are. --env-var\n" +
			"and --allow-host replace the whole list, not one entry of it.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error { return envUpdate(cmd, args[0]) },
	}
	updateCmd.Flags().String("name", "", "new environment name")
	addEnvFlags(updateCmd)

	envCmd.AddCommand(
		listCmd,
		&cobra.Command{
			Use:   "show <id-or-name>",
			Short: "Show an environment",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return envShow(args[0]) },
		},
		createCmd,
		updateCmd,
		&cobra.Command{
			Use:   "delete <id-or-name>",
			Short: "Delete an environment",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return envDelete(args[0]) },
		},
		&cobra.Command{
			Use:   "set-secret <id-or-name> <key> <value>",
			Short: "Set an environment secret",
			Args:  cobra.ExactArgs(3),
			RunE: func(cmd *cobra.Command, args []string) error {
				return envSetSecret(args[0], args[1], args[2])
			},
		},
		&cobra.Command{
			Use:   "delete-secret <id-or-name> <key>",
			Short: "Delete an environment secret",
			Args:  cobra.ExactArgs(2),
			RunE: func(cmd *cobra.Command, args []string) error {
				return envDeleteSecret(args[0], args[1])
			},
		},
	)
	rootCmd.AddCommand(envCmd)
}

func addEnvFlags(c *cobra.Command) {
	f := c.Flags()
	f.String("setup-script", "", "shell script run when a sandbox is provisioned")
	f.String("setup-script-file", "", "read the setup script from a file")
	f.Int("setup-timeout", 0, "setup script timeout in seconds (1-900, default 120)")
	f.StringArray("env-var", nil, "non-secret variable KEY=VALUE (repeatable)")
	f.String("networking", "", "networking: unrestricted or limited")
	f.StringArray("allow-host", nil, "host the sandbox may reach when networking is limited (repeatable)")
}

// envBody builds a request body from the flags the caller set, as agentBody
// does for agents.
func envBody(cmd *cobra.Command) map[string]any {
	f := cmd.Flags()
	body := map[string]any{}
	setString(f, body, "name", "name", false)
	setTextOrFile(f, body, "setup-script", "setup_script")
	setString(f, body, "networking", "networking_type", false)
	if f.Changed("setup-timeout") {
		v, _ := f.GetInt("setup-timeout")
		body["setup_timeout_seconds"] = v
	}
	if f.Changed("env-var") {
		pairs, _ := f.GetStringArray("env-var")
		body["env_vars"] = parseKeyValues("env-var", pairs)
	}
	if f.Changed("allow-host") {
		hosts, _ := f.GetStringArray("allow-host")
		body["networking_config"] = map[string]any{"allowed_hosts": hosts}
	}
	return body
}

func envList(cmd *cobra.Command) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/environments", &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, e := range resp.Data {
		rows = append(rows, []string{
			output.ToString(e["name"]),
			output.ToString(e["networking_type"]),
			output.Truncate(output.ToString(e["setup_script"]), 60),
		})
	}
	output.Table([]string{"name", "networking", "setup_script"}, rows)
	return nil
}

func envShow(target string) error {
	c := activeClient()
	id := resolveEnvironmentID(target)
	var envResp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Get("/environments/"+id, &envResp); err != nil {
		Fatal(err.Error())
	}
	var secResp struct {
		Data any `json:"data"`
	}
	if err := c.Get("/environments/"+id+"/secrets", &secResp); err != nil {
		Fatal(err.Error())
	}
	envResp.Data["secrets"] = secResp.Data
	return output.PrintJSON(envResp.Data)
}

func envCreate(cmd *cobra.Command, name string) error {
	body := envBody(cmd)
	body["name"] = name
	c := activeClient()
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Post("/environments", body, &resp); err != nil {
		Fatal(err.Error())
	}
	fmt.Printf("env  +  %s (%s)\n", output.ToString(resp.Data["name"]), output.ToString(resp.Data["id"]))
	return nil
}

func envUpdate(cmd *cobra.Command, target string) error {
	body := envBody(cmd)
	if len(body) == 0 {
		Fatal("nothing to update: name at least one field to change (see --help)")
	}
	c := activeClient()
	id := resolveEnvironmentID(target)
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Patch("/environments/"+id, body, &resp); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(err.Error())
	}
	fmt.Printf("env  ~  %s (%s)\n", output.ToString(resp.Data["name"]), output.ToString(resp.Data["id"]))
	return nil
}

func envDelete(target string) error {
	c := activeClient()
	id := resolveEnvironmentID(target)
	if err := c.Delete("/environments/"+id, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(explainAPIError(err).Error())
	}
	fmt.Printf("deleted %s\n", id)
	return nil
}

func envSetSecret(target, key, value string) error {
	c := activeClient()
	id := resolveEnvironmentID(target)
	if err := c.Post("/environments/"+id+"/secrets", map[string]string{"key": key, "value": value}, nil); err != nil {
		Fatal(err.Error())
	}
	fmt.Printf("secret  +  %s\n", key)
	return nil
}

func envDeleteSecret(target, key string) error {
	c := activeClient()
	id := resolveEnvironmentID(target)
	if err := c.Delete("/environments/"+id+"/secrets/"+key, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(err.Error())
	}
	fmt.Printf("deleted secret %s\n", key)
	return nil
}

// resolveEnvironmentID accepts a UUID or an environment name and returns the id,
// exactly as resolveVaultID does for vaults. Fatal on an unknown name.
func resolveEnvironmentID(target string) string {
	if isUUID(target) {
		return target
	}
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/environments", &resp); err != nil {
		Fatal(err.Error())
	}
	for _, e := range resp.Data {
		if output.ToString(e["name"]) == target {
			return output.ToString(e["id"])
		}
	}
	Fatalf("no environment named %q", target)
	return ""
}
