package cmd

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/managoat/managoat/cli/internal/acp"
	"github.com/managoat/managoat/cli/internal/api"
	"github.com/managoat/managoat/cli/internal/config"
	"github.com/managoat/managoat/cli/internal/credentials"
	"github.com/managoat/managoat/cli/internal/output"
	"github.com/managoat/managoat/cli/internal/sse"
	"github.com/managoat/managoat/cli/internal/stream"
	"github.com/spf13/cobra"
)

var (
	acpLogLevel    string
	acpAgent       string
	acpVault       string
	acpEnvironment string
	acpPermission  string
	acpCwd         string
	acpWorkspace   string
)

func init() {
	acpCmd := &cobra.Command{
		Use:   "acp",
		Short: "Speak the Agent Client Protocol on stdio (spawned by an editor)",
		Long: `Speak the Agent Client Protocol on stdio.

Not meant to be run by hand: an ACP-capable editor spawns this process and
talks JSON-RPC to it over the pipe. stdout carries the protocol and nothing
else; diagnostics go to stderr.

--agent names the Managoat agent a session runs — the protocol has no field
for it, so it is configured here. Point one editor entry at each agent you
want to reach.

--vault attaches a vault to every conversation this process opens. Vault
values override the agent's environment, so this is where per-entry secrets
belong — an identity the agent posts under, for instance. Two entries pointing
at the same agent with different vaults stay separate; the same secret in a
shared environment would not.

--environment provisions every conversation this process opens from that
environment instead of the agent's own. One agent config can then run under
several environments — one entry per environment — without duplicating the
agent. The vault still wins over it on key collision.

--permission decides what happens before the agent runs a tool. "ask" puts the
question in your editor, as an approval prompt, and the tool waits for your
answer; "auto_deny" refuses; the default, "auto_allow", runs it. Narrow it per
tool with key=verdict pairs — --permission execute=ask asks before shell
commands and allows the rest. Keys match the tool card's title first and then
ACP's kind (execute, edit, read, fetch, …), and a launch may only narrow what
the agent already allows.

--cwd is the directory, inside the sandbox, the agent runs in: an absolute
path under /home/sprite (or /tmp for a gemini agent), created if missing.
Without it the runtime's default stands. It is not your editor's project
directory, which session/new sends and the sandbox cannot see.

--workspace opens every session on one workspace's machine (managoat
workspace) instead of a sandbox of its own, beside whatever else runs there.
The workspace fixes the environment and vault, so --environment and --vault
may only name its own. Pair it with --cwd to give each editor entry a folder.
Conversations in one workspace can read and change each other's files.

Nobody answering is an answer: an unanswered prompt is denied after the
server's timeout, and so is one your editor dismisses or disconnects from. The
turn continues either way.

What it is, and is not: a control surface for a conversation running in a
Managoat sandbox — watch it, steer it, interrupt it. It has no access to the
files open in your editor, and the paths it reports are inside the sandbox,
not on your machine.`,
		RunE: func(cmd *cobra.Command, args []string) error { return runACP() },
	}
	acpCmd.Flags().StringVar(&acpAgent, "agent", "", "Managoat agent name or id to open sessions against")
	acpCmd.Flags().StringVar(&acpVault, "vault", "", "vault name or id to attach to each session's conversation")
	acpCmd.Flags().StringVar(&acpEnvironment, "environment", "", "environment name or id to provision each session's conversation from, instead of the agent's own")
	acpCmd.Flags().StringVar(&acpPermission, "permission", "", `what happens before the agent runs a tool: auto_allow, ask, auto_deny, or key=verdict pairs (for example "execute=ask")`)
	acpCmd.Flags().StringVar(&acpCwd, "cwd", "", "working directory inside the sandbox for each session's agent (absolute, under /home/sprite)")
	acpCmd.Flags().StringVar(&acpWorkspace, "workspace", "", "workspace name or id every session's conversation runs on, instead of a sandbox of its own")
	acpCmd.Flags().StringVar(&acpLogLevel, "log-level", "info", "stderr log level: debug, info, warn, error")
	rootCmd.AddCommand(acpCmd)
}

