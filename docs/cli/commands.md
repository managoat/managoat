# All commands

<!-- GENERATED FILE. Do not edit.

     Rendered from the Cobra command tree by
     cli/internal/cmd/docsgen_test.go. Regenerate with:

         cd cli && go test ./internal/cmd/ -update-cli-docs

     Prose about what a command is for, and which one to reach for, belongs in
     the hand-written index at docs/cli.md. This file is the flag-complete
     description and nothing else. -->

Every command and every flag, generated from the binary. For what to reach for
and why, start at the [CLI guide](../cli.md).

## `managoat acp`

Speak the Agent Client Protocol on stdio (spawned by an editor)

Speak the Agent Client Protocol on stdio.

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
path under /home/sprite (or /tmp for a gemini agent) or under a repository
mount_path of the environment it launches with, created if missing.
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
not on your machine.

```
managoat acp [flags]
```

Options:

```
      --agent string         Managoat agent name or id to open sessions against
      --cwd string           working directory inside the sandbox for each session's agent (absolute, under /home/sprite or a repository mount)
      --environment string   environment name or id to provision each session's conversation from, instead of the agent's own
      --log-level string     stderr log level: debug, info, warn, error (default "info")
      --permission string    what happens before the agent runs a tool: auto_allow, ask, auto_deny, or key=verdict pairs (for example "execute=ask")
      --vault string         vault name or id to attach to each session's conversation
      --workspace string     workspace name or id every session's conversation runs on, instead of a sandbox of its own
```

## `managoat agent create`

Create an agent

Create an agent from flags. Skills, MCP servers, a permission policy and
the other structured fields are set with `managoat apply`.

```
managoat agent create <name> [flags]
```

Options:

```
      --description string        agent description
      --environment string        environment id or name
      --model string              model as provider/name, e.g. anthropic/claude-sonnet-4-5
      --runtime string            runtime: claude, codex, gemini or acp
      --runtime-command string    command the acp runtime launches in the sandbox
      --sandbox-provider string   sandbox backend override: sprites or e2b
      --system string             system prompt
      --system-file string        read the system prompt from a file
```

## `managoat agent delete`

Delete an agent

```
managoat agent delete <id-or-name>
```

## `managoat agent list`

List agents

```
managoat agent list [flags]
```

Options:

```
      --json   output JSON
```

## `managoat agent show`

Show an agent

```
managoat agent show <id-or-name>
```

## `managoat agent update`

Update an agent

Change the fields named by flags and leave the rest as they are. An empty
--model or --environment clears that field.

```
managoat agent update <id-or-name> [flags]
```

Options:

```
      --description string        agent description
      --environment string        environment id or name
      --model string              model as provider/name, e.g. anthropic/claude-sonnet-4-5
      --name string               new agent name
      --runtime string            runtime: claude, codex, gemini or acp
      --runtime-command string    command the acp runtime launches in the sandbox
      --sandbox-provider string   sandbox backend override: sprites or e2b
      --system string             system prompt
      --system-file string        read the system prompt from a file
```

## `managoat apply`

Apply resource definitions from a YAML file or directory

```
managoat apply [flags]
```

Options:

```
  -f, --file string       path to YAML file or directory
      --var stringArray   extra variable for ${VAR} substitution (KEY=VAL, repeatable)
```

## `managoat auth login`

Authenticate and save credentials

```
managoat auth login [flags]
```

Options:

```
      --api-key    paste an API key you created in the console
      --device     sign in by approving this device in your browser (the default on a terminal)
      --password   sign in with email + password (the default when stdin is piped)
```

## `managoat auth logout`

Remove saved credentials

```
managoat auth logout
```

## `managoat auth register`

Create an account, wait for the emailed link, and save the key

Creates the account, waits while you click the link in your email, saves the API key, and prints the same first request the manual shows.

```
managoat auth register [flags]
```

Options:

```
      --email string      email address (prompted for when omitted)
      --password string   password (prompted for when omitted, which keeps it out of shell history)
```

## `managoat auth whoami`

Print current user info

```
managoat auth whoami
```

## `managoat conv create`

Create from API-shaped JSON and print the API response

```
managoat conv create --file <path|-> [flags]
```

Options:

```
      --file string   conversation request JSON file, or - for stdin (required)
```

## `managoat conv delete`

Delete a conversation

```
managoat conv delete <id>
```

## `managoat conv interrupt`

