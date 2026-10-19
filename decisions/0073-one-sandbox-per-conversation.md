---
type: ADR
title: "One sandbox per conversation"
description: "Every conversation without a workspace runs on a sandbox of its own (an implicit workspace, ADR 0097), destroyed when the conversation ends; parking stays."
tags: [sandbox, lifecycle, conversations, product]
status: stable
adr: "0073"
adr_status: "Accepted"
date: 2026-10-14
---

# 0073 — One sandbox per conversation

**Status:** Accepted, 2026-10-14, by the maintainer in the complexity review
tracked on #2676. Supersedes [0023](0023-persistent-agent-sandbox.md); amends
[0058](0058-the-machine-has-one-owner.md) and
[0017](0017-suspend-idle-sandboxes.md), as described under Consequences.
Amended by [0097](0097-workspaces.md) on 2026-10-18: what this ADR decides
holds for a conversation launched without a `workspace_id`, which gets an
implicit workspace of its own; a conversation in an explicit workspace shares
its machine, which outlives the conversation and is parked, not destroyed, at
the ceiling (see Amendments).

## Context

[0023](0023-persistent-agent-sandbox.md) added a second sandbox mode beside
the original sandbox per conversation. A persistent "home" was one machine per
agent identity (user, agent, environment, vault, runtime). Every conversation
of that identity landed on it, could run turns on it at the same time, and
left it standing when the conversation ended. A conversation could also attach
to any machine its caller owned by `sandbox_id`. On 2026-09-26 that was
extended to a guest agent of another runtime, and that extension was removed
on 2026-10-14 (the step before this one).

That mode was most of the lifecycle code in `Fountain.Machines` and
`Fountain.Conversations`. It covered home lookup and the partial unique index,
the refcount that decided whether a detach kept the machine, co-tenants that
followed or were stranded when a dead home was rebuilt, per-runtime turn
capacity, home checkpoints, home retirement when an agent, environment or
vault moved, the reset door, the shared Codex auth binding, and a relaunch for
Codex SQLite contention that existed only because conversations shared
`CODEX_HOME`. In the 60 days before the decision, production had 52 homes, 51
of them the maintainer's. None had been used since early September, apart
from 5 conversations in the last 14 days.

## Decision

Every conversation gets a sandbox of its own and keeps it for its life. The
sandbox is destroyed when the conversation ends. While the conversation idles,
the sandbox is parked and woken as [0017](0017-suspend-idle-sandboxes.md)
describes, and that is how a conversation keeps its disk between turns. The
max-lifetime ceiling destroys every machine; it used to park a home.

What the API refuses:

- `sandbox_mode: "persistent"` on `POST /api/conversations` is refused with
  `422 persistent_sandbox_removed`. `"ephemeral"` is still accepted, because
  existing clients send it. The agent has no `sandbox_mode`.
- A non-null `sandbox_id` on `POST /api/conversations` is refused with
  `422 sandbox_attach_unsupported` rather than ignored. A caller that asked
  for a shared disk must not silently get a fresh one.