func runACP() error {
	level, err := parseLogLevel(acpLogLevel)
	if err != nil {
		return err
	}

	// Every diagnostic goes to stderr. A single stray byte on stdout is an
	// unparseable line to the editor, which reports it as the agent crashing.
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))

	// SIGINT/SIGTERM and a closed stdin are the two ways an editor ends this
	// process, and both are ordinary. Neither is an error exit.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	permission, err := parsePermissionPolicy(acpPermission)
	if err != nil {
		return err
	}
	opts := activeOpts()
	agent := acp.NewAgent(
		cliAuth{opts: opts},
		fountainAPI{
			opts:        opts,
			log:         log,
			vault:       acpVault,
			environment: acpEnvironment,
			permission:  permission,
			cwd:         acpCwd,
			workspace:   acpWorkspace,
		},
		acpAgent,
		Version,
		log,
	)
	conn := acp.NewConn(os.Stdin, os.Stdout, log)
	// The connection is how a turn's updates reach the editor while the turn
	// is still running; without it `session/prompt` would block in silence and
	// deliver everything at the end, which is not a live session.
	agent.SetNotifier(conn)

	// An unset --agent is not fatal here: the editor still gets a working
	// handshake, and the refusal arrives at `session/new` where the editor can
	// show it. Exiting at startup instead produces a process that dies before
	// it can say why, which most clients report as "the agent crashed".
	log.Info("managoat acp starting",
		"base_url", config.BaseURL(opts),
		"profile", credentials.ProfileName(opts),
		"agent", acpAgent)

	return conn.Serve(ctx, agent)
}

func parseLogLevel(s string) (slog.Level, error) {
	switch strings.ToLower(s) {
	case "debug":
		return slog.LevelDebug, nil
	case "info":
		return slog.LevelInfo, nil
	case "warn", "warning":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	default:
		return 0, fmt.Errorf("unknown log level %q (want debug, info, warn or error)", s)
	}
}

// cliAuth resolves credentials exactly the way every other subcommand does —
// MANAGOAT_API_KEY, then the active profile in ~/.managoat/credentials. ADR
// 0015 declines ACP's remote transport partly to keep this in one place; a
// second credential path reachable only from an editor is the thing that
// decision exists to avoid.
type cliAuth struct {
	opts credentials.Opts
}

func (a cliAuth) Available() bool {
	_, err := config.APIKey(a.opts)
	return err == nil
}

// Verify ignores its context because api.Client builds its own (with a 60s
// timeout) per request. Threading one through is a change to every caller of
// that package, and belongs with the streaming work that actually needs
// cancellation (#704), not here.
func (a cliAuth) Verify(context.Context) error {
	var out authMe
	return api.New(a.opts).Get("/auth/me", &out)
}

// Describe names the instance and profile the credentials belong to. Pointing
// an editor at the wrong instance produces auth failures that look like a bad
// password, so the answer says which door was tried.
func (a cliAuth) Describe() string {
	return fmt.Sprintf("%s (profile %s)", config.BaseURL(a.opts), credentials.ProfileName(a.opts))
}

// fountainAPI is the adapter's view of the HTTP API. Every other subcommand
// reaches the API through Fatal-on-error helpers, which would be exactly wrong
// here: a failure inside a session method is a JSON-RPC error the editor
// renders, not a reason to kill a process the editor is talking to.
type fountainAPI struct {
	opts        credentials.Opts
	log         *slog.Logger
	vault       string
	environment string
	// permission is the per-launch policy every conversation this process
	// opens is started with (#939), already parsed. nil leaves the agent's own
	// policy alone.
	permission map[string]string
	// cwd is the in-sandbox working directory every conversation this
	// process opens runs in; empty leaves the runtime's default.
	cwd string
	// workspace names the workspace (ADR 0097) every conversation this
	// process opens runs on; empty gives each a sandbox of its own.
	workspace string
}