Interrupt the running turn

```
managoat conv interrupt <id>
```

## `managoat conv list`

List conversations

```
managoat conv list [flags]
```

Options:

```
      --json   output JSON
```

## `managoat conv prompt`

Send a prompt to a conversation and stream the result

```
managoat conv prompt <id> [flags]
```

Options:

```
      --client-request-id string   caller-provided prompt correlation ID (not an idempotency key)
  -i, --image strings              image file path (repeatable)
  -p, --prompt string              prompt text (required)
```

## `managoat conv show`

Show a conversation

```
managoat conv show <id>
```

## `managoat conv stream`

Stream conversation events

```
managoat conv stream <id>
```

## `managoat conv terminate`

Terminate a conversation

```
managoat conv terminate <id>
```

## `managoat conv wake`

Bring the sandbox up without sending a prompt

```
managoat conv wake <id>
```

## `managoat env create`

Create an environment

Create an environment from flags. Packages and repositories are set with
`managoat apply`.

```
managoat env create <name> [flags]
```

Options:

```
      --allow-host stringArray     host the sandbox may reach when networking is limited (repeatable)
      --env-var stringArray        non-secret variable KEY=VALUE (repeatable)
      --networking string          networking: unrestricted or limited
      --setup-script string        shell script run when a sandbox is provisioned
      --setup-script-file string   read the setup script from a file
      --setup-timeout int          setup script timeout in seconds (1-900, default 120)
```

## `managoat env delete`

Delete an environment

```
managoat env delete <id-or-name>
```

## `managoat env delete-secret`

Delete an environment secret

```
managoat env delete-secret <id-or-name> <key>
```

## `managoat env list`

List environments

```
managoat env list [flags]
```

Options:

```
      --json   output JSON
```

## `managoat env set-secret`

Set an environment secret

```
managoat env set-secret <id-or-name> <key> <value>
```

## `managoat env show`

Show an environment

```
managoat env show <id-or-name>
```

## `managoat env update`

Update an environment

Change the fields named by flags and leave the rest as they are. --env-var
and --allow-host replace the whole list, not one entry of it.

```
managoat env update <id-or-name> [flags]
```

Options:

```
      --allow-host stringArray     host the sandbox may reach when networking is limited (repeatable)
      --env-var stringArray        non-secret variable KEY=VALUE (repeatable)
      --name string                new environment name
      --networking string          networking: unrestricted or limited
      --setup-script string        shell script run when a sandbox is provisioned
      --setup-script-file string   read the setup script from a file
      --setup-timeout int          setup script timeout in seconds (1-900, default 120)
```

## `managoat keys create`

Create a new API key

```
managoat keys create <name>
```

## `managoat keys list`

List API keys

```
managoat keys list [flags]
```

Options:

```
      --json   output JSON
```

## `managoat keys revoke`

Revoke an API key

```
managoat keys revoke <id>
```

## `managoat oauth-client create`

Register an OAuth app

```
managoat oauth-client create <name> [flags]
```

Options:

```
      --json                       output JSON
      --redirect-uri stringArray   where the code is returned to; repeatable
```

## `managoat oauth-client delete`

Unregister an OAuth app

```
managoat oauth-client delete <id>
```

## `managoat oauth-client list`

List OAuth apps

```
managoat oauth-client list [flags]
```

Options:

```
      --json   output JSON
```

## `managoat oauth-client update`

Rename an OAuth app or replace its redirect URIs

```
managoat oauth-client update <id> [flags]
```

Options:

```
      --json                       output JSON
      --name string                new name
      --redirect-uri stringArray   replaces every redirect URI; repeatable
```

## `managoat quickstart`

Run the first request against your default agent and stream the reply

Sends the same prompt the manual shows, to the agent this account already has, and streams the reply. It is `managoat run` with the agent and the prompt filled in.

```
managoat quickstart
```

## `managoat run`

Run an agent (create conversation + stream until done)

```
managoat run <agent-name-or-id> [flags]
```

Options:

```
      --client-request-id string   caller-provided prompt correlation ID (not an idempotency key)
      --cwd string                 working directory inside the sandbox for the agent (absolute, under /home/sprite or a repository mount; created if missing)
      --environment string         environment name or id to provision from, instead of the agent's own
  -p, --prompt string              prompt text (required)
      --vault string               vault name or id
      --workspace string           workspace name or id to run on, beside the conversations already there
```

