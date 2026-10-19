# About workspaces

This page explains what a workspace is, how its machine lives and ends, and
what it costs you in isolation. To put three agents on one machine, follow
[Run several agents on one machine](../guides/agents-in-one-workspace.md). For
the fields and the refusals, read the [Workspaces section](../api.md#workspaces)
of the API reference.

## What a workspace is

A workspace is a sandbox you keep. You create it from an
[environment](environment.md) and, if you want one, a [vault](vault.md).
Managoat sets its machine up at once: the environment's packages, its
repositories and its setup script, with the vault's secrets winning over the
environment's. Then you launch conversations into it, as many as you like,
with any agent and any runtime, each in a folder of its own.

It is the way a person works on their own computer: one machine, set up once,
and a new terminal for each tool. Without a workspace, two agents on one
checkout means two machines and two clones.

A workspace has a name, an environment, an optional vault and a sandbox
provider. All four are fixed when you create it: to point it at another
environment, vault or provider, create another workspace. What is fixed is
which environment and vault, not what they hold. A setup reads them as they
are at that moment, so editing the environment changes what the next setup
runs: a retry after a failure, a rebuild after a loss, or a rebuild you ask
for. An environment several workspaces share changes all of their next
rebuilds. A workspace belongs to the account that created it and is
never shared with another account.

An edit does not change a machine that is already built, so a workspace tells
you when its machine is behind. It reports `stale: true` and `changed_fields`,
the names of the environment's fields that changed since the machine was
built: `repositories`, `packages`, `setup_script`, `setup_timeout_seconds`,
`env_vars`, `networking_type` or `networking_config`. Only names are given,
never values. Editing the environment's name, its metadata or a secret does
not make a workspace stale, and secrets reach the running machine through the
broker anyway. Each edit that moves a ready workspace's environment is also a
`workspace.status` event, so a client can show "rebuild needed" as it
happens.

`stale` says what the machine was built from, which is not everything a
conversation on it runs with. `repositories`, `packages` and `setup_script`
exist only as what the setup did to the disk, so an edit to them reaches the
machine only through a rebuild. `env_vars` and the networking fields are also
read again by each conversation as it starts: a conversation launched or
woken after the edit gets the new variables in its process and the new
network allowlist, while the machine's env file, and the conversations
already running, keep the old ones until a rebuild. `setup_timeout_seconds`
matters only to the next setup.

It is not a fifth primitive. The four primitives are the configuration and
the run; a workspace is the machine a run happens on, made something you can
name. Every conversation already has one. A conversation launched without a
workspace gets an **implicit** workspace of its own, made with its sandbox and
ended with it, which is the one-machine-per-conversation behaviour Managoat
has always had. `GET /api/workspaces` lists only the ones you created, and
`?implicit=true` adds the implicit ones.

## What each conversation keeps to itself

A conversation in a workspace takes the agent's runtime, model, skills, MCP
servers, system prompt and permission policy, as any conversation does. The
environment and vault come from the workspace, so a launch that names a
different one is refused with `422 workspace_fixes_environment`. The agent's
`allowed_environment_ids` and `allowed_vault_ids` still apply, to the
workspace's environment and vault. The agent's `sandbox_provider` is not read:
the workspace's provider wins.

Each conversation has three things of its own on the shared machine:

- **A working directory**, the `cwd` you launch it with: `/home/sprite`, a
  repository's `mount_path` in the workspace's environment, or a directory
  under either, created if missing. Without one, the runtime's default
  applies, which is `/home/sprite` for claude and codex and
  `/tmp/gemini-workspace` for gemini. Two conversations may share a folder.
- **A config home**, `~/.managoat/c/<conversation id>`. The runtime is
  pointed at it with `CLAUDE_CONFIG_DIR`, `CODEX_HOME` or `GEMINI_CLI_HOME`.
  The agent's skills, its instructions file, its MCP configuration, the
  runtime's session and its inference credential live there, so two
  conversations never overwrite each other's settings.
- **An adapter process**, the runtime itself, started for that conversation.

So any mix works on one machine: claude, codex and gemini side by side, or two
claude conversations of the same agent in the same folder. Two costs come with
it. Each live conversation is a resident process, so a busy workspace uses
more memory than one conversation did. And the Claude CLI makes its first-start
policy fetch, about 1.2 seconds, in every fresh config home.

## One trust boundary

!!! warning "Conversations in one workspace can read and influence each other"

    A workspace is one trust boundary, like a laptop. Every process on it runs
    as the same user on the same disk. A process in one conversation can read
    another conversation's files, its config home, its process environment and
    its `MANAGOAT_TOKEN`, and it can plant hooks or a `CLAUDE.md` that another
    conversation's agent then runs or obeys. Separate config homes stop
    accidents, not a hostile process.

    **For isolation, launch without a workspace.** Each conversation then gets
    a sandbox of its own, as it always has.

Three rules follow from that boundary:

- **A sandbox key cannot use workspaces.** The `MANAGOAT_TOKEN` a sandbox
  holds is refused on every workspace route, and a launch it makes that names
  a workspace is `403 insufficient_scope` with `required_scope: "full"`. So a
  conversation an agent starts from inside a workspace always gets a sandbox
  of its own, and fan-out stays one machine each. Inside a workspace, though,
  what one sandbox key can reach is in effect what every conversation's key
  there can reach, because each can read the others'.
- **`sandbox_api_access: "none"` needs a machine of its own.** It is a claim
  that the conversation holds no Managoat credential, and on a shared disk the
  others' are readable. A launch with it and a workspace is
  `422 invalid_sandbox_api_access`.
- **The broker still holds the real credentials.** A bound secret reaches the
  sandbox as a placeholder, as everywhere
  ([Where a secret comes from](secrets.md)). But each conversation's proxy
  session token is readable by the others.

## How the machine lives

### Set up on create

Creating a workspace answers at once with `status: "provisioning"` and builds
the machine with no conversation involved. The setup runs under the egress
broker's network floor, like any sandbox. The status then becomes `ready`, or
`failed` with an `error` that names the failing step and the end of what it
printed, redacted. Each change is a `workspace.status` event on the account's
event stream.

The setup is not a conversation, so it has no transcript and no runtime: it
runs with no `MANAGOAT_TOKEN`, no conversation id and no config home
variables. A setup script that writes runtime configuration therefore reaches
no agent. Put that configuration on the [agent](agent.md) instead.

You can launch conversations into a workspace before it is ready. Their first
prompt waits for the setup. A prompt into a conversation in a `failed`
workspace starts the setup again, with the environment as it is then, and
fails with it if it fails again; two
prompts that arrive together start it once.

### Conversations come and go

Ending a conversation in a workspace, by terminating or deleting it, stops its
adapter and removes its config home. Its transcript is kept. The machine stays,
with everything else on its disk, for the next conversation.

### Idle parks, and the next prompt wakes

A workspace's machine parks when no conversation in it has a running turn and
it has been idle for `SANDBOX_IDLE_TIMEOUT_MINUTES` (60 by default), counted
from the last turn end of any of its conversations. A ready workspace with no
conversations is idle from the moment it is ready, so a workspace you create
and never use costs a setup and then a parked machine.

A prompt into any of its conversations wakes it. The wake is lazy per
conversation: it loads only that conversation's runtime session, and the
others reattach when they are next prompted.

### The ceiling parks, and nothing caps it

`SANDBOX_MAX_LIFETIME_HOURS` is off by default. When an operator sets it, it
treats the two kinds of machine differently:

| Machine | At the ceiling |
|---|---|
| A conversation's own (implicit workspace) | Destroyed, with its disk. The next prompt starts a fresh one. |
| A workspace's (explicit) | **Parked.** Every running turn on it is interrupted first, its transcript kept, and the turn ends `interrupted` with `reason: "machine_parked"`. The disk and the runtime sessions are kept, and the next prompt wakes it. The clock restarts from that wake. |

So **a workspace's machine has no hard lifetime.** It lives until you delete
the workspace or the provider loses the machine. Managoat does not cap how
many workspaces an account keeps, and it does not age a parked machine out.
The fleet ceiling counts only running machines, not parked ones. What bounds
them is the workspaces people keep and the provider's own storage billing and
machine limits. Delete the workspaces you are done with, and if you run the
instance, watch the provider's storage. Read
[Sandbox lifetime and cost](../guides/operate/sandbox-lifetime.md).

### A lost machine is rebuilt on the next prompt

When the provider loses the machine, or a resume fails for good, the
workspace stays and so does every conversation in it. Each keeps its
transcript and loses its runtime session. The next prompt into any of them
sets the workspace back to `provisioning` and builds a new machine from the
environment as it is now, and every conversation in the workspace moves to
it. A turn still running in another of them when that happens is ended,
`interrupted` with `reason: "machine_destroyed"`. Nothing is
replayed, and nothing on the old disk survives, so the agents start without
their memory and without their work in progress. Two prompts that arrive
together rebuild it once.

The machine can go while a conversation's process is still up between
turns. The next prompt to that conversation then finds it gone, and the same
rebuild happens: the prompt runs on the new machine, under the turn number it
was given. Managoat counts a machine as lost only when the provider says it
does not exist. Any other provider error fails that one turn and leaves the
machine alone. A conversation gets one such automatic rebuild in ten minutes.
If the new machine is lost again inside that time, the turn fails, and the
next prompt rebuilds it.

A workspace's `sandbox_id` names its current machine, and changes on a
rebuild. Address the workspace, not the sandbox.

### Rebuild on purpose

To apply an edited environment, rebuild the workspace
(`POST /api/workspaces/{id}/rebuild`, `managoat workspace rebuild`). It is
the lost-machine rebuild above, done when you ask and at once.

!!! warning "A rebuild wipes the disk"

    The machine is destroyed with everything on it: uncommitted work,
    unpushed commits, build output. Save what you need first, for example
    with the workspace's `diff` read, while the machine is ready.

Every conversation keeps its transcript and stays in the workspace, and its
agent starts a fresh session on its next prompt. The workspace goes
`provisioning`, then `ready` or `failed`, and `stale` clears. A running turn
refuses the rebuild with `409 turns_running`, and so does a prompt accepted
but not yet started, unless you pass
`interrupt: true`, which interrupts those turns and keeps their transcripts.
A second rebuild while one is building is `409 rebuild_in_progress`. An
implicit workspace cannot be rebuilt: it is a conversation's own sandbox.

### Delete ends everything

Deleting a workspace terminates every live conversation in it, keeping their
transcripts, and destroys the machine with its disk. It is not refused while
conversations are running. Deleting your account deletes your workspaces.

While a workspace exists, the environment and vault it was created from cannot
be deleted: that is `409 source_in_use_by_workspace`. Delete the workspace
first.

## Reading its disk

The four disk reads, `files`, `file`, `git-status` and `diff`, are served by
workspace at `/api/workspaces/{id}/…`. They read the workspace's current
machine with the same rules as the [sandbox reads](../api.md#files-git-status-and-git-diff).
On a workspace's machine a relative path resolves from `/home/sprite`, and a
path may lie under `/home/sprite`, the working directory of any live
conversation in the workspace, or a repository mount of the workspace's
environment. The output is redacted with the workspace's
environment and vault and every live conversation's credentials. A read never
wakes a parked machine: it answers `409 sandbox_not_ready` with the machine's
status, as it does for one being set up or lost.

## After upgrading: configuration in the image's home

Since config homes arrived (#2988), a conversation no longer reads the image's
own `~/.claude`, `~/.codex` or `~/.gemini`. That affects every conversation,
in a workspace or not:

- A setup script that wrote into those directories no longer reaches new
  conversations. A conversation's own setup runs with `$CLAUDE_CONFIG_DIR`,
  `$CODEX_HOME` and `$GEMINI_CLI_HOME` set, so write there instead. A
  workspace's setup has no conversation and no config home, so give that
  configuration to the agent.
- The Sprites image's bundled `sprite` skills in `~/.claude/skills` and
  `~/.codex/skills` are not seen by new conversations.
- A conversation started before the upgrade keeps the shared directory its
  runtime used, and is not moved.

## Where to go next

- [Run several agents on one machine](../guides/agents-in-one-workspace.md),
  the task, step by step.
- [About sandboxes](sandboxes.md), the machine under every workspace.
- [About conversations](conversation.md), what runs in one.
- The [Workspaces section](../api.md#workspaces) of the API reference.
