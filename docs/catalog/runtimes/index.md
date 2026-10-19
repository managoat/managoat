# Runtimes

A runtime is what a sandbox runs. For three of the four it is a coding-agent
CLI. It is one field on an [Agent](../../concepts/agent.md). It decides which
provider's credential that agent needs, how skills land on disk, and where
Managoat writes the system prompt.

## The four

| Runtime | Provider | Transport |
|---|---|---|
| [claude](claude.md) | `anthropic` | ACP |
| [codex](codex.md) | `openai` | ACP |
| [gemini](gemini.md) | `google` | ACP, through `gemini --acp` |
| `acp` | None | ACP, through the command you name |

Each CLI runtime drives exactly one provider.

**opencode was removed in 2026-10.** An existing agent whose runtime is
`opencode` stays readable, but its conversations refuse to start until you
change its runtime to one of the four above.

## How to choose

**Choose the runtime whose provider you hold a key for.** That constraint
decides it most of the time. Inference credentials belong to one user, who
enters them in the app, and Managoat can export keys for exactly three
providers. Read
[Services Managoat uses](../../integrations/index.md).

**Choose `acp` to run a program instead of a model.** The agent names a
command in `runtime_command`, Managoat launches it inside the sandbox, and it
speaks the protocol back. There is no model, no inference credential and no
adapter to install. A deterministic operation that wants a warm machine, a
vault and a thread is what this is for. Read
[Running a program as an agent](#running-a-program-as-an-agent).

**Every runtime speaks ACP.** Gemini was the last CLI onto it, and it joined
on 2026-08-22. So editor integration, the permission flow and the shared block
format reach every runtime. The choice is about the provider and the program
rather than about the transport.

## Running a program as an agent

The `acp` runtime takes one extra field. Set it in a manifest you send with
`managoat apply`, or on `POST /api/agents`.

```yaml
apiVersion: managoat/v1
kind: Agent
metadata:
  name: converger
spec:
  runtime: acp
  runtime_command: exec chant acp --env prod
  environment: chant-toolchain
```

Five things follow from that.

- **The command is a shell line.** Managoat runs it inside the sandbox with
  the login shell, so the sandbox's own `PATH` resolves it and
  `cd /srv/app && exec ./bin/agent acp` is a legal value. Write `exec` before
  the program. Without it the shell stays as the parent, and an interrupt
  stops the shell and can leave the program running on the sandbox.
- **Nothing may print on stdout before the program starts.** The login shell
  reads your profiles first. A profile that writes a banner puts those bytes
  in front of the first protocol message, and the turn fails on a line the
  client cannot read. Send that output to stderr, or guard it on an
  interactive shell.
- **You install the program.** Name it in the environment's packages, or in
  the environment's setup script. Managoat installs no adapter for this
  runtime.
- **`model` is optional, and it does nothing.** Managoat resolves no inference
  credential, so a turn runs on an account that holds no API key at all.
- **`runtime_command` is a 422 on each other runtime.** Those resolve their
  own executable from a pinned table, and a command there would never run.
- **Everything else is unchanged.** Skills mount, MCP servers reach the
  session, `session/cancel` reaches the process on an interrupt, and the
  permission policy holds for each `session/request_permission` that arrives.

The field is a free string rather than an entry in a catalog. It runs inside
the sandbox, under the same isolation as an environment's setup script, so a
catalog would restrict a self-hoster and protect nobody.

There is no token count to record for a turn on this runtime, so `usage` on
the turn is null.

## The rule that catches people

Managoat stores `model` as `provider/model-id`. **It validates the provider
half, and it does not validate the model id.**

The provider must match the runtime. Managoat rejects a mismatch when you save
the agent. It holds no credential for the wrong provider, and the sandbox
would start with no inference key at all.

Managoat passes the model id to the CLI unchanged. A model that ships after
your Managoat version still works, and a typo reaches the CLI and fails there.

## Suggested models

Managoat offers these as suggestions. They are not an allowlist.

| Provider | Suggested |
|---|---|
| `anthropic` | `claude-fable-5-1`, `claude-opus-5-5`, `claude-opus-5`, `claude-sonnet-5`, `claude-haiku-4-5` |
| `openai` | `gpt-6-astra` |
| `google` | `gemini-3.1-pro-preview`, `gemini-3.7-flash` |

`GET /api/catalog` returns this list for each runtime. A client can then
render the current set, and it does not hard-code one.

## Where skills and prompts land

Every conversation has a config home of its own on its sandbox,
`/home/sprite/.managoat/c/<conversation id>`. The runtime keeps its
configuration there: the skills, the system prompt, the MCP servers, its
session store and its credential files. Managoat points the runtime at it
with one environment variable, which the agent's process carries. Two
conversations on one machine therefore share no runtime state. The shared
`~/.claude`, `~/.codex` and `~/.gemini` of the image are not read, so a
setup script that writes into one of them no longer reaches the agent. A
setup script writes into the runtime template instead, which each new config
home starts as a copy of: read
[Configure the runtimes from the setup](../../concepts/workspaces.md#configure-the-runtimes-from-the-setup).

Each runtime has its own layout under that home. That is why one skill list
produces different paths. Below, `<home>` is the config home.

| Runtime | Variable | Skills root | System prompt |
|---|---|---|---|
| `claude` | `CLAUDE_CONFIG_DIR` | `<home>/skills` | `<home>/CLAUDE.md` |
| `codex` | `CODEX_HOME` | `<home>/skills` | `<home>/AGENTS.md` |
| `gemini` | `GEMINI_CLI_HOME` | `<home>/.gemini/skills` | `<home>/.gemini/GEMINI.md` |
| `acp` | `MANAGOAT_SKILLS_DIR` names the skills root | `<home>/skills` | None |

The `acp` runtime has no CLI of its own, so it borrows claude-code's layout
for skills and gets the path as `MANAGOAT_SKILLS_DIR` in its environment. It
reads no system prompt file, because the command owns its own configuration.

Ending a conversation removes its config home. A conversation started before
config homes existed keeps the shared directory its runtime used then
(`/home/sprite/.claude`, `/home/sprite/.codex`, and `/tmp` for gemini) for
the rest of its life, where its session already is.

The agent runs in its conversation's working directory: the `cwd` it was
launched with, or the runtime's default, `/home/sprite` for `claude`, `codex`
and `acp` and `/tmp/gemini-workspace` for `gemini`. Read
[Choose the working directory](../../api.md#choose-the-working-directory).

## Related

- [About agents](../../concepts/agent.md), where you set `runtime`.
- [Skills](../skills/index.md).
- [`managoat acp`](../../integrations/acp.md), the adapter that drives each of
  them from an editor or a chat surface.