What is removed: `DELETE /api/sandboxes/:id` (reset), `fountain sandbox
reset` and the admin "Retry reset" (a `destroying` stamp left by a reset is
finished by the reaper as a teardown); the CLI's `--sandbox-mode` and
`--sandbox`, and the ACP `_meta` keys `sandboxMode` and `sandboxId`; home
lookup, home retirement, the home checkpoint at park, co-tenant follow and
strand on a wake, per-runtime turn capacity (`409 sandbox_at_capacity`), the
last-detach keep rule (the fence no longer answers `:sandbox_kept`),
`Machine.attach/3`, the Codex machine auth binding
(`409 codex_inference_conflict`) and the Codex SQLite contention relaunch
(#1910); and the error codes `sandbox_identity_mismatch`,
`sandbox_runtime_mismatch`, `sandbox_not_attachable`, `sandbox_not_resettable`
and `sandbox_mid_turn`.

The machine's skills record is one list, `sandboxes.applied_skills`, written
by `Machine.record_skills/2`. 0023 had keyed it by runtime so a claude and a
codex conversation on one machine could each reconcile their own skills root;
with one conversation per machine there is one runtime and the key carries
nothing.

### The data

Migration `20261014160000_one_conversation_per_sandbox` kept one live
conversation on every live sandbox that carried several. The keeper was the
team conversation if there was one, else the one with the most recent turn.
Every other live conversation was detached: repointed at a new `terminated`
sandbox row of its own, with its runtime session cleared, so its next prompt
provisions a fresh machine and its transcript is kept. On 2026-10-14
production had 60 homes and 3 ephemeral machines carrying more than one live
conversation, 192 conversations on them in all.

The columns this release stopped reading (`sandboxes.mode`, `runtime`,
`codex_inference_source`, `codex_peer_homes`, `departed_conversations` and its
trigger, and `agents.sandbox_mode`) are dropped a release later by
`20261014191000_drop_home_columns`, so a replica of the earlier release kept
working during the rollout. `20261016150000_flatten_sandbox_applied_skills`
filled `applied_skills` from the per-runtime map's entry for the runtime of
the machine's newest conversation (a row without that entry gets no record,
and the next reconciliation falls back to the conversation's Agent version);
`20261016150001_drop_sandbox_applied_skills_by_runtime` drops the map a
release later.

## Amendments

By [0097](0097-workspaces.md), 2026-10-18 (its Amendments section; built in
its step 4, explicit workspaces reachable from step 5):

- "Every conversation gets a sandbox of its own and keeps it for its life"
  becomes "every conversation without a `workspace_id` gets an implicit
  workspace of its own"; that case is unchanged.
- "The sandbox is destroyed when the conversation ends" holds for implicit
  workspaces only, and the implicit workspace goes with it. Ending a
  conversation in an explicit workspace stops its adapter and removes its
  config home; the machine stays (`detach` answers `:detached`).
- The 422s for `sandbox_mode: "persistent"` and `sandbox_id` stay.
- "No conversation sees another's files" becomes "no conversation sees
  another's files unless the caller put both in one workspace".
- "The max-lifetime ceiling destroys every machine; it used to park a home" is
  reversed for explicit workspaces: the ceiling parks an explicit workspace's
  machine, after interrupting every running turn on it, and destroys an
  implicit one's.

## Consequences

- **What a home bought is gone.** No conversation sees another's files, so
  cross-conversation memory, shared checkouts and children on the parent's
  disk all end. A child conversation gets a sandbox of its own. Fan-out is
  unchanged.
- **Blast radius shrinks.** A prompt injection in one conversation reaches
  only that conversation's disk, the risk 0023 asked users to accept.
- **[0058](0058-the-machine-has-one-owner.md) keeps its owner and lease.**
  Only the binding layer collapses: there is no attach verb, and `detach/2`
  always ends with the machine. The lease is simplified separately (#2676).
- **[0017](0017-suspend-idle-sandboxes.md) stands.** An idle machine parks
  and wakes. The "persistent home: park" row of its ceiling table no longer
  applies.
- **Leftovers.** `Fountain.Machines.Occupancy` still reads a machine as a set
  of conversations. With one conversation per machine those readers are
  degenerate but correct, and thinning them is follow-up work.

## Alternatives considered

- **Keep homes behind a flag.** That keeps all of the code for a mode almost
  nobody used.
- **Ignore `sandbox_mode: "persistent"` and `sandbox_id` silently.** A client
  would think it had a shared disk when it did not, so they are refused with a
  clear 422.
- **End the extra conversations on a shared machine in the migration.**
  Simpler, but it throws away conversations that can carry on with a fresh
  disk.

## History

- 2026-10-14 — Decided in the complexity review (#2676): homes, attach and
  reset removed; extra conversations on shared machines detached by migration.
- 2026-10-15 — The team rotation path that provisioned a fresh sandbox went
  with the team ([0074](0074-remove-the-team.md)); its release verb
  `Termination.release_conversation/2` was removed in #2715.
- 2026-10-15 — The skills record keyed by runtime (from 0023's #2514) became
  one list again, `sandboxes.applied_skills`.
- 2026-10-17 — Reusable environment layers ([0090](0090-portable-environment-layers.md))
  were removed; portable environment state is the sandbox provider's to offer.
- 2026-10-18 — Amended by [0097](0097-workspaces.md): this ADR's machine per
  conversation is the implicit workspace; an explicit workspace keeps its
  machine when a conversation ends and parks it at the ceiling (0097 step 4).
- 2026-10-19 — The reset door this ADR removed comes back for explicit
  workspaces only, as [0097](0097-workspaces.md)'s rebuild on request
  (`POST /api/workspaces/:id/rebuild`, #2986), which keeps the conversations;
  `DELETE /api/sandboxes/:id` stays gone.
