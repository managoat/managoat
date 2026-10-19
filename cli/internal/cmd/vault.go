package cmd

import (
	"fmt"
	"regexp"

	"github.com/managoat/managoat/cli/internal/api"
	"github.com/managoat/managoat/cli/internal/output"
	"github.com/spf13/cobra"
)

var uuidRE = regexp.MustCompile(`^[0-9a-fA-F-]{36}$`)

func isUUID(s string) bool { return uuidRE.MatchString(s) }

func init() {
	vaultCmd := &cobra.Command{Use: "vault", Short: "Manage vaults"}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List vaults",
		RunE:  func(cmd *cobra.Command, args []string) error { return vaultList(cmd) },
	}
	listCmd.Flags().Bool("json", false, "output JSON")

	createCmd := &cobra.Command{
		Use:   "create <name>",
		Short: "Create a vault",
		Args:  cobra.ExactArgs(1),
		RunE:  func(cmd *cobra.Command, args []string) error { return vaultCreate(cmd, args[0]) },
	}
	createCmd.Flags().String("description", "", "vault description")

	setSecretCmd := &cobra.Command{
		Use:   "set-secret <id-or-name> <key> <value>",
		Short: "Set a vault secret",
		Long: "Set a vault secret's value. Without --expires-at a secret that already\n" +
			"exists keeps its expiry; use set-expiry to change only the expiry.",
		Args: cobra.ExactArgs(3),
		RunE: func(cmd *cobra.Command, args []string) error {
			return vaultSetSecret(cmd, args[0], args[1], args[2])
		},
	}
	setSecretCmd.Flags().String("expires-at", "", "advisory expiry: RFC 3339 time or YYYY-MM-DD")

	setExpiryCmd := &cobra.Command{
		Use:   "set-expiry <id-or-name> <key> [<expires-at>]",
		Short: "Set or clear a vault secret's expiry",
		Long: "Change a vault secret's advisory expiry without touching its value. The\n" +
			"time is RFC 3339 or YYYY-MM-DD (midnight UTC); --clear removes it.",
		Args: cobra.RangeArgs(2, 3),
		RunE: func(cmd *cobra.Command, args []string) error { return vaultSetExpiry(cmd, args) },
	}
	setExpiryCmd.Flags().Bool("clear", false, "remove the expiry")

	vaultCmd.AddCommand(
		listCmd,
		createCmd,
		&cobra.Command{
			Use:   "show <id-or-name>",
			Short: "Show a vault",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return vaultShow(args[0]) },
		},
		&cobra.Command{
			Use:   "delete <id-or-name>",
			Short: "Delete a vault",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return vaultDelete(args[0]) },
		},
		setSecretCmd,
		setExpiryCmd,
		&cobra.Command{
			Use:   "delete-secret <id-or-name> <key>",
			Short: "Delete a vault secret",
			Args:  cobra.ExactArgs(2),
			RunE: func(cmd *cobra.Command, args []string) error {
				return vaultDeleteSecret(args[0], args[1])
			},
		},
	)
	rootCmd.AddCommand(vaultCmd)
}

func vaultList(cmd *cobra.Command) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/vaults", &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, v := range resp.Data {
		rows = append(rows, []string{
			output.ToString(v["name"]),
			output.ShortID(output.ToString(v["id"])),
			output.Truncate(output.ToString(v["description"]), 60),
		})
	}
	output.Table([]string{"name", "id", "description"}, rows)
	return nil
}

func vaultShow(target string) error {
	c := activeClient()
	id := resolveVaultID(target)
	var vresp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Get("/vaults/"+id, &vresp); err != nil {
		Fatal(err.Error())
	}
	var sresp struct {
		Data any `json:"data"`
	}
	if err := c.Get("/vaults/"+id+"/secrets", &sresp); err != nil {
		Fatal(err.Error())
	}
	vresp.Data["secrets"] = sresp.Data
	return output.PrintJSON(vresp.Data)
}

func vaultCreate(cmd *cobra.Command, name string) error {
	desc, _ := cmd.Flags().GetString("description")
	c := activeClient()
	var resp struct {
		Data map[string]any `json:"data"`
	}
	body := map[string]string{"name": name, "description": desc}
	if err := c.Post("/vaults", body, &resp); err != nil {
		Fatal(err.Error())
	}
	fmt.Printf("vault  +  %s (%s)\n", output.ToString(resp.Data["name"]), output.ToString(resp.Data["id"]))
	return nil
}

func vaultDelete(target string) error {
	c := activeClient()
	id := resolveVaultID(target)
	if err := c.Delete("/vaults/"+id, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(explainAPIError(err).Error())
	}
	fmt.Printf("deleted %s\n", id)
	return nil
}

func vaultSetSecret(cmd *cobra.Command, target, key, value string) error {
	body := map[string]any{"key": key, "value": value}
	if cmd.Flags().Changed("expires-at") {
		raw, _ := cmd.Flags().GetString("expires-at")
		at, err := parseExpiry(raw)
		if err != nil {
			Fatalf("--expires-at: want an RFC 3339 time or YYYY-MM-DD, got %q", raw)
		}
		body["expires_at"] = at
	}
	c := activeClient()
	id := resolveVaultID(target)
	if err := c.Post("/vaults/"+id+"/secrets", body, nil); err != nil {
		Fatal(err.Error())
	}
	fmt.Printf("secret  +  %s\n", key)
	return nil
}

// vaultSetExpiry sends PATCH /vaults/:id/secrets/:key, which changes only the
// expiry: null clears it, and the value is never sent.
func vaultSetExpiry(cmd *cobra.Command, args []string) error {
	clearExpiry, _ := cmd.Flags().GetBool("clear")
	if clearExpiry == (len(args) == 3) {
		Fatal("pass an expiry time or --clear, exactly one")
	}
	target, key := args[0], args[1]
	var expiresAt any
	if !clearExpiry {
		at, err := parseExpiry(args[2])
		if err != nil {
			Fatalf("want an RFC 3339 time or YYYY-MM-DD, got %q", args[2])
		}
		expiresAt = at
	}
	c := activeClient()
	id := resolveVaultID(target)
	if err := c.Patch("/vaults/"+id+"/secrets/"+key, map[string]any{"expires_at": expiresAt}, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(err.Error())
	}
	if clearExpiry {
		fmt.Printf("secret  ~  %s expires never\n", key)
	} else {
		fmt.Printf("secret  ~  %s expires %s\n", key, expiresAt)
	}
	return nil
}

func vaultDeleteSecret(target, key string) error {
	c := activeClient()
	id := resolveVaultID(target)
	if err := c.Delete("/vaults/"+id+"/secrets/"+key, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(err.Error())
	}
	fmt.Printf("deleted secret %s\n", key)
	return nil
}

// resolveVaultID accepts a UUID or vault name; for names it queries
// /vaults and matches by exact name.
func resolveVaultID(target string) string {
	if isUUID(target) {
		return target
	}
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/vaults", &resp); err != nil {
		Fatal(err.Error())
	}
	for _, v := range resp.Data {
		if output.ToString(v["name"]) == target {
			return output.ToString(v["id"])
		}
	}
	Fatalf("no vault named %q", target)
	return ""
}
