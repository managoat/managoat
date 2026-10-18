# Run Codex as an API

> OpenAI's Codex CLI, headless in the sandbox.

Run Codex on a sandbox with your repositories, packages and credentials.
Send a prompt over HTTP, follow the transcript, and send the next prompt to
the same conversation. Managoat manages the machine between turns.

To use a chat interface, [open Conversations](https://fountain-conversations.demo.managoat.com/).
To call it from your own code, follow the [quickstart](../../quickstart.md),
then use the agent definition below.

## Summary

| | |
|---|---|
| Provider | `openai` |
| Multi-provider | No |
| Transport | ACP, through the pinned `codex-acp` adapter |
| Skills root | `$CODEX_HOME/skills`, in the conversation's [config home](index.md#where-skills-and-prompts-land) |
| System prompt | `$CODEX_HOME/AGENTS.md` |
| Credential | An OpenAI API key |

## Why you would choose this one

You want an OpenAI model to do the work. Or you compare two runtimes on the
same task.

## Set it up

```yaml
apiVersion: managoat/v1
kind: Agent
metadata:
  name: reviewer
spec:
  runtime: codex
  model: openai/gpt-6-astra
```

The model must carry the `openai/` prefix.

Add your OpenAI key at `/account/inference-credentials` in the app, or link
a ChatGPT plan there instead: see
[Run Codex on a ChatGPT subscription](../../guides/chatgpt-subscription.md).

## Call it over HTTP

After you apply the agent definition, set `MANAGOAT_AGENT_ID` to the returned
agent id, `MANAGOAT_BASE_URL` to your instance URL, and `MANAGOAT_API_KEY` to
your Managoat account key. The account key is separate from the model credential.

```sh
--8<-- "apps/fountain/priv/first_request/first-request.sh"
```

Use the returned conversation id to [follow events and send another prompt](../../guides/http-api.md).
A self-hosted instance uses the same request at its own base URL.

## Verify

Check the turn's `model_selection` in `GET /api/conversations/:id/turns`.
The same fields appear in the `model` stream stage:

- `requested_model`: the ID sent to the runtime.
- `effective_model`: the runtime's selected ID, or `null` on selection failure.
- `source`: `runtime` for a returned model field, or `selection_ack` when the
  runtime accepted the setter without returning a model field.
- `status` and `error`: whether selection succeeded and the failure message.

Selection evidence is separate from the agent's saved model. To verify actual
execution, inspect Codex's session JSONL `turn_context.payload.model`. An
assistant's answer about its model is not execution evidence.

An explicit model that the runtime rejects stops the turn before inference.
Managoat does not substitute another model. An unavailable ID in the runtime
catalog does not, by itself, prove that your provider account lacks access.
Check the bundled Codex version, its refreshed `model/list` response, and the
provider response with the same credentials.

Managoat checks the pinned adapter version before opening a new connection,
including on a sandbox that woke from a park. An existing connection keeps its process
until it closes. If an old runtime rejects the model, the failed connection
closes; retrying opens the updated adapter against the same session and disk.
The sandbox must allow registry access through its configured network path.

A saved agent model change takes effect on the next user turn, including on
an existing ACP connection. The conversation, session, transcript and worktree
remain in place. A change during a running turn applies to the next turn.

## The sandbox codex builds for itself

Codex applies a sandbox policy of its own **inside** the Managoat sandbox. The
pinned `codex-acp` adapter sends that policy with each session. By default a
command can write to the workspace (the conversation's working directory), to
the environment's repositories and to the temporary directories, and it cannot
reach the network.

| What the adapter sends | Default |
|---|---|
| The sandbox | `workspaceWrite` |
| `writableRoots` | each repository's `mount_path`, and its `.git` |
| `networkAccess` | `false` |
| `excludeSlashTmp` | `false`, so `/tmp` is writable |
| `excludeTmpdirEnvVar` | `false`, so `$TMPDIR` is writable |
| The approval policy | `on-request` |
| The approvals reviewer | `auto_review`, or `user` under a permission policy that asks |

Managoat sends each repository's `mount_path`, and the `.git` inside it, to
the adapter as ACP `additionalDirectories` entries, and the adapter adds them
to `writableRoots`. The `.git` has to be named on its own because codex keeps
`.git` read-only inside every writable root, so a branch or a commit fails
with the clone alone. The agent can therefore commit to a clone Managoat made
for it, and cut a worktree from it, even though the clone lives outside the
workspace. That includes `.git/hooks` and `.git/config`, which the Managoat
sandbox, and not codex's, contains.

Inside that sandbox, other writes and all network calls are still refused. A
write outside the workspace, the repositories and the temporary directories
fails. And a network call fails, so `git fetch`, a package install and a
`curl` the agent runs itself all fail.

A refusal is not always the end. Because the approval policy is `on-request`,
codex can ask to run a refused command outside the sandbox, or ask for network
or file-system access. Who answers depends on the agent's
[permission policy](../../concepts/permissions.md).

| The permission policy | Codex's mode | Who answers codex's requests |
|---|---|---|
| Every verdict `auto_allow`, or none set | `agent` | Codex's automatic reviewer, without asking Managoat |
| Any `ask` or `auto_deny` verdict | `workspace-write` | The policy, through `session/request_permission` |

Managoat picks the mode each time it starts the adapter. `workspace-write`
keeps the same sandbox: a command can still write to the workspace, the
repositories and the temporary directories without asking. Only the reviewer
changes. An approval can let that one command run, or grant the access for
the turn or the session. codex's `read-only` mode is a different one: its
sandbox refuses every write, and Managoat never picks it, but an environment
can set it with `INITIAL_AGENT_MODE`, as [full access](#give-codex-full-access)
is set below.

A refusal ends the turn. A request that is refused, by a person, by
`auto_deny` or by the 5-minute timeout, stops the turn as `cancelled`, even
when codex offered a `reject_once` option and Managoat chose it. Managoat
records that turn as `failed`. The conversation keeps its session, and the
next prompt continues it.

Try this route before full access, which removes both the sandbox and the
approvals.

`$CODEX_HOME/config.toml` does not widen it. The adapter sends an explicit
per-session policy, and that policy wins over the file, in the same way the
`CODEX_CONFIG` overlay wins over a `model_provider` written into it.

### Give codex full access

Full access is for an agent that needs the network, or writes outside its
workspace, on every turn and without asking. Set `INITIAL_AGENT_MODE` to
`agent-full-access` in the [environment's](../../concepts/environment.md)
`env_vars`. The adapter reads it
from the process environment when it opens the session.

```yaml
apiVersion: managoat/v1
kind: Environment
metadata:
  name: codex-full-access
spec:
  env_vars:
    INITIAL_AGENT_MODE: agent-full-access
```

Six things follow from that.

- **It also turns off codex's own approvals.** The mode sets the adapter's
  approval policy to `never` as well as the sandbox to `dangerFullAccess`. Codex
  then runs its shell commands and file edits without asking. Managoat applies
  the agent's [permission policy](../../concepts/permissions.md) only when a
  runtime sends `session/request_permission`, and it cannot hold or deny an
  operation that sends no request. So Managoat ignores this setting under a
  policy with an `ask` or `auto_deny` verdict, and starts codex in its asking
  mode instead. Full access takes effect only for agents whose policy is
  `auto_allow` throughout. The reverse does not hold: a policy of
  `auto_allow` does not remove the sandbox. It approves only the requests that
  codex sends to Managoat.
- **It is all or nothing.** The value names a mode, not a list. The
  environment's repositories are already writable without it, but there is no
  way to add network access on its own, or a writable directory that is not a
  repository. The adapter has no per-session network setting short of full
  access. [#1684](https://github.com/managoat/managoat/issues/1684) tracks the
  rest.
- **It does not widen Managoat's own egress.** An environment with
  `networking_type: limited`, and the credential broker, still
  decide which hosts a request reaches. Full access lets codex attempt the
  call. The
  [network policy](../../concepts/environment.md#the-network-policy-is-not-symmetric)
  decides whether it lands, and a host that is not allowed still gets a 403
  that names it.
- **Every conversation on that environment gets it.** Give the agents that
  need full access an environment of their own. A launch can then name it with
  `environment_id`, within the agent's `allowed_environment_ids`, rather than
  widening the environment everything else shares.
- **The value is scrubbed from the logs.** It is longer than the 8-byte
  redaction floor, so an agent that prints its environment shows
  `INITIAL_AGENT_MODE=[REDACTED]`. That is the scrubber working, and not a
  variable that failed to arrive. Read
  [Where a secret comes from](../../concepts/secrets.md#hop-5-a-hop-back-managoat-scrubs-the-output).
- **It is codex only.** claude and gemini do not express a sandbox
  this way. The variable reaches them and means nothing to them.

## Limits

The CLI takes the bare model id, so Managoat removes the `openai/` prefix
before it calls the CLI. You never see that in normal use. It matters when you
read a spawn command in the logs.

Managoat moves the conversation onto a model provider of its own. The provider is the same endpoint with the
WebSocket transport off. Codex's WebSocket dialer cannot use the broker's
https-scheme proxy. It waits out the full connect timeout before it falls back
to HTTP, which was about 300 seconds on every turn. Managoat
carries across `OPENAI_BASE_URL`, the OpenAI-Organization and OpenAI-Project
header mappings, and standalone web search. A conversation with no
`OPENAI_API_KEY` keeps the built-in provider, which reads `$CODEX_HOME/auth.json`.

Managoat also sets `MODEL_PROVIDER` to that provider. The ACP adapter passes
this variable to Codex when it resumes a conversation. Without it, a resumed
conversation went back to the built-in provider and to the WebSocket wait.

Managoat reads only the `CODEX_CONFIG` overlay and `MODEL_PROVIDER` when it
does this. A `model_provider` that your setup script writes into
`$CODEX_HOME/config.toml` is not read, and the overlay wins over the file. An
agent that reached a gateway that way now reaches the endpoint above instead.
To keep your own provider, name it in `CODEX_CONFIG` or in `MODEL_PROVIDER`.
Managoat leaves both alone.

The sandbox images do not pin the Codex CLI. The field that turns the
transport off is `supports_websockets`, which Codex 0.153.3 accepts. A later
Codex that ignores the field brings the 300-second wait back, and nothing in
Managoat reports it. The symptom is the gap between the `model` stream stage
and the first agent output. See
[openai/codex#13103](https://github.com/openai/codex/issues/13103).

## Related

- [About agents](../../concepts/agent.md)
- [`managoat acp`](../../integrations/acp.md)
- [Runtimes](index.md)
