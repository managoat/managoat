# About agents

This page explains what an Agent is, and which of its fields carry a decision
and not a setting. For each field, read the
[API reference](../api.md).

## What an agent is

An Agent is a named configuration for a coding agent that you can run again
and again. It is config, and not a process. Nothing runs until a
[Conversation](conversation.md) runs it.

An Agent carries these choices.

- **`model`**, as `provider/model-id`. An example is
  `anthropic/claude-sonnet-5`.
- **`runtime`**, one of `claude`, `codex`, `gemini` or `acp`.
- **`environment`**, an optional [Environment](environment.md) to start from.
- **`system`** and **`description`**, the system prompt and a summary that a
  person reads.
- **`skills`**, either inline or from GitHub.
- **`mcp_servers`**, the MCP server definitions, with `${VAR}` substitution in
  their env.
- **`metadata`**, a free-form map for your own records.
- **`runtime_command`**, the command that the `acp` runtime launches. It is
  null on each other runtime.

## Why it exists

An Agent is the thing you name and hand to somebody else.

Without it, each run would carry its own model choice, prompt and tool
configuration. Two people would ask the same agent for the same thing and get
different behavior. The Agent is the unit that makes a run repeatable.

## Why Managoat checks the provider and not the model id

This asymmetry surprises people, and it is deliberate.

The provider must match the runtime. Use `anthropic` for `claude`, `openai`
for `codex`, and `google` for `gemini`. The `acp` runtime takes none. It
runs a program rather than a model.

Managoat rejects a provider outside that set at write time. It holds no
credential for such a provider. A sandbox from that config would start with no
inference key at all. It would fail on the first turn, and the error would
point nowhere useful. The write-time rejection turns an unclear runtime
failure into a clear form error.

Managoat does not check the model id against a list. It suggests current
models, and passes what you type to the runtime's CLI unchanged,
so a model that ships after your Managoat version still works.

To validate the id, Managoat would have to ship a list. That list would go
stale between releases, and a stale allowlist costs more than a typo does.

## How the system prompt reaches the machine

Managoat writes the system prompt into the runtime's user-level instructions
file, in the conversation's own config home on the sandbox,
`~/.managoat/c/<conversation id>` (read
[Where skills and prompts land](../catalog/runtimes/index.md#where-skills-and-prompts-land)).
It writes it at provision, and again at each reattach.

| Runtime | File |
|---|---|
| `claude` | `~/.managoat/c/<id>/CLAUDE.md` |
| `codex` | `~/.managoat/c/<id>/AGENTS.md` |
| `gemini` | `~/.managoat/c/<id>/.gemini/GEMINI.md` |

The `acp` runtime has no such file, and Managoat writes none. The command owns
its own configuration.

Managoat rewrites the file on reattach. An edit to an Agent's system prompt
therefore reaches a sandbox that already exists, the next time that sandbox
wakes. It does not reach a turn that is already in flight.

## Skills and MCP servers

Each `skills` entry is inline or it comes from GitHub. An inline entry is
`{name, content}`, and Managoat writes a full `SKILL.md` into the sandbox. A
GitHub entry is `{source: "owner/repo"}`, and Managoat fetches the repository
and copies its skills in.

Each sandbox also gets the **`managoat`** skill, whatever the Agent asks for.
It gives the agent Managoat's own API, so the agent can start
sub-conversations.

An `mcp_servers` entry takes `${VAR}` substitution in its `env`. Managoat
resolves the reference from the merged environment and vault secrets at spawn
time.

```yaml
apiVersion: managoat/v1
kind: Agent
metadata:
  name: researcher
spec:
  model: anthropic/claude-sonnet-5
  runtime: claude
  environment: python-data-env
  skills:
    - source: anthropics/skills
      name: brainstorming
  mcp_servers:
    github:
      command: npx
      args: ["-y", "@modelcontextprotocol/server-github"]
      env:
        GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PAT}"
```

`${GITHUB_PAT}` resolves from the merged environment and vault secrets. Read
[substitution](../api.md).

Substitution applies to the whole entry, and not to `env` alone. A header, a
URL or an argument takes a reference too.

Write `$$` for a literal `$`. Use it when the value must reach the runtime
unresolved. Managoat turns `"Bearer $${MANAGOAT_TOKEN}"` into
`"Bearer ${MANAGOAT_TOKEN}"`, and the runtime then reads `MANAGOAT_TOKEN` from
the sandbox environment. Only Claude expands a reference in an MCP header,
so to send a server the conversation's own key on every runtime, give the
entry `auth: conversation` instead. Read
[Your application's own server](../catalog/mcp-servers/index.md#your-applications-own-server).
Managoat resolves each reference one time, and does not scan the result
again.

The runtime receives one configuration. Managoat resolves it at spawn time,
and the project file in the sandbox and the agent session both carry the same
document.

## What an agent is not

**Not a process that runs.** An Agent that nobody has run has no sandbox, no
memory and no cost.

**Not a hard scope.** `allowed_environment_ids` and `allowed_vault_ids` bound
which environments and vaults a launch can name. They are the Agent's own
allowlists, and not a tenancy boundary. Managoat enforces tenancy separately,
on each query.

**Not the ACP sense of "agent".** In the Agent Client Protocol, "agent" means
the process that an editor spawns. Read
[`managoat acp`](../integrations/acp.md).

## Config history

Managoat writes a version each time an agent's config changes. Each version
holds the config as it stood. Read them with `GET /api/agents/{id}/versions`,
and one with `GET /api/agents/{id}/versions/{version}`.

Deleting an environment or vault also writes a version for each agent whose
configuration changes. The deleted environment stops being the default, and
the deleted resource leaves the agent's allowlist. An emptied allowlist stays
empty; it does not become unrestricted. Older versions keep their original
configuration.

Versions are read-only, and Managoat never rewrites history. There is no
rollback command. To go back to an old version, read it with
`GET /api/agents/{id}/versions/{version}` and write its `config` to the agent
again, as the body of `PUT /api/agents/{id}` or in a manifest. That edit
becomes the newest version, and Managoat checks it like any other, so a
config that names removed infrastructure is refused. The update is a merge:
a field that an old version does not record keeps its current value.

Each conversation records the version it launched under. Its inference source
also has a durable binding, including the selected model and runtime. A later
agent edit or a replaced key does not silently replace that source on wake or
resume. A conversation also keeps a copy of the agent's `session_config` from
its launch, so an edit to the agent's reasoning effort or fast mode reaches
new conversations only. The agent is the only place to set them: a
conversation and a prompt can't. See [inference credentials](secrets.md#inference-credentials) for how
replacement and deletion affect an existing conversation.

## Where to go next

- [About conversations](conversation.md), which run an Agent.
- [About environments](environment.md), which an Agent names.
- [Runtimes](../catalog/runtimes/index.md), compared.
- [Skills](../catalog/skills/index.md), and the two that each sandbox gets.
- [Glossary](../reference/glossary.md), for the three senses of "agent".
