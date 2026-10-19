# Use the CLI

The `managoat` binary manages Managoat resources from a terminal, or from a CI
script. It is a convenience wrapper over the REST API. You can do everything
here with `curl`.

This page follows what you want to do. It shows the useful invocations, and
not each flag. For the complete list of flags, which comes
from the binary itself, read [All commands](cli/commands.md).

A command that is on neither of these two pages does not exist. A test walks
the real command tree, and it fails either way round.

## Install

```bash
brew install managoat/tap/managoat
```

Or take a release binary from the
[GitHub Releases](https://github.com/managoat/managoat/releases) page.

The CLI was called `fountain` before the project was renamed. The formula
still installs a `fountain` link to `managoat`, and `brew upgrade` moves an
old `fountain` install to the new formula. A later release drops the old
name.

On Linux, Homebrew compiles a formula and needs a C compiler first,
`build-essential` on Debian and Ubuntu. A release binary needs no compiler.

```bash
curl -fsSLO https://github.com/managoat/managoat/releases/latest/download/managoat-linux-amd64
sudo install -m 0755 managoat-linux-amd64 /usr/local/bin/managoat
```

Use `managoat-linux-arm64` on an ARM machine.

Then point the CLI at your instance and sign in, as
[Authentication](#authentication) describes.

```bash
MANAGOAT_BASE_URL=http://localhost:4000 managoat auth login
```

## Start from nothing

```bash
managoat auth register    # create an account, wait for the emailed link, save the key
managoat quickstart       # run the first request and stream the reply
```

`auth register` asks for an email address and a password, creates the
account, then waits while you click the link in your email. It saves the API
key and prints the same first request the [quickstart](quickstart.md) shows. The wait ends
after about ten minutes. The account and the emailed link both survive that,
so `managoat auth login` finishes the job later.

By default an instance closes registration once it has an admin
(`REGISTRATION_ENABLED=auto`), so `auth register` usually creates only the
first account. On a closed instance, ask its operator for an account, then
run `managoat auth login`.

`quickstart` sends that request. It runs the prompt against the agent your
account already has, streams the reply, and prints where to go next.

## Authentication

```bash
managoat auth login            # browser approval on a terminal; email + password when piped
managoat auth login --device   # force the browser approval flow
managoat auth login --password # force the email + password prompt
managoat auth login --api-key  # prompts for a pasted API key instead
managoat auth whoami           # print the current user
managoat auth logout           # remove saved credentials
```

On a terminal, `managoat auth login` signs you in through your browser. The
CLI shows a short one-time code and a console URL, and opens the URL for
you. Enter the code in the console and approve the device. The CLI waits,
collects a fresh API key, and saves it. This flow works for every account.
An account made with the "Sign up with GitHub" button has no password, so
the other flows cannot serve it.

When stdin is a pipe, the command reads an email and a password instead.
A script that feeds credentials keeps its behavior. `--password` forces that
prompt on a terminal. If the password login fails there, the CLI offers the
browser flow.

`--api-key` takes a key you created yourself. Create an API key in the
console, in the **API keys** section of **Account**. Then run `managoat auth login --api-key`
and paste the key at the prompt. The CLI checks the key against the server
and saves it. The prompt also reads a piped line, so a script can supply the
key on stdin.

`auth login` has no `--endpoint` flag. Point the CLI at a different instance
with `MANAGOAT_BASE_URL`. `auth login` then records that URL in the saved
profile.

```bash
MANAGOAT_BASE_URL=https://your-fountain.example.com managoat auth login
```

### Profiles

Use `--profile`, or `MANAGOAT_PROFILE`, to keep several instances side by
side.

```bash
MANAGOAT_BASE_URL=https://staging.example.com managoat auth login --profile staging
managoat conv list --profile staging
```

## Agents

```bash
managoat agent list [--json]
managoat agent show <id-or-name>
managoat agent create <name> --runtime claude --model anthropic/claude-sonnet-4-5 [--environment <id-or-name>] [--system-file prompt.md]
managoat agent update <id-or-name> [--model ...] [--environment ""] [--name new-name]
managoat agent delete <id-or-name>
```

`create` and `update` set the scalar fields: runtime, model, description,
system prompt, environment, the acp runtime's command and the sandbox
provider. An `update` sends only the flags you name, and an empty `--model` or
`--environment` clears that field. Skills, MCP servers, a permission policy
and the allowlists are structured, so set those with
[`managoat apply`](#apply-manifests) or the REST API.

## Environments

```bash
managoat env list [--json]
managoat env show <id-or-name>
managoat env create <name> [--setup-script-file setup.sh] [--env-var KEY=VALUE ...] [--networking limited --allow-host github.com ...]
managoat env update <id-or-name> [--setup-timeout 300] [--name new-name]
managoat env delete <id-or-name>

managoat env set-secret <id-or-name> <key> <value>
managoat env delete-secret <id-or-name> <key>
```

`--env-var` and `--allow-host` repeat, and on an `update` each replaces the
whole list rather than adding to it. Packages and repositories are set with
`apply` or the API.

## Vaults

A vault holds the credentials for one conversation, and those are the ones you
most often want to change with no edit to a manifest.

```bash
managoat vault list [--json]
managoat vault show <id-or-name>
managoat vault create <name> [--description "..."]
managoat vault delete <id-or-name>

managoat vault set-secret <id-or-name> <key> <value> [--expires-at 2027-01-15]
managoat vault set-expiry <id-or-name> <key> 2027-01-15T00:00:00Z
managoat vault set-expiry <id-or-name> <key> --clear
managoat vault delete-secret <id-or-name> <key>
```

A secret's [expiry](concepts/vault.md#secret-expiry) is advisory. It takes an
RFC 3339 time or a bare date, which means midnight UTC. `set-secret` without
`--expires-at` keeps the date a secret already has; `set-expiry` changes the
date and leaves the value alone.

None of the `delete` commands asks for confirmation.

## Conversations

```bash
managoat conv list [--json]
managoat conv show <id>
managoat conv stream <id>
managoat conv prompt <id> -p "next instruction" [-i screenshot.png]
managoat conv wake <id>
managoat conv interrupt <id>
managoat conv terminate <id>
managoat conv delete <id>
```

You can repeat `-i` and `--image`. Each one takes a local file path.

Use `--client-request-id` on `conv prompt` or `run` to name a prompt submission:

```bash
managoat conv prompt <id> -p "Run the approved plan" --client-request-id plan-7-step-3
```

Managoat stores this value on the resulting turn. It is a correlation ID, not
an idempotency key; repeating it can run the work again. Omit the flag to send
no ID. See [prompt correlation](api.md#find-the-turn-your-prompt-opened) for
the limits and how to find the turn.

Conversation output uses ACP. Setup and provisioning diagnostics and stderr
remain visible. Historical vendor stdout has no formatted transcript.
Its stored `data` remains available through `GET /api/conversations/:id/events`.

## Sandboxes

A sandbox is the computer a conversation runs on. A conversation gets a
sandbox of its own, which ends with it, unless you run it in a
[workspace](#workspaces).

```bash
managoat sandbox list [--json] [--status ready,suspended]
managoat sandbox show <id>
```

## Workspaces

A workspace is a sandbox you keep: set up once from an environment, then any
number of conversations run on it, each in its own folder.
[Run several agents on one machine](guides/agents-in-one-workspace.md) walks
through it.

```bash
managoat workspace create <name> --environment <id-or-name> [--vault <id-or-name>] [--provider sprites|e2b] [--wait] [--json]
managoat workspace list [--implicit] [--json]
managoat workspace show <id-or-name> [--json]
managoat workspace wait <id-or-name> [--timeout 30m]
managoat workspace rebuild <id-or-name> [--interrupt] [--wait] [--json]
managoat workspace retry <id-or-name> [--wait] [--json]
managoat workspace delete <id-or-name>

managoat run <agent> --workspace <id-or-name> --cwd /home/sprite/app -p "..."
```

`create` answers as soon as the workspace exists, with status
`provisioning`, and Managoat sets its machine up in the background.
`--wait`, or `workspace wait` later, follows the setup until it is `ready`,
and exits non-zero with the failing step if it is `failed`. `retry` sets a
`failed` workspace up again once you have fixed the environment; with
`--wait` it follows that setup the same way. The environment, vault and
provider are fixed for the workspace's life; an edit to the environment
reaches its next setup, a retry or a rebuild.

`--workspace` on `run` and `acp` puts the conversation on the workspace's
machine instead of a sandbox of its own. The workspace supplies the
environment and vault, so leave out `--environment` and `--vault`. Pair it
with `--cwd` to give each agent its own folder.

`list` leaves out implicit workspaces, the one each conversation run without
`--workspace` gets; `--implicit` shows them too. `show` prints the machine's
state: its status, or that it is parked and the next prompt wakes it, or
that it has none live and the next prompt builds one. Both say when the
machine is stale: the environment changed since it was built, with the names
of the fields that changed (`list`'s `stale` column).

`rebuild` applies an edited environment: it destroys the machine **with
everything on its disk** and sets up a new one from the environment as it is
now. Save work first; the workspace's `diff` route reads it while the machine
is ready. Every conversation keeps its transcript and stays in the
workspace, and its agent starts a fresh session on its next prompt. It is
refused while a conversation has a running turn; `--interrupt` interrupts
those turns instead. `--wait` follows the new setup like `create --wait`.

`delete` terminates every conversation in the workspace, keeping their
transcripts, and destroys the machine with its disk. It does not ask for
confirmation. A workspace's machine has no lifetime limit, so delete the ones
you are done with.

Conversations in one workspace can read and change each other's files and
tokens. Run without `--workspace` when a conversation must be isolated.

## Run an agent

```bash
managoat run <agent-name-or-id> -p "Audit the auth module"
managoat run <agent-name-or-id> -p "Run the test suite" --vault staging-creds
managoat run <agent-name-or-id> -p "Run the test suite" --environment staging
managoat run <agent-name-or-id> -p "Run the approved plan" --client-request-id plan-7-step-1
managoat run <agent-name-or-id> -p "Fix the API tests" --cwd /home/sprite/app/api
managoat run <agent-name-or-id> -p "Fix the API tests" --workspace app-box --cwd /home/sprite/app/api
```

For the full conversation creation API, pass a JSON object with wire names and
IDs. The command prints the complete API response; it does not start a
stream:

```bash
managoat conv create --file launch.json
cat launch.json | managoat conv create --file -
```

For example, `launch.json` can contain:

```json
{"agent_id":"<agent-id>","prompt":"Review the repository","labels":{"source":"nightly"}}
```

Omitted fields stay omitted; null, false, zero and empty values pass through.
The server validates the request. This command uses IDs directly and accepts
no name-based launch flags, so file fields cannot collide with flag defaults.
A promptless request creates an idle conversation. Use `managoat run` when you
want the existing create-and-watch shortcut.

`run` creates a conversation, then streams until the turn reaches a terminal
state.

`--vault` layers a vault's secrets over the agent's environment, and the vault
wins on a collision. `--environment` provisions from that environment, and not
from the agent's own. `--cwd` is the directory inside the sandbox the agent
runs in: `/home/sprite` or a folder under it (for a gemini agent, also under
`/tmp`), or a repository's `mount_path` in the environment the conversation
runs with, or a folder under that, created if missing. `--workspace` runs the conversation on a
[workspace](#workspaces)'s machine, which fixes the environment and vault.

A turn that its machine cuts short exits non-zero: the lifetime ceiling
parking a workspace's machine (`machine_parked`), or its machine being
destroyed (`machine_destroyed`), for example by `managoat workspace delete`
or `managoat workspace rebuild --interrupt`.

### Long-running turns

The server closes an idle SSE connection after 60 seconds. So a turn that
thinks for a while and prints nothing loses its connection.

The CLI reconnects with `Last-Event-ID`. It replays the output that arrived
while it had no connection, and it never mistakes a dropped connection for a
finished turn.

If nothing at all arrives for 30 minutes, the CLI exits with an error that
names the conversation. It does not report success. Widen the wait with
`MANAGOAT_STREAM_IDLE_TIMEOUT`, in seconds.

After a deployment disconnect, stream attachment retries for up to 180 seconds.
Set `MANAGOAT_STREAM_RECOVERY_TIMEOUT` (seconds) to change that window. The
cursor is preserved and no create or prompt request is replayed. An accepted
prompt interrupted before turn admission reports `deployment_interrupted`;
inspect the outcome before submitting it again.

```bash
MANAGOAT_STREAM_IDLE_TIMEOUT=7200 managoat run researcher -p "large refactor"
```

A disconnect loses nothing. Reattach at any time.

```bash
managoat conv stream <conversation-id>
```

## Editor integration (ACP)

```bash
managoat acp --agent <name-or-id> [--vault <name-or-id>] [--environment <name-or-id>] [--workspace <id-or-name>] [--cwd <dir>] [--log-level debug]
```

This speaks the [Agent Client Protocol](https://agentclientprotocol.com) on
stdio, so an ACP-capable editor can drive a Managoat conversation.

You do not run it yourself. The editor spawns it, and talks JSON-RPC over the
pipe. stdout carries the protocol and nothing else. Diagnostics go to stderr,
and that is where to look first when an editor reports a problem.

`--agent` names the Managoat agent that a session runs. The protocol has no
field for it, so you configure it on the command line, with one editor entry
for each agent.

The credentials are the ones that `managoat auth login` already saved.
`--profile` chooses the instance.

**[`managoat acp` (reference)](integrations/acp.md)** documents the protocol
surface and the flags in full. **[Editors (ACP)](integrations/editors.md)**
has the setup, the editor config snippets, and the limits that matter before
you start.

The first of those limits is that the agent works on a sandbox's files. It
does not work on the files open in your editor.

## Apply manifests

```bash
managoat apply -f path/to/manifest.yml
managoat apply -f path/to/directory/          # walks all *.yml / *.yaml files
managoat apply -f dir/ --var REGION=eu-west-1 # ${VAR} substitution, repeatable
```

Apply is idempotent. It creates what is new, and updates what changed. It
supports three kinds, which are `Environment`, `Vault` and `Agent`.

`--var` and `${VAR}` substitution apply to a `spec.secrets` value alone. A
`${VAR}` anywhere else in the document goes across as it stands. A
`setup_script` and a name are two such places.

The CLI compiles each document into one manifest, and sends that to
`POST /api/apply` in one request.

The server reconciles the three kinds in the order above, so an `Agent` can
name its `environment` whatever its position in the file. The name resolves
against the manifest first, then against the records your account already
holds.

The `metadata.name` is the key for every kind. An absent `spec` key leaves
that field alone.

Apply is additive. A document that you delete from the manifest leaves its
record in place. There is no prune, so delete a record with
`managoat agent delete`, `managoat env delete` or `managoat vault delete`.

The CLI prints `+` for a create, `~` for an update, `=` for a resource that
already matched the manifest, and `!` for a failure.

```
env  =  my-project
vault  =  alice
agent  ~  ada
```

A second apply of the
same file prints `=` on every row, because Managoat wrote to none of them.
Inline `spec.secrets` are the exception. Managoat encrypts them again on each
apply, so they keep printing `~` under a row that prints `=`.

The server rejects unknown `spec` keys per resource. The CLI prints those
errors and exits nonzero; valid resources in the same manifest still apply.
Correct a misspelled field before you retry.

`managoat apply` requires Managoat server v0.3.0 or later, which introduced
`POST /api/apply`. Newer document kinds and fields can require a newer server.
If the endpoint returns 404, the CLI exits nonzero without individual resource
requests. Upgrade the server or check `MANAGOAT_BASE_URL` before you retry.

### Secret references

A `spec.secrets` value can point at a secret manager, and hold no plaintext.
That is what lets you commit a manifest to git.

The CLI resolves a value that starts with one of these schemes, on the client,
at apply time. It runs the manager's own CLI, which you must install and
authenticate first.

| Scheme | Manager | Resolved with |
|---|---|---|
| `op://vault/item/field` | 1Password | `op read` |
| `bws://<secret-uuid>` | Bitwarden Secrets Manager | the `bws` CLI |
| `infisical://<project?>/<env>/<path?>/<name>` | Infisical | the `infisical` CLI |

```yaml
kind: Vault
metadata: { name: prod-tokens }
spec:
  secrets:
    GITHUB_TOKEN: op://Private/github/token
    STRIPE_KEY: bws://8f0a3c1e-...
```

A failure to resolve stops the whole apply before the CLI sends anything,
and the CLI lists every failed reference at once. So does an empty value,
which nearly always means the manager found no secret. The CLI writes no
empty secret.

The CLI resolves a `spec.secrets` value alone. The schemes are inert anywhere
else. [Manage resources as YAML](guides/manifests.md) has the manifest format,
an example of each kind, and how to set up each secret manager.

## API keys

```bash
managoat keys list [--json]
managoat keys create <name>     # prints the key once; it is not recoverable
managoat keys revoke <id>
```

## OAuth apps

Register an app that offers "Sign in with Managoat." The registration also
admits the app's redirect origins to the API.

```bash
managoat oauth-client list [--json]
managoat oauth-client create <name> --redirect-uri <url> [--redirect-uri <url>]... [--json]
managoat oauth-client update <id> [--name <name>] [--redirect-uri <url>]... [--json]
managoat oauth-client delete <id>
```

`create` prints the generated `client_id` that your app sends. A redirect
URI must match exactly and must use `https`. Loopback hosts can use `http`
and match on any port.

The app starts in development mode. It signs in only the account that
registered it. `delete` stops new sign-ins, but keys already issued stay
valid until you revoke them with `managoat keys revoke`.

## Output

A list command accepts `--json`. There is no `-o` flag, and there is no YAML
output.

```bash
managoat agent list --json | jq '.[].name'
```

## Configuration

`managoat auth login` writes `~/.managoat/credentials`, an INI-style file with
one section for each profile. It writes each value in double quotes.

```ini
[default]
api_key = "ftn_..."
base_url = "https://managoat.com"
```

The CLI writes the file `0600`, and the directory `0700`.

### Environment variables

| Variable | Effect |
|---|---|
| `MANAGOAT_API_KEY` | The API key. It wins over the credentials file. |
| `MANAGOAT_BASE_URL` | The instance URL. It wins over the credentials file. |
| `MANAGOAT_PROFILE` | The profile to use. It is the same as `--profile`. |
| `MANAGOAT_STREAM_RECOVERY_TIMEOUT` | Seconds allowed for stream reconnection after unavailability. The default is 180. |
| `MANAGOAT_STREAM_IDLE_TIMEOUT` | The seconds of silence before a stream gives up. The default is 1800. |

Each variable falls back to its old `FOUNTAIN_*` name, such as
`FOUNTAIN_API_KEY`, when it is unset, and the CLI prints a warning when it
reads one. The credentials file was `~/.fountain/credentials`. The CLI reads
that file while `~/.managoat/credentials` does not exist, and its first write
creates the new file with every profile. A later release stops reading the
old names.

```bash
MANAGOAT_API_KEY=ftn_... MANAGOAT_BASE_URL=https://other.example.com managoat agent list
```

The CLI resolves both the key and the URL in the same order. It reads the
environment variable, then the active profile in the credentials file. For the
URL alone it then falls back to the built-in default,
`https://managoat.com`.

**Do you self-host?** That built-in default is the maintainer's instance, and not
yours.

Run `managoat auth login` with `MANAGOAT_BASE_URL` pointed at your instance.
Do that first, before each other command. A CLI with no config, and `MANAGOAT_API_KEY`
exported, sends that key to `managoat.com`. Configure the URL
before the key.
