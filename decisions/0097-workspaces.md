---
type: ADR
title: "A workspace owns the sandbox, and conversations run in it"
description: "Unbuilt: a workspace (user, environment, vault, fixed at create) owns the sandbox and its lifecycle; a conversation may launch into one of the caller's workspaces in any folder, with a config home and adapter process of its own, and a conversation that names none gets an implicit single-use workspace ended with it."
tags: [sandbox, lifecycle, conversations, product, api]
status: draft
adr: "0097"
adr_status: "Proposed"
date: 2026-10-18
---

# 0097 — A workspace owns the sandbox, and conversations run in it

**Status:** Proposed, 2026-10-18. Nothing here is built. The design points
were chosen by the maintainer; the calls marked **(open)** were made while
drafting and are his to confirm. If accepted, it amends
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
describes, and destroyed when the workspace is deleted. A workspace has at
most one non-terminal sandbox at a time, and over its life it may have a
succession of them (see Sandbox lost).

**Every sandbox has a workspace.** A conversation launched without a
`workspace_id` gets an **implicit** workspace, made in the same reservation
as its sandbox, with the environment and vault the launch resolved as it does
today, and destroyed with the conversation. So there is one lifecycle owner
everywhere, and today's behaviour is the implicit case. Implicit workspaces
are marked as such and are not listed by `GET /api/workspaces` unless asked
**(open)**.

### Launching into a workspace

`POST /api/conversations` takes two new optional fields:

- `workspace_id`: one of the caller's workspaces. The conversation runs on
  its sandbox. The agent supplies the runtime, model, skills, MCP servers,
  instructions and permission policy; the environment and vault come from
  the workspace. A launch that also names an `environment_id` or `vault_id`
  different from the workspace's is refused with
  `422 workspace_fixes_environment` **(open)**. The agent's
  `allowed_environment_ids` and vault allowlist still apply to the
  workspace's environment and vault **(open)**, and the agent's
  `sandbox_provider` is not consulted: the workspace's provider wins
  **(open)**. A workspace that is not the caller's is `404 not_found`.
- `cwd`: an absolute path the conversation's agent runs in, fixed for the
  conversation's life. Today `Fountain.RuntimeDispatch.cwd/1` fixes it per
  runtime; that stays the default. The path must lie under `/home/sprite`
  (or the runtime's own home, for gemini's `/tmp`) and is created if missing
  **(open)**. It is accepted with or without a workspace.

`sandbox_id` keeps its refusal, `422 sandbox_attach_unsupported`, with the
message pointing at `workspace_id` **(open)**. A sandbox row is a
succession member of a workspace, not a handle a client should hold.

A sandbox key (`sprite` scope) may not name a `workspace_id` and may not
create, list or delete workspaces: `403 insufficient_scope`,
`required_scope: "full"`. A conversation started from a sandbox is a child
([0096](0096-sandbox-key-confined-to-its-conversation-tree.md)), and a child
gets a sandbox of its own as today; fan-out stays a sandbox each.

### A config home and adapter process per conversation

Each conversation on a workspace runs its own adapter process with its own
runtime config directory, under `~/.managoat/c/<conversation_id>/`:
`CLAUDE_CONFIG_DIR` for claude, `CODEX_HOME` for codex, and for gemini a
per-conversation `HOME` under its existing `/tmp` home **(open: whether
gemini-cli honours a config-dir variable instead)**. Skills, the agent's
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
  removes its config home **(open)**. The sandbox stays, unless the workspace
  is implicit, in which case the workspace and its sandbox are destroyed as
  today.
- **Deleting a workspace** terminates every live conversation on it
  (transcripts kept) and destroys the sandbox, through
  `Machines.Destroy` with one `sandbox.destroyed` and one `workspace.deleted`
  audit event carrying the caller **(open: terminate rather than refuse with
  409)**.
- **Provisioning is lazy.** Creating a workspace writes the row; the first
  prompt of the first conversation on it provisions the sandbox from the
  workspace's environment, and every later conversation attaches its adapter
  to the running machine **(open: no eager provision on create)**. Two
  conversations prompting a workspace with no sandbox provision it once; the
  second waits, as two wakes resume once today.
- **Park** happens when no conversation in the workspace has a running turn
  and the workspace has been idle for `SANDBOX_IDLE_TIMEOUT_MINUTES`, measured
  from the last turn end of any of its conversations. **Wake is lazy per
  conversation**: a prompt resumes the machine if it is parked and loads only
  that conversation's session (`session/load`); the others stay unattached
  until they are prompted. A workspace with a sandbox and no live
  conversation is parked by the reaper on the same idle bound.
- **Sandbox lost.** When the machine is gone (provider death, a failed
  resume, or the max-lifetime ceiling), every conversation on the workspace
  keeps its transcript and has its runtime session cleared, the workspace
  stays, and the next prompt in any of them provisions a new sandbox from the
  workspace's environment. The max-lifetime ceiling destroys the sandbox, not
  the workspace, on a non-implicit workspace **(open)**; on an implicit one it
  ends the conversation's machine as today. The agents lose their runtime
  memory and the disk's contents, as #649 described; nothing is replayed.