// parsePermissionPolicy turns --permission into the policy the API takes.
//
// A bare verdict is the policy's default, which is the common case: "ask before
// anything". Comma-separated key=verdict pairs narrow it per tool, and may
// include their own "default". Rejected here rather than at the server so a
// typo is a message on the editor's stderr at startup, not a 422 at the first
// `session/new`.
func parsePermissionPolicy(flag string) (map[string]string, error) {
	flag = strings.TrimSpace(flag)
	if flag == "" {
		return nil, nil
	}

	policy := map[string]string{}
	for _, part := range strings.Split(flag, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}

		key, verdict := "default", part
		if k, v, found := strings.Cut(part, "="); found {
			key, verdict = strings.TrimSpace(k), strings.TrimSpace(v)
		}
		if key == "" {
			return nil, fmt.Errorf("--permission: %q has an empty tool key", part)
		}
		if !isVerdict(verdict) {
			return nil, fmt.Errorf(
				"--permission: unknown verdict %q (want auto_allow, ask or auto_deny)", verdict)
		}
		policy[key] = verdict
	}

	if len(policy) == 0 {
		return nil, nil
	}
	return policy, nil
}

func isVerdict(v string) bool {
	return v == "auto_allow" || v == "ask" || v == "auto_deny"
}

func (f fountainAPI) Agent(_ context.Context, target string) (acp.AgentRef, error) {
	c := api.New(f.opts)

	if isUUID(target) {
		var resp struct {
			Data map[string]any `json:"data"`
		}
		if err := c.Get("/agents/"+target, &resp); err != nil {
			return acp.AgentRef{}, err
		}
		return agentRef(resp.Data), nil
	}

	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/agents", &resp); err != nil {
		return acp.AgentRef{}, err
	}
	for _, a := range resp.Data {
		if output.ToString(a["name"]) == target {
			return agentRef(a), nil
		}
	}
	return acp.AgentRef{}, fmt.Errorf("no agent named %q", target)
}

func agentRef(data map[string]any) acp.AgentRef {
	return acp.AgentRef{
		ID:      output.ToString(data["id"]),
		Name:    output.ToString(data["name"]),
		Runtime: output.ToString(data["runtime"]),
		Model:   output.ToString(data["model"]),
	}
}

func (f fountainAPI) CreateConversation(_ context.Context, agentID string, opts acp.SessionOptions) (string, bool, error) {
	channelID, fresh := opts.ChannelID, opts.Fresh
	var resp struct {
		Data map[string]any `json:"data"`
		Meta map[string]any `json:"meta"`
	}
	body := map[string]any{"agent_id": agentID}

	// The channel key makes the create a find-or-create on the server: the
	// latest live conversation for this agent + vault + channel comes back
	// with `meta.resumed: true` instead of a new one (#774). Omitted when the
	// client sent none — an empty key would be a binding to "".
	if channelID != "" {
		body["channel_id"] = channelID
		// The harness's owner rotated the channel: open a new conversation
		// even though one is bound. Only meaningful with a channel key.
		if fresh {
			body["fresh"] = true
		}
	}

	// A vault carries the secrets that belong to this entry rather than to the
	// agent — its values win over the environment's on key collision, which is
	// the point: two editor entries on one agent can hold different
	// credentials without either leaking into the other.
	if f.vault != "" {
		vaultID, err := f.vaultID()
		if err != nil {
			return "", false, err
		}
		body["vault_id"] = vaultID
	}

	// An environment override is the baseline the sandbox is provisioned from
	// instead of the agent's own (#783). Same omit-when-unset rule as the
	// vault: an empty string would name an environment called "".
	if f.environment != "" {
		envID, err := f.environmentID()
		if err != nil {
			return "", false, err
		}
		body["environment_id"] = envID
	}

	// The permission policy this entry runs under (#939). A launch may only
	// narrow the agent's own, so the server refuses a widening one with 422
	// rather than clamping it — which reaches the editor as a `session/new`
	// failure naming the tool.
	if len(f.permission) > 0 {
		body["permission_policy"] = f.permission
	}

	// The working directory inside the sandbox. Omitted when unset, as the
	// others are: the server then runs the runtime's default. A resumed
	// channel conversation must already run there, or the server says so.
	if f.cwd != "" {
		body["cwd"] = f.cwd
	}

	// The workspace whose machine the conversation joins. With a channel key
	// the server resumes only a conversation already in that workspace.
	if f.workspace != "" {
		id, err := resolveWorkspaceID(api.New(f.opts), f.workspace)
		if err != nil {
			return "", false, err
		}
		body["workspace_id"] = id
	}

	// No prompt: the conversation is created empty and the editor's first
	// `session/prompt` becomes turn 1. Provisioning starts server-side either
	// way, so the sandbox is warming while the developer types.
	if err := api.New(f.opts).Post("/conversations", body, &resp); err != nil {
		return "", false, explainAPIError(err)
	}
	id := output.ToString(resp.Data["id"])
	if id == "" {
		return "", false, fmt.Errorf("conversation created but the response carried no id")
	}
	resumed, _ := resp.Meta["resumed"].(bool)
	return id, resumed, nil
}

