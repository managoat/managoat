---
type: ADR
title: "The machine has one owner"
description: "One process per workspace (ADR 0097), holding a durable lease on the workspace's row, is the only writer of sandboxes.status and the only caller of the provider's lifecycle operations."
tags: [sandbox, lifecycle, conversations]
status: stable
adr: "0058"
adr_status: "Accepted"
date: 2026-09-16
---

# 0058 — The machine has one owner

**Status:** Accepted, 2026-09-16. Built 2026-09-16 to 2026-09-18 (tracker
#2344). Amended by [0097](0097-workspaces.md) on 2026-10-18: the owner and
the lease are keyed by the sandbox's workspace (see History). Settles #2307
and open decisions 1–3 on #2255. Takes the idle and
ceiling decision of [0017](0017-suspend-idle-sandboxes.md) into the owner.

## Context

A sandbox row and its provider machine had many writers. On `main` at
`c3f568596` (2026-09-16), `Conversations.update_sandbox/2` and its sibling
`claim_sandbox/2` wrote the row from 28 sites, and the provider's create,
resume, suspend, destroy and checkpoint were called from 17 sites in 9 files:
the conversation server, the reaper, termination, provisioning and its
watchdog, the wake, reapply, the lifecycle module, the home checkpoint and
account deletion. Each writer carried its own protection, and every one of
them was compensation for an owner that did not exist: the fence columns
`reset_requested_at` and `teardown_requested_at`, which a writer had to check
because nobody owned the state they fenced; `expected_sandbox_id`, a
compare-and-set token on every ending write (the nine-PR #1767 campaign,
with #2021 listing the writes it still missed); a retirement changeset match
copied four times (#2039); and four unrelated answers to "is anyone else on
this sandbox" (#2255).

[0023](0023-persistent-agent-sandbox.md) step 4 had specified a per-sandbox
process to serialize provision, resume, park, destroy and re-provision, and
its Outcome recorded that the process was not built. #2286 tried to make the
reaper's idle park safe with a lock and a durable claim, went five
adversarial review rounds, each finding a real ordering gap, and was
withdrawn. #2307 records the seven constraints those rounds established. They
are not reaper constraints; they describe what any owner of the machine must
do. The one a lock cannot satisfy is that the provider round trip sits
between deciding and writing, and a transaction-scoped lock cannot span it.

#2175 and #2255 had already given each conversation lifecycle verb one owner
(`Launch`, `Wake`, `Termination`, `Interruption`). The thing they all acted
on still had none. State with many concurrent writers and external I/O in the
middle of its transitions is the shape Erlang answers with a process.

Since this was decided, each conversation has a sandbox of its own
([0073](0073-one-sandbox-per-conversation.md)) and Managoat runs as one node
([0072](0072-fountain-runs-as-one-node.md)). Neither removes the need: a
provision runs in a `ConversationServer` while a park or a destroy runs in the
machine's owner, and the provider round trip still sits between deciding and
writing, so two processes on one node still race without it.

## Decision

A sandbox has one owner: a `Fountain.Machines.Machine` process, registered in
the local `Fountain.MachineRegistry` under the id of the sandbox's
**workspace** and backed by a lease on the `workspaces` row
([0097](0097-workspaces.md); until then the sandbox id and the `sandboxes`
row). Every verb still names the machine by its sandbox. It is the only code that writes
`sandboxes.status` and the timestamps of a transition, the only caller of
`Managoat.Sandbox.create/2`, `resume/1`, `suspend/1` and `destroy/1`, and the
one answer to "who is on this machine, and is anyone mid-turn"
(`Machines.Occupancy`, read behind the existing predicates). Conversation
servers, the reaper, `Launch`, `Wake`, `Termination`, the admin surfaces and
`Accounts.Deletion` send it requests and never touch the row or the provider.
There is one GenServer per active machine, stopping when idle, not one per
row. What a reclaim means (park or destroy at each bound, given the
provider's capability) lives in `Fountain.Machines.Policy`.

### The lease

The source of truth is the lease on the row, not the process: `lease_epoch`
(a monotonic integer) and `lease_node`, the holder, written as
`"<boot id>/<pid>"`. The boot id is drawn once when the application starts.
`Lease.live?/1` is true exactly when the boot id is this boot's and the
process is alive; `Machine.busy?/1` and every reader follow it, and none reads
a clock. A holder that dies stops holding when it dies.

A lease is claimed in one short transaction under the per-workspace advisory
lock, with a `FOR UPDATE` re-read of the row. It is per operation: an idle
machine holds none, so "busy" means a live lease, not a stamped transition.
Every state write the owner makes is a compare-and-set on
`(id, lease_epoch)`; a write from a superseded epoch affects zero rows, and
the process that made it stops. Taking a lease from a live holder is
`Lease.claim(id, supersede: pid)`, and its one caller is `ProvisionWatchdog`,
which retires a provision whose server is wedged and stops that server.

`Fountain.Machines.BootSweep` runs straight after the migrator, before Oban,
the endpoint or the rehydrator can claim anything. `Lease.sweep_boot/0` clears
every lease another boot left, and every `transition` but `destroying`.

### In-flight states are durable

Beside the status set (`pending starting ready suspended terminated failed`)
the row has a nullable `transition` (`provisioning`, `resuming`, `parking`,
`destroying`) and a `transition_reason`, stamped with the epoch. The owner
writes the transition before any provider I/O, does the I/O outside every
transaction, then finalizes with a compare-and-set on the same epoch and
transition. A reader that meets a transition under a live lease gets a
retryable refusal rather than racing it. A transition whose holder is gone is
an abandoned operation, and readers clear it.

A finalize lost after a successful provider call is repaired by the next
claimant, which reads the machine's true state: for `parking`, it finalizes a
machine the provider reports suspended and clears the transition on one it
reports running, leaving the row `ready` for the next idle verdict. It never
resumes, because a resume is compute and belongs behind the account and quota
gates this protocol does not consult.

`destroying` is the one durable transition. It is a request somebody made, so
every reader refuses it whatever the lease says, no reader clears it,
`Lease.cas_update/4` keeps it through any write that does not retire the row,
and quotas count it until the row is terminal. It survives the death of any
owner and any restart. `SandboxReaper.sweep_fenced_teardowns/0` is its driver,
on a five-minute cron entry of its own: it finishes a destroy once the stamp
is fifteen minutes old and no server holds the machine. A five-minute driver,
rather than folding into the hourly reaper pass, keeps an abandoned destroy
from waiting up to 75 minutes under a budget sized without it. A terminal
row still wearing the stamp is cleared by `Machines.Destroy`'s
`already_terminal` clause. This is what replaced the fence columns.

### The verbs

| Verb | Where it runs | Rule |
|---|---|---|
| `destroy` | owner | One door for terminate, agent delete, admin reap, account deletion and the reaper's expiry. One `sandbox.destroyed` audit event carrying the actor ([0013](0013-audit-trail.md)). Ends every running turn bound to the machine at its finalize. Account deletion nilifies `user_id`, so the owner destroys an ownerless row (#2329); deletion's teardown stays non-fatal |
| `park` | owner | Idle reclaim, on a provider that can suspend; refused while a turn is admitted. A park over a turn nothing is driving leaves that turn: a turn parked on a person's permission is theirs to answer. At the max-lifetime ceiling the machine is destroyed instead (`Policy.reclaim_action/2`) |
| `ensure_up` | owner | Resume a suspended machine. Two wakes resume it once; the second waits. The quota gate is settled before the provider call |
| `provision`, `confirm_up`, `fail_provision` | caller | A bracket: the owner's code takes the lease, stamps the intent, creates the machine and writes the outcome, while the conversation server's own pipeline runs in the middle as a callback. That pipeline builds the server's state and runs for minutes, so it cannot move into another process; the other two follow it so one family has one answer. All three refuse an enclosing transaction. The reservation needs no stamp: the row is inserted `pending` inside the quota transaction, and `pending` already counts |
| `admit_turn` | owner | The locked turn insert (`Machines.Admission`) refuses a live lease and a `destroying` row |
| `end_turn` | caller | The door for every turn-ending write. It writes only the conversation's rows, under their own locks, so queueing it behind a minute-long park would hold a server's shutdown path in a call |
| `detach` | owner | The last-detach decision, which always ends with the machine. It refuses a live lease (waited out briefly, then `sandbox_unavailable`) and carries the caller's deadline. Answers `:detached`, `:destroyed` or `:already_terminal` |
| `record_skills` | caller | The one write of `applied_skills`, after a wake's skills reconciliation (`Conversations.Skills.mount/3`). Inline under the machine's advisory lock; refused only on a terminal or missing row |
| `machine_gone` (outbound) | owner | The owner tells the bound conversation once; `Conversations.MachineEvents` is its outbound, callable from `lib/fountain/machines/` only |

The launch reserves the machine and its conversation together, so there is
no attach verb.

The fence for every turn-ending write is the conversation's current binding
(`Machines.Admission.bound?/2`), not the epoch. A park that proceeds over a
turn whose server is dead moves the epoch, and the recovery of that turn is
exactly the write that then has to succeed. The epoch fences machine state
only.

A refusal is the existing `sandbox_unavailable`, not a new word: it was
already 503 with a `Retry-After` and already handled by the SDK.

### What stays outside the owner

- The conversation server keeps its adapter, transcript, callback key, turn
  state machine and the handle (`Managoat.Sandbox.build_handle/2` is pure; the
  server rebuilds it from the row). It asks the owner for a turn slot and is
  told when the machine is gone. `state.sandbox_id` is immutable.
- `SandboxReaper` schedules and does not write. It keeps its scans and
  telemetry and sends `park` or `destroy` requests, which the owner
  revalidates under its own lease.
- One provider call stays outside the owner on purpose: the reaper's destroy
  of a provider machine whose row is already terminal, which no owner will
  ever claim. The untracked-machine report stays in the reaper for the same
  reason.
- In the test suite only, the owner serves each call with its caller's
  `$callers`, so a test's SQL-sandbox connection and stubs reach it (a flag
  set in `config/test.exs`). Production must not: `opentelemetry_ecto`, a
  production-only dependency, would copy the caller's process dictionary on
  every query and re-parent the owner's database spans.

### Rules the reviews paid for

- Revalidate under the lock, every time. A pre-lock verdict is stale by
  construction (#2307 constraint 1).
- Provider I/O is never inside a lock or a transaction. A nested
  `Repo.transaction` joins the outer one and holds a transaction-scoped
  advisory lock until the outer commit; a nested `Repo.rollback` aborts the
  whole enclosing transaction, so "not eligible, skip" is a plain return
  (#2309).
- Under a lock, write the row and run effects after commit, with the status
  the `FOR UPDATE` read saw (#2309).
- A sweep over failure leftovers must not `{:ok, _} =` its write; one refused
  row stopped machine cleanup fleet-wide (#2329).
- A release that stops reading a column must check what the previous released
  version wrote to it (see History, v0.20.1).
- Five rounds of "one more finding" means stop and redesign, not round six.
  That is how this ADR came to exist.

## Consequences

- Gone with the owner: the `expected_sandbox_id` plumbing and #2021's
  reconciliation debt, the two fence columns, `SandboxResetReconciler`,
  `Conversations.update_sandbox/2` with its four copies of the retirement
  match, and the duplicate admin reap audit.
- A lease protocol is real work with real failure modes, and a behaviour
  change here needs adversarial review (#2262). Every behaviour stage had at
  least three independent reviews and a revert sweep proving its tests.
- `ConversationServer.init/1` does no database work, because registration
  runs inside the per-sandbox lock transaction
  ([0072](0072-fountain-runs-as-one-node.md)).
- One residue: `Quotas.active_sandboxes/0` counts a `resuming` row in SQL,
  which cannot ask whether a process is alive, so a resume whose holder died
  in this boot counts until the next claim on that machine or the next boot.
  The protocol rescues its adapter, so such a death is a defect.
- `Machines.Occupancy` still reads a machine as a set of conversations. With
  one conversation per machine its readers are degenerate but correct.
- Abandoned destroys are measured on the five-minute run's own event,
  `fountain.reaper.teardowns.reconciled` and `.refused`.
  `FountainReaperTeardownsSilent` (jhgaylor/home-cloud#234) fires when the
  first has been absent for 30 minutes; it catches a run that never reported
  since boot, not one that ran and then stopped.
- Not built: #1120, a meter for a machine's kept time, which the owner would
  make natural.

## Alternatives considered

- **Keep fencing per write** (#1767 continued). 25 branches, four writes still
  unfenced (#2021), and #2307 showed the park cannot be fixed by a lock. It
  needs every writer to be individually correct, forever.
- **Postgres only: a transition column with compare-and-set, no process.**
  Covers constraints 1–3 but not the serialization of two wakes, and the
  provider I/O still has many callers. The process is what makes the I/O
  single-file.
- **A process only, no lease** (0023's `SandboxServer` as written). Two owners
  during a rolling deploy, which the asynchronous Horde registry made real on
  #2286. With one node this argument is weaker, but the lease still carries the
  durable transition and the epoch compare-and-set that keep a provision in a
  server and a park in the owner apart.
- **Rewrite the conversation server.** #1369 and #2175 showed subtraction
  works here.

## History

- 2026-09-16 — Decided: one owner per machine behind a TTL lease renewed on the database's clock, rolled out behind `MACHINE_OWNER_ENABLED`; stage 1 (#2342), tracker #2344.
- 2026-09-17 — Stages 2–8b built: a direct-writes ratchet, the lease, the read-only process, then destroy, park (closing #2307), resume, the provision bracket, admission and binding through the owner (#2346–#2377). Stage 6a settled that "busy" means a live lease, not a stamped transition (refusing on a dead lease withheld a machine up to 75 minutes), added a `woken_at` marker for Horde's asynchronous registry, and kept `sandbox_unavailable` as the refusal (#2365). 7a moved the lease onto the database's clock with a renewer. The gate was turned on in production (home-cloud#233).
- 2026-09-18 — `destroying` made the one durable transition, driven by the reaper (#2386); the gate deleted and the fence columns unread, shipped in v0.20.0 (#2423, #2426).
- 2026-09-18 — v0.20.1's backfill stamps `destroying` on fences v0.19.0 wrote only to the columns, except a reset on a machine used since the request, which is logged by id and discarded (#2427, #2433); the column drop runs the backfill again first, because a v0.19.0 replica on a rolling upgrade could still write one.
- 2026-09-18 — Fence columns dropped and `SandboxResetReconciler` deleted (stage 9b-ii); accepted with an Outcome.
- 2026-10-14 — Reapply removed: no code moves a machine's binding identity; the skills record becomes `Machine.record_skills`, and admission takes no revision (#2676).
- 2026-10-14 — One sandbox per conversation ([0073](0073-one-sandbox-per-conversation.md)): no attach verb, detach always ends the machine, no inference binding, no per-runtime capacity, no home checkpoint at park, and the reset door is gone (a leftover reset stamp is finished as a teardown) (#2676).
- 2026-10-14 — One node ([0072](0072-fountain-runs-as-one-node.md)): the `woken_at` marker goes, since registration now happens under the lock; the lease becomes a holder of this boot with a boot sweep, and the renewer, TTLs, database clock and early takeover are deleted; `lease_until` dropped (#2686).
- 2026-10-15 — The release (`detach` with `policy: :keep`) removed with the team ([0074](0074-remove-the-team.md), #2715).
- 2026-10-15 — The environment warm-start checkpoint removed, leaving the reaper's destroy of a terminal row the one provider call outside the owner (#2720).
- 2026-10-15 — The direct-writes ratchet test removed (#2721); `woken_at` dropped (#2725).
- 2026-10-18 — Keyed by workspace ([0097](0097-workspaces.md) step 3b): one owner per workspace, registered under the workspace id; `lease_epoch`, `lease_node`, `transition` and `transition_reason` read from and written to the `workspaces` row, with the per-workspace advisory lock (namespace 4316, keyed by the workspace id) and the compare-and-set on the workspace's epoch; every locked reader takes the workspace's row before the sandbox's. The transitions, the boot sweep (over workspaces), durable `destroying` (`sweep_fenced_teardowns/0` over workspace stamps), `Machines.Reads` admission and the quota count of `resuming` carry over keyed by workspace. A sandbox retired before workspaces existed has no owner and is answered as terminal. The sandbox's own four columns are still written as a copy for a rollback, and dropped a release later. Not yet: the rebuild of a lost machine under the same owner, `detach` keeping the machine of a non-implicit workspace, `machine_gone` to every bound conversation, and `Policy.reclaim_action/2` taking the workspace's kind (0097, steps 3c and 4).