- **Account deletion** deletes the account's workspaces with their sandboxes.

### The owner

[0058](0058-the-machine-has-one-owner.md)'s owner stays per sandbox row: the
`Machine` process is registered under the sandbox id and its lease and epoch
live on the `sandboxes` row, because a workspace has a succession of
sandboxes and an epoch belongs to one of them **(open: keyed by sandbox, not
by workspace)**. What moves to the workspace is the binding: a conversation
is bound to its workspace, and through it to the workspace's current
sandbox. `detach` ends the machine only for an implicit workspace; on any
other it is `:detached`. `Machines.Occupancy`, which still reads a machine as
a set of conversations, becomes the real answer to "is anyone mid-turn" for
the park. `machine_gone` tells every conversation bound to the machine.
Admission does not cap turns per workspace; the fleet ceiling counts
sandboxes, so a workspace is one however many conversations it runs
**(open)**.

### Files

The four read routes of [0039](0039-sandbox-files-over-the-api.md) are also
served at `/api/workspaces/:id/files`, `/file`, `/diff` and `/git-status`,
resolving to the workspace's current sandbox, full scope only, with the same
admission, bounds and never-resume rule. A relative path resolves from
`/home/sprite`, and the confinement roots are `/home/sprite` and the `cwd` of
every live conversation on the workspace **(open)**. Redaction covers the
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
  workspace **(open: refuse, rather than allow and document)**.
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
`name`, `implicit`), `sandboxes.workspace_id` with a partial unique index on
the non-terminal row, and `conversations.workspace_id`. Deleting an
environment or vault that a non-implicit workspace names is refused with
`409` while the workspace exists **(open: today the foreign keys nilify)**.
The migration makes one implicit workspace per non-terminal sandbox, from the
environment and vault of its conversation, and points the sandbox and the
conversation at it; terminal sandbox rows keep a null `workspace_id`
**(open)**.

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
  workspace". "The max-lifetime ceiling destroys every machine" stays true;
  for an explicit workspace it destroys the machine, not the workspace.
- **[0058](0058-the-machine-has-one-owner.md).** Owner, lease, transitions and
  verbs stand, keyed by sandbox. The binding layer that 0073 collapsed comes
  back one level up: the conversation binds to a workspace, and `detach` keeps
  the machine for a non-implicit one. There is still no `attach` verb on the
  machine and no refcount: the workspace, not a count of conversations,
  decides whether the machine lives.
- **[0017](0017-suspend-idle-sandboxes.md).** The idle clock is the
  workspace's (last turn end of any conversation), and a wake loads one
  conversation's session.
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
- `Machines.Occupancy` stops being degenerate, and the park reads it for real.
- New API surface: `/api/workspaces` (create, list, show, delete, and the four
  file reads), two launch fields, the SDK and CLI for them, and a manual page.
- Unbuilt, and not proposed here: eager provisioning on create, a workspace
  setup step independent of any conversation, and copying a workspace.

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
| Machines: `detach` keep rule, join a live machine, one provision per workspace | 300–600 | 800–1,400 |
| Conversations: launch, split provision into machine and conversation steps, wake and re-provision across siblings, terminate, cwd | 900–1,600 | 2,000–3,500 |
| Park, idle clock, max lifetime, reaper | 150–300 | 400–700 |
| Runtimes: layout from a config root, `skills_root/1`, Claude MCP config, per-conversation auth paths | 250–450 | 400–700 |
| Skills record on the conversation | 100–200 | 250–400 |
| Sandbox key rules | 60–150 | 200–350 |
| Files routes by workspace | 80–160 | 200–350 |
| API, schemas, SDK, CLI | 850–1,400 | 1,000–1,650 |
| **Total** | **about 3.2k–5.6k** | **about 5.7k–9.7k** |

Plus about 1–1.5k lines of manual. Keying the owner by workspace instead of
by sandbox would add about 1.5–2.5k lib and 3k test lines. The riskiest part
is the re-provision handoff between a workspace's conversations in `Wake`;
the `ConversationServer` size ratchet means that logic goes in helper
modules.

A PR sequence, each releasable alone:

1. Per-conversation config homes and `cwd`, on today's one-conversation
   machines (runtimes, skills record, Claude MCP config, launch field). No
   workspace yet; proves the 1.2 s and memory cost in production.
2. Schema, implicit workspaces and the backfill: every sandbox gets one, and
   nothing reads them yet.
3. The machine and conversation lifecycle reads the workspace: `detach`, the
   idle clock, Sandbox lost, the reaper. Still only implicit workspaces, so
   behaviour is unchanged; adversarial review per 0058.
4. `/api/workspaces`, `workspace_id` on launch, the sandbox-key and `none`
   refusals, the file routes, the SDK regeneration.
5. CLI and the manual page.

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
- **Keying the machine owner by workspace.** One process would span a
  succession of sandbox rows, each with its own lease epoch, for no gain over
  binding through the workspace's current sandbox.
- **Attach by `sandbox_id`.** A sandbox row does not outlive a loss, so a
  client holding one would be stranded on the first provider death.