func (f fountainAPI) Conversation(_ context.Context, convID string) (acp.ConversationRef, error) {
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := api.New(f.opts).Get("/conversations/"+convID, &resp); err != nil {
		return acp.ConversationRef{}, err
	}
	ref := acp.ConversationRef{
		ID:      output.ToString(resp.Data["id"]),
		Runtime: output.ToString(resp.Data["runtime"]),
		Status:  output.ToString(resp.Data["status"]),
	}

	// The conversation knows its agent by id only, and a reopened session
	// still owes the client a model. Best-effort: an agent deleted since the
	// conversation ran leaves the model unreported rather than failing a load
	// that would otherwise work.
	if agentID := output.ToString(resp.Data["agent_id"]); agentID != "" {
		if agent, err := f.Agent(context.Background(), agentID); err == nil {
			ref.Agent = agent.Name
			ref.Model = agent.Model
		} else {
			f.log.Info("could not read the conversation's agent", "agent_id", agentID, "err", err)
		}
	}
	// A conversation may run a model of its own (ADR 0061), which is then the
	// one it runs whatever its agent says.
	if model := output.ToString(resp.Data["model"]); model != "" {
		ref.Model = model
	}

	return ref, nil
}

// Replay drains everything the conversation has stored on the `acp` stream and
// closes, oldest first.
//
// `wait=false` is what makes it a drain: the server replays the history and
// ends the response instead of holding the connection open (#398's sibling —
// the same endpoint, the opposite need). `Last-Event-ID: 0` starts at the
// beginning, which is exactly what `session/load` is for.
func (f fountainAPI) Replay(ctx context.Context, convID string, fn acp.EventFunc) error {
	req, err := api.New(f.opts).NewStreamRequest(ctx,
		"/conversations/"+convID+"/stream?streams=acp&wait=false", "0")
	if err != nil {
		return err
	}

	resp, err := (&http.Client{}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("replay HTTP %d: %s", resp.StatusCode, body)
	}

	// The trailing blank line makes the final event parse even when the body
	// did not end with one.
	events, _ := sse.Feed(string(body) + "\n\n")
	for _, ev := range events {
		data, ok := ev.Data.(map[string]any)
		if !ok {
			continue
		}
		stop, err := fn(acp.Event{
			Kind:   output.ToString(data["kind"]),
			Stream: output.ToString(data["stream"]),
			Data:   output.ToString(data["data"]),
			Stage:  output.ToString(data["stage"]),
			State:  output.ToString(data["state"]),
		})
		if err != nil {
			return err
		}
		if stop {
			return nil
		}
	}
	return nil
}

// Interrupt stops the running turn. A 409 means the turn had already ended —
// the normal outcome of a cancel that raced the agent finishing — and is not
// reported as a failure.
func (f fountainAPI) Interrupt(_ context.Context, convID string) error {
	err := api.New(f.opts).Post("/conversations/"+convID+"/interrupt", map[string]any{}, nil)
	if api.StatusCode(err) == 409 {
		f.log.Info("cancel arrived after the turn ended", "conversation", convID)
		return nil
	}
	return err
}

