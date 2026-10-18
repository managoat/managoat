# About conversations

This page explains what a Conversation is, and what happens to its sandbox
over time. For the state table, read
[Conversation states](../reference/conversation-states.md). For the endpoints,
read the [Conversations section](../api.md#conversations) of the API
reference.

## What a conversation is

A Conversation is one run of an [Agent](agent.md) in a sandboxed machine.

It starts with a prompt and continues over turns. It has a transcript, a
stream of log events, and a status. It is the only primitive that costs money
while it exists, because it is the only one with a machine attached.

## Why it exists

The other three primitives are configuration. They could have been one object
with three sections. The Conversation is the reason they are not.

At the Conversation, Managoat resolves all three together into a machine that
runs. The Conversation picks an Agent. It can override that Agent's
Environment, and it can attach a Vault. It does all three at launch, and not at
configuration time.

That is what lets one Agent serve staging and production. It lets one
Environment serve twenty agents. It lets any of them borrow one Vault.

## How it works

A launch resolves the full environment variable set, then asks a sandbox
provider for a machine.

```
POST /api/conversations
        |
        v
resolve agent -> environment (or the per-launch override)
        |
        v
merge environment secrets with vault secrets   (vault wins)
        |
        v
provision a sandbox, write skills and the system prompt
        |
        v
run the turn, stream log events over SSE
```

The same machine runs another turn for a follow-up prompt. You can interrupt a
turn that runs, and you can end the whole conversation early.

A Conversation keeps the Agent, Environment and Vault it was created with. To
run a different selection, start a new Conversation. Each wake reads the
Agent again, so its edited system prompt, skills and MCP configuration reach
the machine on the next prompt.

A Conversation runs its Agent's model unless it names one of its own. Name one
when you create it. See [Choose the model](../api.md#choose-the-model).

A Conversation's agent runs in a working directory inside the sandbox, which
the launch may name with `cwd`, and keeps its runtime configuration in a
config home of its own. See
[Choose the working directory](../api.md#choose-the-working-directory).

Reasoning effort, fast mode and the runtime's other session options belong
to the Agent, in its `session_config`. A Conversation copies its Agent's
options when it's created and requests them on every turn, so an edit to them
reaches new Conversations only. A Conversation and a prompt can't set options
of their own. See
[Set reasoning effort and fast mode](../api.md#set-reasoning-effort-and-fast-mode).

Log events stream in real time over
`GET /api/conversations/:id/stream`. Add `?blocks=true` and the server parses
ACP events into transcript blocks. Other streams remain available as raw
event data. Historical vendor stdout formats no longer produce blocks.

The additive `plan` block kind carries the full ordered checklist in `body`,
including an empty list when the agent clears it. Each entry has `content` and
`status` (`pending`, `in_progress`, or `completed`). Entries can also carry
`priority`, `id`, and `activeForm`. Each snapshot can render independently in
live output or event replay.

## The sandbox does not live forever, and that is two rules

Both bounds act on the sandbox. Neither one ends the Conversation, which stays
resumable either way.

**Idle suspends.** By default, 60 minutes with no turn activity suspends the
sandbox. It scales to zero, and a parked sandbox costs nothing. The next
prompt wakes it, and the agent's memory is intact. The runtime keeps its
session on the sandbox's disk, and a suspended sandbox keeps its disk.

**Nothing stops a busy sandbox.** A conversation that keeps its sandbox busy
keeps it up. There is no ceiling on a continuous run by default. A
self-hoster can set one with `SANDBOX_MAX_LIFETIME_HOURS`. When set, to cross
it destroys the sandbox, and the disk goes with it. The stored
transcript survives and the conversation stays resumable. The next turn
starts a fresh runtime session, so the agent answers without the earlier
turns.

The difference matters. Suspend keeps the agent's memory. A destroy does
not.

A self-hoster can widen or stop the idle bound with
`SANDBOX_IDLE_TIMEOUT_MINUTES`, and a `0` stops it. Read the
[configuration reference](../configuration.md).

Not every sandbox provider can suspend. A provider that does not advertise the
capability destroys on idle. It does not fake a park, because a resume with a
fresh disk would lose the agent's memory without a sound. Read
[the sandbox contract](../integrations/sandbox-contract.md).

## What a conversation is not

**Not the transcript.** Managoat stores the transcript, and the transcript
outlives the sandbox. The Conversation is the run.

**Not a chat session in a UI.** Managoat's own console renders no
conversations. You watch one work in a separate application on `/api`:
Arugula or the
[conversations app](https://github.com/managoat/demos/tree/main/apps/fountain-conversations)
(see [the apps](surfaces.md#to-watch-an-agent-work-use-a-different-application)).

**Not a sandbox you create.** Managoat provisions the sandbox when the
Conversation starts, one for each Conversation, and reclaims it on the rules
above. `GET /api/sandboxes` lists them.
Read [About sandboxes](sandboxes.md) and the
[Sandboxes section](../api.md#sandboxes) of the API reference.

## When to use something else

When you want one thread with an agent that continues, and not one run for
each task, keep the Conversation's id and send each prompt to it, or bind it
to a `channel_id` of your own. When a run must happen without you, run your
own cron and send the prompt when it fires. Read
[A long-lived agent, or one on a clock](../api.md#a-long-lived-agent-or-one-on-a-clock).

## Where to go next

- [Conversation states](../reference/conversation-states.md), the state table.
- [Architecture](../architecture.md), for what runs where.
- [The guided tour](../tour.md), which runs one from start to finish.

## Labels

A conversation carries free-form `key=value` strings. They record what a run
found, and not what it said. `env=prod` and `drift=true` are the shape of
them.

Set them at launch, merge them later with
`PATCH /api/conversations/:id/labels`, or let the agent stamp its own run over
the ACP extension notification. Filter a list with a repeatable
`?label=env:prod` parameter, which Managoat combines with AND.

A conversation holds at most 32 of them. A key is at most 64 bytes and a value
is at most 256 bytes. Read the
[Labels section](../api.md#labels) of the API reference for the wire format,
the merge rules and the size limits.

Labels are not part of full-text search. Search covers titles, prompts and
replies, which is what a person scans. A label is a fact a program already
knew.

## Discover conversations on a sandbox

Use `GET /api/conversations?sandbox_id=<uuid>` to find the conversation on a
machine you own. Combine it with `agent_id`, `channel_id`, `status` or
`roots_only`, and add `limit` (1 to 500) to cap the page. A client that polls
the list must filter and cap it. The whole account is the default, and on a
busy account that is hundreds of rows per call. The TypeScript SDK accepts
`managoat.conversations({sandboxId: id, rootsOnly: false})`.

`GET /api/events/stream` includes new events from conversations that finish
before the stream discovers them. A `Last-Event-ID` cursor also replays
finished conversations. Without a cursor, the stream starts with events
recorded after connection. The `streams` and `blocks` options apply to replay
and live output.

## Usage accounting

A turn's `usage` contains the token counts that its runtime reports.
Optional `usage.accounting` identifies the adapter's source, version, scope and completeness.
These fields describe the adapter's claim, not a verified bill.
`reported` does not guarantee coverage beyond the stated scope.
`partial` indicates incomplete accounting; known counts remain available.

A metadata-only report has no token counts. Missing counts do not mean zero usage.
An interrupted turn carries the usage its runtime reports when it answers the cancel.
A runtime that does not answer within a few seconds leaves the turn's usage unknown.
Older reports lack accounting metadata and remain unqualified.
Managoat does not reconstruct their missing requests.
Conversation `usage_total` sums reported input and output; it is not a complete cost total.
Metadata is present only when the installed runtime adapter emits it.

A codex turn counts every model request of its prompt on the conversation's
own thread, so a turn that calls tools reports all of its requests. Codex
turns recorded before the codex-acp 2.2.2 pin count only their last request,
and nothing marks which those are. The codex adapter emits no accounting
metadata, so a codex turn has no `usage.accounting`.
