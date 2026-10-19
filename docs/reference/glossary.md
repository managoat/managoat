# Glossary

Here are the terms Managoat uses, and the six that carry more than one
meaning. Where a word has more than one sense, this page lists the senses and
names the one the docs use.

## The overloaded words

### Agent

Three senses. The docs mean the first.

1. **The primitive.** A named configuration that you can run again and again.
   Read [About agents](../concepts/agent.md).
2. **The coding agent.** The process in the sandbox, which is Claude Code,
   Codex or Gemini CLI. The docs call this the **runtime**.
3. **The ACP role.** In the Agent Client Protocol, the process an editor
   spawns. The docs call this `managoat acp`. Read
   [`managoat acp`](../integrations/acp.md).

### Environment

Three senses. The docs mean the first.

1. **The primitive.** Read
   [About environments](../concepts/environment.md).
2. **Environment variables.** The values in a process. The docs always write
   "environment variables" in full.
3. **A deployment tier.** Dev, staging, production. The docs say
   **deployment** for this, and never "environment".

### Managoat

Three senses. The format tells you which.

1. **Managoat**, unstyled, is the product.
2. **`managoat`**, in code font, is the CLI binary.
3. **the `managoat` skill** is the skill that each sandbox gets, which gives
   an agent Managoat's own API. Always write the word "skill" with it.

### Vault

Two senses, and they are close to opposite. The docs mean the first.

1. **The primitive.** A small, static override layer for one run, which wins
   on a key collision. Read [About vaults](../concepts/vault.md).
2. **HashiCorp Vault.** A central server that issues dynamic leased
   credentials. Nothing about it relates to Managoat's Vault, except the shape
   of the encryption. The Vault page sets the collision out.

### Workspace

Two senses. The docs mean the first.

1. **The Managoat object.** A machine you create from an environment and
   keep, which many conversations run on. Read
   [About workspaces](../concepts/workspaces.md).
2. **A runtime's working directory.** Claude Code and Codex call the
   directory an agent runs in its workspace, as in Codex's `workspace-write`
   mode, and gemini's default is `/tmp/gemini-workspace`. The docs say
   **working directory**, or `cwd`.

### Computer

Some apps use this word for the machine an agent works on. The docs say
**sandbox**.

## The rest

| Term | Means |
|---|---|
| **ACP** | Agent Client Protocol. How an editor or a chat surface drives Managoat. Read [`managoat acp`](../integrations/acp.md). |
| **AG-UI** | The protocol OpenBot and other coworker hosts speak. Managoat spoke it until ADR 0057 retired the endpoint. |
| **Connection** | A user's OAuth grant to one remote MCP server. An Agent names it in `mcp_servers` under `auth`; the broker carries its token. Read [Connect Linear to an agent](../guides/connect-an-mcp-server.md). |
| **Conversation** | One run of an Agent in a sandbox. Read [About conversations](../concepts/conversation.md). |
| **DEK** | Data encryption key. Managoat derives one for each tenant from `MASTER_SECRETS_KEY`, then encrypts that tenant's secrets with it. |
| **Inference credentials** | A user's own model provider keys, which they enter in the app. An operator never sets them. Read [Services Managoat uses](../integrations/index.md). |
| **Log event** | One entry in a conversation's stream. It arrives over SSE, and `?blocks=true` parses it for you. |
| **MCP server** | A Model Context Protocol server that an Agent gives its runtime. You declare it in `mcp_servers`. |
| **Reaper** | The background sweep that suspends an idle sandbox, and destroys one that passed a configured ceiling. |
| **Runtime** | What a sandbox runs. One of `claude`, `codex`, `gemini`, which are coding-agent CLIs, or `acp`, which is a command the Agent names. |
| **Config home** | A conversation's own runtime configuration directory on its sandbox, `~/.managoat/c/<conversation id>`: its skills, instructions, MCP configuration and session. |
| **Implicit workspace** | The workspace a conversation launched without `workspace_id` gets for its own sandbox, ended with it. Listed with `GET /api/workspaces?implicit=true`. |
| **Sandbox** | The isolated machine that a Conversation runs in. Each Conversation has its own, unless it was launched into a workspace. Managoat provisions it at launch and reclaims it on the lifetime rules. `GET /api/sandboxes` lists them. |
| **Sandbox provider** | A backend that Managoat provisions sandboxes on. Sprites or E2B. Read [the sandbox contract](../integrations/sandbox-contract.md). |
| **Skill** | A `SKILL.md` that Managoat writes into the sandbox, inline or from GitHub. |
| **Sprite** | One sandbox on the Sprites provider. Not a Managoat concept. Read [Sprites](../integrations/sprites.md). |
| **Substitution** | `${VAR}` interpolation in an Agent config, resolved from the merged secrets at spawn. |
| **Suspend** | To scale a sandbox to zero and keep its disk, so the agent's memory survives. |
| **Turn** | One prompt, and the work that comes after it, in a Conversation. |
| **Workspace** | A machine you create from an environment and keep, which many conversations share, each in its own working directory. One trust boundary. Read [About workspaces](../concepts/workspaces.md). |

## Three things that sound like primitives and are not

A **long-lived agent** is not an object. It is a Conversation that you keep,
by its id or by a `channel_id` of your own.

A **sandbox** is not an object you create. Managoat provisions it when a
Conversation starts, one for each Conversation. You can list them and read
one. Read
[Sandboxes](../api.md#sandboxes) and
[About conversations](../concepts/conversation.md).

A **workspace** is a machine you create and keep, and is the one sandbox you
name. It configures nothing of its own: its environment and vault are two of
the primitives, and it only decides where conversations run. Read
[About workspaces](../concepts/workspaces.md).