## `managoat sandbox list`

List sandboxes

```
managoat sandbox list [flags]
```

Options:

```
      --json            output JSON
      --status string   comma-separated statuses to include (default: all)
```

## `managoat sandbox show`

Show a sandbox and the conversations on it

```
managoat sandbox show <id>
```

## `managoat vault create`

Create a vault

```
managoat vault create <name> [flags]
```

Options:

```
      --description string   vault description
```

## `managoat vault delete`

Delete a vault

```
managoat vault delete <id-or-name>
```

## `managoat vault delete-secret`

Delete a vault secret

```
managoat vault delete-secret <id-or-name> <key>
```

## `managoat vault list`

List vaults

```
managoat vault list [flags]
```

Options:

```
      --json   output JSON
```

## `managoat vault set-expiry`

Set or clear a vault secret's expiry

Change a vault secret's advisory expiry without touching its value. The
time is RFC 3339 or YYYY-MM-DD (midnight UTC); --clear removes it.

```
managoat vault set-expiry <id-or-name> <key> [<expires-at>] [flags]
```

Options:

```
      --clear   remove the expiry
```

## `managoat vault set-secret`

Set a vault secret

Set a vault secret's value. Without --expires-at a secret that already
exists keeps its expiry; use set-expiry to change only the expiry.

```
managoat vault set-secret <id-or-name> <key> <value> [flags]
```

Options:

```
      --expires-at string   advisory expiry: RFC 3339 time or YYYY-MM-DD
```

## `managoat vault show`

Show a vault

```
managoat vault show <id-or-name>
```

## `managoat workspace create`

Create a workspace and start setting up its machine

Create a workspace and start setting up its machine at once: the
environment's packages, repositories and setup script, with the vault's
secrets overriding the environment's. The environment, vault and provider are
fixed for the workspace's life.

Without --wait the command returns as soon as the workspace exists, with
status provisioning. With --wait it follows the setup and exits non-zero if it
fails. Conversations can be launched into a workspace before it is ready;
their first prompt waits for it.

```
managoat workspace create <name> [flags]
```

Options:

```
      --environment string   environment name or id the machine is set up from (required)
      --json                 print the workspace as JSON
      --provider string      sandbox provider: sprites or e2b (default: the instance's)
      --timeout duration     how long --wait waits (default 30m0s)
      --vault string         vault name or id whose secrets override the environment's
      --wait                 wait until the workspace is ready, and fail if its setup fails
```

## `managoat workspace delete`

Delete a workspace: terminate its conversations and destroy its machine

Delete a workspace. Every live conversation in it is terminated (their
transcripts are kept) and its machine is destroyed, with everything on its
disk. It is not refused while conversations are running.

```
managoat workspace delete <id-or-name>
```

## `managoat workspace list`

List workspaces

```
managoat workspace list [flags]
```

Options:

```
      --implicit   also list implicit workspaces, one per conversation launched without --workspace
      --json       output JSON
```

## `managoat workspace rebuild`

Rebuild a workspace's machine from its environment as it is now

Rebuild a workspace's machine: destroy it, with everything on its disk,
and set up a new one from the environment as it is now. Use it after editing
the environment (`managoat workspace show` says when the machine is stale).

The disk is wiped. Save any work on it first, for example with
`GET /api/workspaces/<id>/diff`.

Every conversation in the workspace keeps its transcript and stays in it,
with its runtime session cleared: its agent starts fresh on its next prompt.
The command is refused while any conversation has a running turn, unless
--interrupt, which interrupts those turns. With --wait it follows the setup
and exits non-zero if it fails.

```
managoat workspace rebuild <id-or-name> [flags]
```

Options:

```
      --interrupt          interrupt running turns rather than be refused
      --json               print the workspace as JSON
      --timeout duration   how long --wait waits (default 30m0s)
      --wait               wait until the workspace is ready, and fail if its setup fails
```

## `managoat workspace show`

Show a workspace and its machine

```
managoat workspace show <id-or-name> [flags]
```

Options:

```
      --json   output JSON
```

## `managoat workspace wait`

Wait until a workspace is ready, and fail if its setup fails

```
managoat workspace wait <id-or-name> [flags]
```

Options:

```
      --timeout duration   how long to wait (default 30m0s)
```

## Global flags

Accepted by every command.

```
      --profile string   credentials profile name
```
