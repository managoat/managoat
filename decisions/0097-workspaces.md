---
type: ADR
title: "A workspace owns the sandbox, and conversations run in it"
description: "Step 2 built, the rest not (schema and implicit workspaces, unread): a workspace (user, environment, vault, fixed at create) owns the sandbox through one owner and lease that survive rebuilds; an explicit one is provisioned on create, carries a status, and parks at the max-lifetime ceiling; a conversation may launch into one of the caller's workspaces in any folder, with a config home and adapter process of its own, and a conversation that names none gets an implicit single-use workspace ended with it."
tags: [sandbox, lifecycle, conversations, product, api]
status: stable
adr: "0097"
adr_status: "Accepted"
date: 2026-10-18
---

# 0097 — A workspace owns the sandbox, and conversations run in it

**Status:** Accepted, 2026-10-18, by the maintainer, in review on #2984.
Step 2 of the Cost section's sequence is built: the `workspaces` table, and
an implicit workspace beside every live sandbox that has an owner, which
nothing reads yet. The rest, step 1 included, is not built; the Cost section
sets out the work and its order. It amends
[0073](0073-one-sandbox-per-conversation.md) and the binding layer of
[0058](0058-the-machine-has-one-owner.md), and touches
[0017](0017-suspend-idle-sandboxes.md), [0039](0039-sandbox-files-over-the-api.md),
[0045](0045-sandbox-api-access.md) and
[0096](0096-sandbox-key-confined-to-its-conversation-tree.md), as described
under Amendments.

## Context