// AnswerPermission answers a held `session/request_permission` (#940). A 409
// means it was already resolved — another attached client answered it, the ask
// timeout denied it, or the turn ended — which is the documented outcome of
// losing that race, not a failure.
func (f fountainAPI) AnswerPermission(_ context.Context, convID, requestID, optionID string) error {
	path := "/conversations/" + convID + "/requests/" + url.PathEscape(requestID)
	err := api.New(f.opts).Post(path, map[string]any{"option_id": optionID}, nil)
	if api.StatusCode(err) == 409 {
		return fmt.Errorf("%w: %s", acp.ErrAlreadyResolved, err)
	}
	return err
}

// vaultID resolves --vault, which may be a name or an id.
func (f fountainAPI) vaultID() (string, error) {
	if isUUID(f.vault) {
		return f.vault, nil
	}

	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := api.New(f.opts).Get("/vaults", &resp); err != nil {
		return "", err
	}
	for _, v := range resp.Data {
		if output.ToString(v["name"]) == f.vault {
			return output.ToString(v["id"]), nil
		}
	}
	return "", fmt.Errorf("no vault named %q", f.vault)
}

func (f fountainAPI) environmentID() (string, error) {
	if isUUID(f.environment) {
		return f.environment, nil
	}

	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := api.New(f.opts).Get("/environments", &resp); err != nil {
		return "", err
	}
	for _, e := range resp.Data {
		if output.ToString(e["name"]) == f.environment {
			return output.ToString(e["id"]), nil
		}
	}
	return "", fmt.Errorf("no environment named %q", f.environment)
}

func (f fountainAPI) StreamHead(_ context.Context, convID string) (string, error) {
	return streamHead(api.New(f.opts), convID)
}

func (f fountainAPI) SendPrompt(_ context.Context, convID, prompt string, images []acp.Image, clientRequestID *string) error {
	payload := make([]map[string]string, 0, len(images))
	for _, img := range images {
		payload = append(payload, map[string]string{
			"data":       img.Data,
			"media_type": img.MediaType,
		})
	}
	body := map[string]any{"prompt": prompt, "images": payload}
	if clientRequestID != nil {
		body["client_request_id"] = *clientRequestID
	}
	return api.New(f.opts).Post("/conversations/"+convID+"/prompts", body, nil)
}

// Follow reads the conversation's stream with `?streams=acp,stage`.
//
// The filter is the reason this adapter is a forwarder rather than a parser:
// the `acp` stream is the sprite adapter's own `session/update` notifications,
// stored verbatim by the server (#644). Asking for `stdout` as well would put
// a runtime's dialect in front of a client that has no idea what it is.
func (f fountainAPI) Follow(ctx context.Context, convID, lastEventID string, fn acp.EventFunc) error {
	c := api.New(f.opts)

	open := func(ctx context.Context, lastEventID string) (io.ReadCloser, error) {
		req, err := c.NewStreamRequest(ctx, "/conversations/"+convID+"/stream?streams=acp,stage", lastEventID)
		if err != nil {
			return nil, err
		}
		// No client timeout: the idle watchdog inside the follow loop is what
		// bounds a stream, and a turn may legitimately think for a long time.
		resp, err := (&http.Client{}).Do(req)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode < 500 {
				return nil, stream.Permanent(fmt.Errorf("stream HTTP %d: %s", resp.StatusCode, body))
			}
			return nil, fmt.Errorf("stream HTTP %d: %s", resp.StatusCode, body)
		}
		return resp.Body, nil
	}

	return stream.Follow(ctx, open, stream.IdleTimeout(), convID, lastEventID, func(ev sse.Event) (bool, error) {
		data, ok := ev.Data.(map[string]any)
		if !ok {
			f.log.Debug("skipping an event with no object payload", "event", ev.Event)
			return false, nil
		}
		return fn(acp.Event{
			Kind:   output.ToString(data["kind"]),
			Stream: output.ToString(data["stream"]),
			Data:   output.ToString(data["data"]),
			Stage:  output.ToString(data["stage"]),
			State:  output.ToString(data["state"]),
		})
	})
}
