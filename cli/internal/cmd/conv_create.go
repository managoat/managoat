package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"
)

// Creation and following are separate: the API may return an idle
// conversation. Print that response without assuming a turn exists.
func newConversationCreateCommand() *cobra.Command {
	command := &cobra.Command{
		Use:   "create --file <path|->",
		Short: "Create from API-shaped JSON and print the API response",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			path, _ := cmd.Flags().GetString("file")
			reader := cmd.InOrStdin()
			if path != "-" {
				file, err := os.Open(path)
				if err != nil {
					return fmt.Errorf("read conversation request: %w", err)
				}
				defer file.Close()
				reader = file
			}
			body, err := readConversationRequest(reader)
			if err != nil {
				return err
			}
			var response json.RawMessage
			if err := activeClient().Post("/conversations", body, &response); err != nil {
				return explainAPIError(err)
			}
			encoder := json.NewEncoder(cmd.OutOrStdout())
			encoder.SetIndent("", "  ")
			return encoder.Encode(response)
		},
	}
	command.Flags().String("file", "", "conversation request JSON file, or - for stdin (required)")
	_ = command.MarkFlagRequired("file")
	return command
}

func readConversationRequest(reader io.Reader) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(reader)
	var body map[string]json.RawMessage
	if err := decoder.Decode(&body); err != nil {
		return nil, fmt.Errorf("conversation request must be a JSON object: %w", err)
	}
	if body == nil {
		return nil, fmt.Errorf("conversation request must be a JSON object")
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, fmt.Errorf("conversation request must contain exactly one JSON object")
	}
	return body, nil
}