Since [0073](0073-one-sandbox-per-conversation.md) every conversation owns a
sandbox, and the sandbox is destroyed when the conversation ends. That
removed the persistent home of [0023](0023-persistent-agent-sandbox.md) and,
with it, most of the lifecycle code: home lookup, the refcount that decided
whether a detach kept the machine, co-tenant follow and strand on a rebuilt
home, per-runtime turn capacity, the shared Codex auth binding, and the Codex
SQLite contention relaunch (#1910).

Clients keep asking for the thing a home half-gave them: a sandbox set up
once from an environment, then any agent (claude, codex, gemini) started on it
in whatever folder they choose, the way a person opens a new terminal on
their own machine and runs a CLI there. Today the only way to get two agents
on one checkout is to clone it twice.

What made homes expensive was not that several conversations shared a disk.
It was that the machine had no owner of its own: its identity was derived
from an agent (user, agent, environment, vault, runtime), so the machine was
found by lookup, retired when any of those moved, kept or dropped by a
refcount of whoever was on it, and shared one runtime config directory
between every conversation of a runtime. Each of those produced a rule of its
own (one agent per runtime, the Codex auth binding, the SQLite relaunch, the
skills record keyed by runtime).

The red-team review of shared machines (#2525, hardened in #2526) found that a
process on a shared machine can plant `~/.claude/settings.local.json` hooks
and a `CLAUDE.md` that later sessions there run or obey.

## Decision

### The primitive

A **workspace** is `{user_id, environment_id, vault_id}`, plus a name and the
sandbox provider, all fixed at create. It is a row the caller creates and
deletes by API, owned by the caller, and every query on it is scoped by
`user_id`. It cannot move to another environment, vault or provider, and it
is never shared between users.

The workspace owns the sandbox: it is provisioned from the workspace's
environment and vault, parked as [0017](0017-suspend-idle-sandboxes.md)
describes, and destroyed when the workspace is deleted. One owner process
and one lease per workspace drive all of it (see The owner). A workspace has at
most one non-terminal sandbox at a time, and over its life it may have a
succession of them (see Sandbox lost).

**Every sandbox has a workspace.** A conversation launched without a
`workspace_id` gets an **implicit** workspace, made in the same reservation
as its sandbox, with the environment and vault the launch resolved as it does
today, and destroyed with the conversation. So there is one lifecycle owner
everywhere, and today's behaviour is the implicit case. Implicit workspaces
are marked as such and are not listed by `GET /api/workspaces` unless asked
(`?implicit=true`).

### The workspace API

`POST /api/workspaces` (`environment_id`, `vault_id`, `name`, optional
`sandbox_provider`) creates an explicit workspace and starts provisioning
it at once: it answers `201` with `status: "provisioning"`. A workspace
carries a `status` of `provisioning`, `ready` or `failed`, with an `error`
when `failed` (redacted like the transcript), on `GET /api/workspaces` and
`GET /api/workspaces/:id`, beside its current sandbox's own status
(`ready`, `suspended`, or none after a loss). Each status change is a
`workspace.status` event on the account event stream. A create when the
fleet ceiling is full is refused with the launch's `503 fleet_full`.
`DELETE /api/workspaces/:id` deletes it (see Lifecycle). Create and delete
are audited in the context, with the caller, outside any transaction.

### Launching into a workspace

`POST /api/conversations` takes two new optional fields:

- `workspace_id`: one of the caller's workspaces. The conversation runs on
  its sandbox. The agent supplies the runtime, model, skills, MCP servers,
  instructions and permission policy; the environment and vault come from
  the workspace. A launch that also names an `environment_id` or `vault_id`
  different from the workspace's is refused with
  `422 workspace_fixes_environment`. The agent's
  `allowed_environment_ids` and vault allowlist still apply to the
  workspace's environment and vault, and the agent's `sandbox_provider` is
  not consulted: the workspace's provider wins. A workspace that is not the
  caller's is `404 not_found`. A launch into a workspace that is still
  `provisioning` is accepted, and its first prompt waits for `ready`.
- `cwd`: an absolute path the conversation's agent runs in, fixed for the
  conversation's life. Today `Fountain.RuntimeDispatch.cwd/1` fixes it per
  runtime; that stays the default. The path must lie under `/home/sprite`
  (for gemini, also under `/tmp`, where its default working directory is)
  and is created if missing. It is accepted with or without a workspace.

`sandbox_id` keeps its refusal, `422 sandbox_attach_unsupported`, with the
message pointing at `workspace_id`. A sandbox row is a
succession member of a workspace, not a handle a client should hold.

A sandbox key (`sprite` scope) may not name a `workspace_id` and may not
create, list or delete workspaces: `403 insufficient_scope`,
`required_scope: "full"`. A conversation started from a sandbox is a child
([0096](0096-sandbox-key-confined-to-its-conversation-tree.md)), and a child
gets a sandbox of its own as today; fan-out stays a sandbox each.

### A config home and adapter process per conversation

Each conversation on a workspace runs its own adapter process with its own
runtime config directory, under `~/.managoat/c/<conversation_id>/`:
`CLAUDE_CONFIG_DIR` for claude, `CODEX_HOME` for codex, and
`GEMINI_CLI_HOME` for gemini, which drops gemini's `HOME=/tmp`. gemini-cli
0.59.0, the version `Managoat.Runtimes.Gemini` pins, resolves its home
through `homedir()`, which returns `GEMINI_CLI_HOME` when it is set
([`packages/core/src/utils/paths.ts`](https://github.com/google-gemini/gemini-cli/blob/v0.59.0/packages/core/src/utils/paths.ts#L17-L28)),
and builds every user-level path (`settings.json`, `skills`, `tmp`, the
project registry) from it in `Storage.getGlobalGeminiDir()`
([`packages/core/src/config/storage.ts`](https://github.com/google-gemini/gemini-cli/blob/v0.59.0/packages/core/src/config/storage.ts#L54-L60));
its configuration reference documents the variable for "keeping CLI state
isolated". `HOME=/tmp` was set because the rename of
`~/.gemini/projects.json.tmp` fails across `/home/sprite`'s ACL boundary
(`Managoat.Runtimes.Layout`). Whether that failure follows the gemini config
home to `~/.managoat/c/<id>` is unmeasured; if it does, the gemini config
home lives under `/tmp/managoat/c/<id>` instead, still set through
`GEMINI_CLI_HOME`, and `HOME` stays the image's own. Skills, the agent's
instructions file, MCP configuration, the runtime session and the inference
credentials are written there, not under the shared `~/.claude` or
`~/.codex`. Claude's MCP servers move out of the project-scope
`<cwd>/.mcp.json` they are written to today, which two conversations in one
folder would overwrite, into the config home. The record of which skills are
on disk moves from the machine (`sandboxes.applied_skills`) to the
conversation. Implicit workspaces use the same layout, so there is one code
path.

That makes conversations on one machine independent at the runtime layer, so
the rules homes needed do not return: there is no Codex SQLite contention
(#1910) because no two Codex processes share a `CODEX_HOME`, no shared Codex
auth binding, no per-runtime skills root collision, and no "one agent per
runtime" rule. Two claude conversations of different agents, or of the same
agent, can run side by side in one folder.

Accepted cost: the Claude CLI pays its first-start policy fetch (about 1.2 s)
on every fresh config home, and every live conversation is a resident adapter
process.

### Lifecycle

- **Ending a conversation** (terminate, delete) stops its adapter process and
  removes its config home. The sandbox stays, unless the workspace
  is implicit, in which case the workspace and its sandbox are destroyed as
  today.
- **Deleting a workspace** terminates every live conversation on it
  (transcripts kept) and destroys the sandbox, through the workspace's owner
  (`Machines.Destroy`), with one `sandbox.destroyed` and one
  `workspace.deleted` audit event carrying the caller. It is not refused
  while conversations are live.
- **An explicit workspace is provisioned on create.** The workspace's owner
  runs the machine-level steps itself, with no conversation involved:
  create the machine, write the environment and vault, the broker CA and
  relay, packages, repositories and the setup script. It sets `ready` or
  `failed`. Every conversation then attaches its own steps (config home,
  instructions, skills, MCP configuration, adapter) to the running machine.
  A prompt into a `failed` workspace retries the provision; the prompt
  waits for it and fails with it if it fails again. Two prompts into one
  failed workspace retry it once; the second waits.
- **A rebuild after a sandbox loss is lazy**: nothing provisions until the
  next prompt in any of the workspace's conversations, which sets the
  workspace back to `provisioning` (see Sandbox lost). Two prompts into a
  workspace with no sandbox rebuild it once; the second waits, as two wakes
  resume once today.
- **An implicit workspace is unchanged**: its sandbox is provisioned with its
  conversation, as today, and its status follows that provision.
- A `ready` explicit workspace with no conversations is idle from the moment
  it is ready, so the reaper parks it on the same idle bound as any other
  (see Park). A workspace created and never used costs a provision and then
  a parked machine.
- **Park** happens when no conversation in the workspace has a running turn
  and the workspace has been idle for `SANDBOX_IDLE_TIMEOUT_MINUTES`, measured
  from the last turn end of any of its conversations. **Wake is lazy per
  conversation**: a prompt resumes the machine if it is parked and loads only
  that conversation's session (`session/load`); the others stay unattached
  until they are prompted. A workspace with a sandbox and no live
  conversation is parked by the reaper on the same idle bound.
- **Sandbox lost.** When the machine is gone (provider death or a failed
  resume), every conversation on the workspace keeps its transcript and has
  its runtime session cleared, the workspace stays, and the next prompt in
  any of them provisions a new sandbox from the workspace's environment. The
  agents lose their runtime memory and the disk's contents, as #649
  described; nothing is replayed.
- **The max-lifetime ceiling** (`SANDBOX_MAX_LIFETIME_HOURS`, off by default)
  splits by kind. On an implicit workspace it destroys the machine, as
  today. On an explicit workspace it **parks** the machine: the disk and the
  runtime sessions are kept, and the next prompt wakes it. 0017 destroys at
  the ceiling because it fires on a conversation that never stops being
  busy, with a detachable session still running, and a park would leave that
  exec burning unattended; so on an explicit workspace the ceiling first
  interrupts every running turn on it (each is cancelled and marked
  interrupted, its transcript kept), then parks. It does not wait for the
  turns to finish. The clock restarts from the wake (`last_resumed_at`), as
  0017 measures it.

  So **an explicit workspace's sandbox has no hard lifetime ceiling.** It
  lives until the workspace is deleted or the sandbox is lost. Nothing in
  Managoat bounds how many parked sandboxes accumulate: the fleet ceiling
  counts only compute and excludes `suspended` rows by design (0017), and
  there is no per-account cap ([0005](0005-platform-shared-sprites-token.md),
  2026-10-13). What bounds them is the number of workspaces callers create
  and keep, and the provider: its storage billing for a suspended machine
  and any account-level machine cap. Neither a per-account workspace cap nor
  a retention bound on parked sandboxes ships: Managoat is self-hosted, and
  the operator watches provider storage (see Consequences).
- **Account deletion** deletes the account's workspaces with their sandboxes.

### The owner

[0058](0058-the-machine-has-one-owner.md)'s owner is keyed by **workspace**:
one `Fountain.Machines.Machine` process per active workspace, registered in
`Fountain.MachineRegistry` under the workspace id, and one lease on the
`workspaces` row. `lease_epoch`, `lease_node`, `transition` and
`transition_reason` move from `sandboxes` to `workspaces`, and the
per-sandbox advisory lock becomes a per-workspace one. The owner survives a
rebuild: re-provisioning after a loss is the owner's own transition
(`provisioning` on the workspace row), which retires the old sandbox row and
inserts the next under one epoch, so no second owner ever claims the new
machine and no epoch belongs to only one sandbox. The `sandboxes` row stays
the record of one machine (provider name, status and its timestamps), and
the owner is still the only writer of its status, now as a compare-and-set
on the workspace's epoch.

Everything 0058 says about the lease carries over with "workspace" for
"sandbox": `Lease.live?/1`, the boot sweep, `destroying` as the one durable
transition (driven by `SandboxReaper.sweep_fenced_teardowns/0` over
workspace rows), `Machines.Reads` admission (0039) under the workspace lock,
and the quota count of a `resuming` transition. An implicit workspace has
the same owner, so there is still one owner per conversation in the
implicit case.

A conversation is bound to its workspace, and through it to the workspace's
current sandbox. `detach` ends the machine only for an implicit workspace;
on any other it is `:detached`. `Machines.Occupancy`, which still reads a machine as
a set of conversations, becomes the real answer to "is anyone mid-turn" for
the park. `machine_gone` tells every conversation bound to the machine.
Admission does not cap turns per workspace; the fleet ceiling counts
sandboxes, so a workspace is one however many conversations it runs.

### Files

The four read routes of [0039](0039-sandbox-files-over-the-api.md) are also
served at `/api/workspaces/:id/files`, `/file`, `/diff` and `/git-status`,
resolving to the workspace's current sandbox, full scope only, with the same
admission, bounds and never-resume rule. A relative path resolves from
`/home/sprite`, and the confinement roots are `/home/sprite` and the `cwd` of
every live conversation on the workspace. Redaction covers the
workspace's environment and vault plus whatever every live conversation on it
registered. The `/api/sandboxes/:id` routes stay.

### One trust boundary

A workspace is one trust boundary, like a person's own laptop. Every process
in it runs as the same user on the same disk, so a process in one
conversation can read another conversation's files, its config home, its
process environment through `/proc`, and its `MANAGOAT_TOKEN`; it can plant
hooks or a `CLAUDE.md` that another conversation's agent then runs or obeys,
the #2525 finding. Separate config homes stop accidental collisions, not a
hostile process. This is accepted, not mitigated:

- A sandbox key's reach in a workspace is, in effect, the union of the trees
  ([0096](0096-sandbox-key-confined-to-its-conversation-tree.md)) of every
  conversation on it.
- `sandbox_api_access: "none"` ([0045](0045-sandbox-api-access.md)) is a
  claim about a machine: such a conversation must be alone on a fresh one
  (today `launch.ex` refuses it with a caller-chosen machine name, #1632).
  So `workspace_id` with `"none"` is refused with
  `422 invalid_sandbox_api_access`, and `"none"` exists only on an implicit
  workspace.
- The broker's placeholders hold ([0019](0019-egress-credential-brokerage.md)):
  the sandbox still holds no real outbound credential, but each
  conversation's proxy session token is readable by the others.

A caller who wants isolation launches without a `workspace_id`.

### Refused

- An implicit "my agent's machine" lookup. A workspace is named by id.
- Attaching to another conversation's sandbox, by `sandbox_id` or otherwise.
- Children landing on the parent's workspace.
- Moving a workspace to another environment, vault or provider.
- Sharing a workspace between users.

### Data

A `workspaces` table (`user_id`, `environment_id`, `vault_id`, `provider`,
`name`, `implicit`, `status`, `error`, and from step 3 the lease columns),
`sandboxes.workspace_id` with a partial unique index on
the non-terminal row, and `conversations.workspace_id`. Deleting an
environment or vault that a non-implicit workspace names is refused with
`409` while the workspace exists; today the foreign keys nilify, and they
still do for implicit workspaces.
The migration makes one implicit workspace per non-terminal sandbox, from the
environment and vault its launch resolved (recorded on the sandbox row), and
points the sandbox and the conversation at it, with the status its sandbox implies; terminal sandbox
rows keep a null `workspace_id`.

### Naming

"Workspace" already names the runtime's working directory in the code
(`Managoat.Runtimes.Layout`, gemini's `/tmp/gemini-workspace`) and in
[0039](0039-sandbox-files-over-the-api.md). Those uses become "working
directory" or `cwd` when this is built.

## Amendments

- **[0073](0073-one-sandbox-per-conversation.md).** "Every conversation gets
  a sandbox of its own and keeps it for its life" becomes "every conversation
  without a `workspace_id` gets an implicit workspace of its own"; that case
  is unchanged. "The sandbox is destroyed when the conversation ends" holds
  for implicit workspaces only. The 422s for `sandbox_mode: "persistent"` and
  `sandbox_id` stay. "No conversation sees another's files" becomes "no
  conversation sees another's files unless the caller put both in one
  workspace". "The max-lifetime ceiling destroys every machine; it used to
  park a home" is reversed for explicit workspaces: the ceiling parks an
  explicit workspace's machine and destroys an implicit one's.
- **[0058](0058-the-machine-has-one-owner.md).** "A sandbox has one owner ...
  registered under the sandbox id and backed by a lease on the `sandboxes`
  row" becomes "a workspace has one owner, registered under the workspace id
  and backed by a lease on the `workspaces` row". The transitions, the
  epoch compare-and-set, the boot sweep, the durable `destroying` and the
  verb table stand, keyed by workspace; `provision` gains the rebuild of a
  lost machine under the same owner, and `machine_gone` tells every bound
  conversation instead of one. The binding layer that 0073 collapsed comes
  back one level up: the conversation binds to a workspace, and `detach`
  keeps the machine for a non-implicit one. There is still no `attach` verb
  and no refcount: the workspace, not a count of conversations, decides
  whether the machine lives. `Policy.reclaim_action/2` takes the workspace's
  kind.
- **[0017](0017-suspend-idle-sandboxes.md).** The idle clock is the
  workspace's (last turn end of any conversation), and a wake loads one
  conversation's session. "Every machine is one conversation's, so there is
  no case where the ceiling parks instead of destroying" stops holding: the
  ceiling table gets back the row 0073 removed, as "explicit workspace:
  park" beside "implicit workspace: destroy", and an explicit workspace's
  machine has no hard lifetime.
- **[0039](0039-sandbox-files-over-the-api.md).** The reads are also
  addressed by workspace, and "a sandbox belongs to exactly one conversation"
  holds only for implicit workspaces.
- **[0045](0045-sandbox-api-access.md), [0096](0096-sandbox-key-confined-to-its-conversation-tree.md).**
  Their guarantees hold per implicit workspace; in a shared one they are
  bounded by the trust boundary above.

## Against the home machinery 0073 removed

| 0023 home machinery | Under this ADR |
|---|---|
| Home found by lookup on (user, agent, environment, vault, runtime), with a partial unique index | Stays gone. A workspace is created and named by id; nothing is looked up |
| Machine identity derived from an agent; retired when the agent, environment or vault moved | Stays gone. The workspace's environment and vault are fixed at create, and an agent is not part of its identity |
| Last-detach refcount deciding whether the machine stays | Stays gone. The workspace decides: implicit ends with its conversation, explicit lives until deleted |
| Many conversations on one machine at once | Returns, by explicit `workspace_id` only |
| Co-tenants following or stranded when a dead home was rebuilt | Partially returns as Sandbox lost: every conversation keeps its transcript and loses its session, and the next prompt re-provisions. No follow, no strand |
| Per-runtime turn capacity (`409 sandbox_at_capacity`) | Stays gone. No turn cap per workspace |
| One agent per runtime on a machine; guest attach of another runtime | Stays gone. Per-conversation config homes make any mix of agents and runtimes independent |
| Shared `CODEX_HOME`, the Codex auth binding (`409 codex_inference_conflict`) and the SQLite relaunch (#1910) | Stays gone. Each Codex conversation has its own `CODEX_HOME` |
| Skills record keyed by runtime | Stays gone. Skills live in each conversation's config home; the machine's record is not needed for them |
| Home checkpoint at park | Stays gone |
| A home parked at the max-lifetime ceiling | Returns for explicit workspaces: the ceiling parks, and the machine has no hard lifetime |
| Reset door (`DELETE /api/sandboxes/:id`) | Stays gone. Deleting the workspace, or creating another, is the reset |
| `sandbox_id` attach | Stays refused; `workspace_id` replaces it |
| A child landing on the parent's home | Stays gone. A child gets a sandbox of its own |
| Cross-conversation disk, shared checkouts, shared memory files | Returns inside a workspace, as one trust boundary |

## Consequences

- Clients get "one machine, many agents, any folder" without a second
  lifecycle: the implicit workspace is today's model, and an explicit one
  differs only in who decides when the machine ends.
- Blast radius grows back inside a workspace, by the caller's choice, and the
  sandbox key's tree confinement is weaker there. The caller who does nothing
  gets today's isolation.
- Each conversation pays a Claude first-start fetch and a resident adapter
  process; a busy workspace uses more memory than one conversation did.
- A lost sandbox costs every conversation on the workspace its session and
  its disk at once, where it used to cost one.
- An explicit workspace's machine has no hard lifetime: Managoat's own
  bounds park it and never destroy it, so parked machines accumulate with
  the workspaces callers keep.
- **Nothing in Managoat bounds that accumulation, by decision.** There is no
  per-account workspace cap and no retention bound on parked sandboxes.
  Managoat is self-hosted ([0005](0005-platform-shared-sprites-token.md):
  no per-account cap since 2026-10-13), so the person running it is also
  the one paying the provider, and they watch provider storage and delete
  workspaces they no longer want. If a provider's account-level machine cap
  or storage bill starts binding, 0017's retention knob is the one to add,
  with #649's caveat.
- At the ceiling, an explicit workspace's running turns are interrupted
  (marked interrupted, transcripts kept) so the park does not leave a
  session running unattended. A long turn that crosses the ceiling is cut
  off, as it would be by a destroy, but its disk and session survive.
- The lease move is a change to 0058's protocol, so it needs the adversarial
  review 0058 asks for (#2262), and the migration must carry any
  `destroying` stamp from a sandbox row to its workspace.
- `Machines.Occupancy` stops being degenerate, and the park reads it for real.
- New API surface: `/api/workspaces` (create, list, show, delete, and the four
  file reads), two launch fields, the SDK and CLI for them, and a manual page.
- Provisioning on create gives a workspace a setup step independent of any
  conversation, run by its owner, so environment setup is paid once before
  the first agent arrives rather than inside the first prompt. Not proposed
  here: copying a workspace.

## Cost

Estimated by reading `main` at `d6a3b0c7c` (2026-10-18), not by
prototyping; calibrated against the removals this partly reverses, #2687
(homes: about 3.35k lib and 8.1k test lines deleted) and #2678 (guests:
about 1.0k lib and 1.7k test). Two things make it cheaper than a home: the
machine layer still reads a machine as a set of conversations
(`Occupancy`, `Park`'s co-tenant notice, `Identity`'s per-session tags,
multi-conversation redaction), and every conversation already spawns its own
tagged adapter process. The #1910 relaunch, the Codex auth binding and the
one-agent-per-runtime rule have no code left to remove.

| Area | Lib lines | Test lines |
|---|---|---|
| Schema, `Fountain.Workspaces` context, migration and backfill | 500–750 | 450–650 |
| Machines: owner and lease moved to the workspace (registry key, advisory lock, epoch compare-and-set across two tables, boot sweep, `destroying` driver, reads admission), rebuild under one owner, `detach` keep rule | 1,800–3,100 | 3,800–4,400 |
| Conversations: launch, split provision into machine and conversation steps, wake and re-provision across siblings, terminate, cwd | 900–1,600 | 2,000–3,500 |
| Provision on create: the owner runs the machine-level steps without a conversation server, workspace status and error, the `workspace.status` event, retry on prompt | 250–450 | 450–750 |
| Park, idle clock, the ceiling parking an explicit workspace, reaper | 200–400 | 450–800 |
| Runtimes: layout from a config root, `skills_root/1`, Claude MCP config, per-conversation auth paths | 250–450 | 400–700 |
| Skills record on the conversation | 100–200 | 250–400 |
| Sandbox key rules | 60–150 | 200–350 |
| Files routes by workspace | 80–160 | 200–350 |
| API, schemas, SDK, CLI | 850–1,400 | 1,000–1,650 |
| **Total** | **about 5.0k–8.7k** | **about 9.3k–13.6k** |

Plus about 1–1.5k lines of manual. Keying the owner by workspace accounts
for about 1.5–2.5k lib and 3k test lines of that: the machine layer
addresses its row by `sandbox_id` throughout (about 725 references in lib,
463 in test). It also takes some weight off `Wake`, because a rebuild after
a loss becomes the owner's own transition rather than a handoff between
conversation servers; the estimate does not subtract that. The riskiest
parts are the lease move and the re-provision across a workspace's
conversations; the `ConversationServer` size ratchet means that logic goes
in helper modules.

A PR sequence, each releasable alone:

1. Per-conversation config homes and `cwd`, on today's one-conversation
   machines (runtimes, skills record, Claude MCP config, launch field). No
   workspace yet; proves the 1.2 s and memory cost in production.
2. Schema, implicit workspaces and the backfill: every sandbox gets one,
   and nothing reads them yet. The lease columns move in step 3, with the
   migration that carries them.
3. The owner and lease move to the workspace: registry key, advisory lock,
   compare-and-set, boot sweep, the `destroying` driver and reads admission,
   with the migration carrying in-flight stamps; the owner also learns to run
   the machine-level provision steps itself. Implicit workspaces only, so
   there is one owner per conversation as today and behaviour is unchanged.
   Likely two or three PRs, as 0058's own stages were, each with adversarial
   review.
4. The lifecycle reads the workspace: rebuild after a loss under the owner,
   `detach`, the idle clock, the ceiling's park for an explicit workspace,
   the reaper. Still unreachable without the API.
5. `/api/workspaces` with provision on create, status and its event,
   `workspace_id` on launch, the sandbox-key and `none` refusals, the file
   routes, the SDK regeneration.
6. CLI and the manual page.

## Alternatives considered

- **Bring homes back.** The lookup, refcount and shared config directories
  are what made them expensive; the request is for a machine, not for an
  agent's machine.
- **Workspaces without implicit ones** (a conversation either owns its
  sandbox or is in a workspace). Two lifecycle owners and two code paths,
  which is what 0073 removed.
- **Shared config directories per runtime**, as homes had. Brings back the
  SQLite relaunch, the Codex auth binding and one agent per runtime, to save
  1.2 s and some memory per conversation.
- **Isolating conversations inside a workspace** (separate Unix users or
  `bwrap` per conversation). The clients ask for one machine; a shared disk
  that is also isolated is a contradiction, and the work is large. A caller
  who wants isolation omits `workspace_id`.
- **Keying the owner by sandbox, binding through the workspace's current
  sandbox.** About 1.5–2.5k lib lines cheaper, but every rebuild after a loss
  would hand the workspace to a new owner, and the conversation servers
  would have to agree among themselves which of them provisions the next
  machine. One owner per workspace makes the rebuild one transition.
- **Destroying an explicit workspace's machine at the ceiling**, as 0073
  does for every machine. It would turn an operator's backstop into a
  periodic wipe of a disk the caller kept on purpose.
- **Waiting for running turns at the ceiling before parking.** The ceiling
  exists for the conversation that never stops being busy; waiting would let
  that conversation hold the machine past it indefinitely.
- **A retention bound on parked explicit sandboxes.** It would destroy a disk
  the caller kept on purpose, on a clock the caller did not set, which is
  the amnesia 0017 was written to stop (#649); on a self-hosted deployment
  the operator can delete a workspace instead.
- **A per-account cap on explicit workspaces.** Managoat has no per-account
  caps since 0005's 2026-10-13 change, and on a self-hosted deployment the
  accounts are the operator's own people; a cap would be a knob with no one
  it protects.
- **Both a cap and a retention bound.** Two knobs, each refused above, for
  a cost the operator already sees on the provider's bill.
- **Attach by `sandbox_id`.** A sandbox row does not outlive a loss, so a
  client holding one would be stranded on the first provider death.
- **Provisioning an explicit workspace lazily, on its first prompt.** Less
  code, since the conversation server's pipeline already provisions, but the
  caller asked for a machine set up from an environment and would learn
  that setup failed only by prompting an agent into it, and the first agent
  would pay the whole setup inside its first turn.
- **Rebuilding eagerly after a loss.** It would spend a provision on a
  workspace nobody may come back to; the next prompt is the first moment
  anyone needs the machine.

## History

- 2026-10-18 — Proposed (#2984). In review the maintainer decided that the
  ceiling parks an explicit workspace, that the owner and lease are keyed by
  workspace, that deleting a workspace terminates its live conversations,
  and that gemini's config home is set with `GEMINI_CLI_HOME`.
- 2026-10-18 — The maintainer decided that the ceiling interrupts an
  explicit workspace's running turns, then parks; and that neither a
  per-account workspace cap nor a retention bound on parked sandboxes
  ships, because Managoat is self-hosted and the operator watches provider
  storage.
- 2026-10-18 — Accepted by the maintainer. He confirmed the remaining calls
  as drafted: `422 workspace_fixes_environment`, the agent's allowlists
  applying to the workspace's environment and vault, the workspace's
  provider winning, `cwd` (absolute, under `/home/sprite` or gemini's own,
  created if missing, with or without a workspace), `sandbox_id` keeping
  its 422, implicit workspaces hidden unless asked, `"none"` refused on a
  workspace, file-route roots, the config home removed when a conversation
  ends, no per-workspace turn cap, `409` on deleting an environment or vault
  an explicit workspace names, and the backfill of non-terminal sandboxes
  only. He changed one: an explicit workspace is provisioned on create,
  with a status (`provisioning`, `ready`, `failed` and an error) and a
  `workspace.status` event, a prompt into a failed one retrying the
  provision; a rebuild after a loss stays lazy, and implicit workspaces are
  unchanged.
- 2026-10-18 — Step 2 built (#2985): the `workspaces` table without the
  lease columns, which move in step 3 with the migration that carries
  them; an implicit workspace made with every new sandbox in its
  reservation's transaction, its status taking the provision's outcome; and
  a backfill of one implicit workspace per live sandbox, from the sandbox's
  own environment and vault (the launch's resolved pair, which the
  conversation's override column leaves nil for an agent's default). Until
  step 4's rebuild, a wake that provisions a fresh sandbox gives it a fresh
  implicit workspace and moves the conversation to it, since the old
  sandbox is still live while the new one is reserved. A live sandbox with
  no owner gets no workspace; nothing is audited for an implicit one.
