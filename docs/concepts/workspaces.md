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

If the instance stops offering that provider, because its credentials were
removed, a prompt that has to wake or rebuild the workspace's machine does
not run. Nothing is woken, and nothing is rebuilt on another provider. The
`wake` stage fails with `sandbox_provider_disabled`, and its `advice` says
what to do: set the provider's credentials again, or create a workspace on
another provider.

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
  conversations never overwrite each other's settings. It starts as a copy
  of the [runtime template](#configure-the-runtimes-from-the-setup) the
  setup script filled.
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
variables. To configure the runtimes the agents will use, the setup script
writes into the runtime template instead, described next.

You can launch conversations into a workspace before it is ready. Their first
prompt waits for the setup. A prompt into a conversation in a `failed`
workspace starts the setup again, with the environment as it is then, and
fails with it if it fails again; two
prompts that arrive together start it once.

### Configure the runtimes from the setup

A setup script runs before any conversation exists, so there is no config
home for it to write into. It writes into the **runtime template** instead.
The script runs with `MANAGOAT_RUNTIME_TEMPLATE` set to
`/home/sprite/.managoat/template`, where `claude/`, `codex/` and `gemini/`
are made, empty, just before it starts. Each one holds what `~/.claude`,
`~/.codex` or `~/.gemini` would: a Claude `settings.json` with hooks and the
scripts they run, a codex `config.toml`, a gemini `settings.json`.
[Run several agents on one machine](../guides/agents-in-one-workspace.md#give-the-runtimes-their-settings)
shows a setup script that writes a Claude hook and a codex `config.toml`.

When Managoat makes a conversation's config home, it copies the template
directory for that conversation's runtime into it, then writes its own files
on top. The same holds for a conversation without a workspace whose
environment has a setup script.

- **It is copied once, when the home is made.** That is a conversation's
  first attach to the workspace's machine, or, without a workspace, its own
  provision, right after the setup script. A wake does not copy it again. A
  later change to the template, by hand or by an agent, reaches only
  conversations whose homes are made after it.
- **Managoat's own files win.** These are the agent's instructions file
  (when the agent has a system prompt), its skills (a template skill with the
  same name is replaced, directory and all), the codex `auth.json` and the
  runtime's session. Everything else in the template is copied as it is.
- **Some JSON files are merged rather than replaced.** Claude's
  `settings.json` and `.claude.json`, and gemini's `settings.json`, are files
  Managoat writes keys into. For these, the template's file is the base and
  Managoat sets its keys over it, at the top level: `showThinkingSummaries` in
  Claude's `settings.json`, and `mcpServers` in the other two. A template's
  `hooks`, `permissions` or `env` survive, then and on every later wake.
- **`mcpServers` is replaced whole.** The MCP servers that run are the
  agent's own. An agent that drops a server drops it on its next wake. Each
  server's credentials take the agent's path, through `${VAR}` references and
  the broker. Put MCP servers on the [agent](agent.md), not in the template.
  Managoat writes no codex `config.toml`, so a template's `config.toml` is
  used as it is, and any `[mcp_servers]` it names start beside the agent's.
- **Files are copied byte for byte, paths in them included.** A file that
  names an absolute path under the template, such as the records of a Claude
  plugin installed into the template, still points at the template. What it
  points at is shared, so a later change there reaches every conversation.
  Name `$CLAUDE_CONFIG_DIR` (or `$CODEX_HOME`) in a hook command, not the
  template's path.
- **Only regular files and directories are copied, with their modes**, so a
  hook script stays executable. A symlink is skipped, not followed, and so
  is anything that is not a file. A template, or a runtime's directory in it,
  that is itself a symlink is not used.
- **A template that cannot be copied fails the conversation.** A merged file
  that is not a JSON object, such as a `settings.json` with a syntax error,
  fails it with `runtime_template` and `not_a_json_object` naming the file. A
  file or directory the sandbox user cannot read, such as one written with
  `sudo`, fails it with `runtime_template` and `unreadable` naming the path.
  A conversation without a workspace then stays failed: fix the setup script
  and start a new one. A ready workspace does not run its setup again, so
  every conversation launched into it fails the same way until you fix the
  file on its disk or create the workspace again.
- **The template configures the runtime, and Managoat does not police it.**
  A Claude `settings.json` can pre-approve tools (`permissions`), set
  `env`, or run hooks, and a codex `config.toml` can change its sandbox and
  approval settings. A tool a runtime allows by itself never reaches the
  conversation's permission policy. That is what a shared `~/.claude` could
  do before config homes, and it is the setup script's to decide.
- **It is not a place for secrets.** The template is on the machine's disk
  like everything else. Every conversation's home gets a copy, and the
  [disk reads](#reading-its-disk) can read it, redacted like any other file.
  Give an agent a secret through the environment or the vault, as an
  environment variable.

A rebuild after a lost machine runs the setup again on the new machine, which
fills a new template, before any conversation moves there. Each conversation
then gets a new config home from that template.

A conversation started before config homes existed keeps its shared
directory and gets no template. So does one whose config home was already
there when the template arrived. The `acp` runtime has no template directory.

### Conversations come and go

Ending a conversation in a workspace, by terminating or deleting it, stops its
adapter and removes its config home. Its transcript is kept. The machine stays,
with everything else on its disk, for the next conversation. When the machine
is parked at that moment, its config home is removed when the next prompt
wakes the machine, so a parked machine is not woken only to delete a directory.

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
A second rebuild while one is building is `409 rebuild_in_progress`. If the
workspace's sandbox provider has been disabled since you created it, the
rebuild is `422 sandbox_provider_disabled` and nothing is touched: set the
provider's credentials, or create a workspace on another provider. An
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
  conversations. Write into `$MANAGOAT_RUNTIME_TEMPLATE/claude`, `/codex` or
  `/gemini` instead: see
  [Configure the runtimes from the setup](#configure-the-runtimes-from-the-setup).
  That works for a workspace's setup and a conversation's own alike.
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
