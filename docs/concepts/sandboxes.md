# About sandboxes

This page explains what a sandbox is, why Managoat does not let you create
one, and what changes when you move to a different provider. For the
executable contract a backend must meet, read
[the sandbox contract](../integrations/sandbox-contract.md). To choose and
configure one, read [Self-host Managoat](../self-hosting.md). For the
endpoints, read the [Sandboxes section](../api.md#sandboxes) of the API
reference.

## What a sandbox is

A sandbox is the isolated machine that a [conversation](conversation.md)
runs in. By default every conversation gets a sandbox of its own, and no two
conversations share one.

You never create a sandbox directly. Managoat provisions one when a
conversation starts. It parks the sandbox when the conversation goes quiet,
wakes it on the next prompt, and destroys it when the conversation ends.
`GET /api/sandboxes` lists them, and `managoat sandbox` does the same from the
CLI. Both are read-only.

That is deliberate. A sandbox you could create on its own would be a resource
you could leak. The machine that nobody remembered to stop is what makes agent
infrastructure expensive.

The one exception is a [workspace](workspaces.md): a machine you create by
name, set up once from an environment, and run many conversations on, each in
its own folder. Its machine outlives each conversation and ends when you
delete the workspace, so you take on the cost of remembering it. Behind the
scenes every sandbox belongs to a workspace; a conversation without one has an
implicit workspace of its own, made and ended with it, which is everything
this page describes.

One conversation builds one sandbox. Managoat runs one server for each
conversation, and a deploy stops the old instance before it starts the new
one, so only one process builds the machine. A second start for the same
conversation finds the first and hands its prompt over.
A build that stops part-way is torn down and started again rather than
continued, because the steps it runs cannot be repeated on top of themselves.
Building has an absolute ceiling: after about half an hour Managoat stops it,
records the sandbox as failed, and the next prompt starts a fresh one. If
Managoat cannot write that record — because something else is working on the
sandbox at that moment — it asks again for up to a quarter of an hour and then
stops the build anyway, leaving the sandbox for the hourly cleanup pass.

## One machine per conversation

A conversation keeps its sandbox for its whole life. Its notes, clones and
installed tools stay on the disk between turns, and the agent's session stays
there too, so a parked conversation picks up where it left off. When the
conversation ends, the sandbox is destroyed. In a workspace it stays, for
the workspace's other conversations.

A child conversation that an agent starts gets a sandbox of its own, even
when its parent runs in a workspace: a sandbox's key cannot name a workspace.
Two conversations share a disk only when you launched both into one
workspace.

Older clients may still send `sandbox_mode`. `ephemeral` is accepted and
changes nothing. `persistent` answers `422 persistent_sandbox_removed`, and a
`sandbox_id` on `POST /api/conversations` answers
`422 sandbox_attach_unsupported`; a `workspace_id` is how conversations share
a machine now. Persistent sandboxes, one machine that every
conversation of an agent shared, were removed in 2026-10. On upgrade, a
sandbox that carried several live conversations keeps one: the
conversation bound to the former team channel if there is one, otherwise the
one with the most recent turn.
Each of the others keeps its transcript and builds a fresh sandbox on its next
prompt.

## When Managoat is working on a machine

One operation at a time acts on a machine. A prompt that wakes a machine, a
prompt to a conversation whose process is up on one, and a request to end a
conversation on one, answer `503 sandbox_unavailable` with a `Retry-After`
header while Managoat is in the middle of an operation on that machine. A
prompt to a conversation whose process is up, and a request to end one, wait a
few seconds for the operation first. Deleting a machine and parking an idle
one each take the machine for the length of one provider round trip. Send the
request again. When a machine is deleted, a turn still running on it is marked
interrupted: nothing on that machine can finish it. The TypeScript SDK
reports this as a not-ready error, and the boot sweep leaves the machine to the operation that holds it.

A machine that is being destroyed answers `409 sandbox_reset_pending` to a
prompt until the destroy finishes. The name is historical: it comes from a
per-sandbox reset that Managoat no longer has, and clients match on it, so it
stays. The next prompt after that builds a new machine.

Every five minutes, Managoat looks for deletions that were asked for and then
abandoned. A deletion is finished when it is fifteen minutes old and no server
holds the machine. A machine that another operation is working on is left to
that operation. The capacity reservation stays in place until the deletion
finishes.

For a manual override, an operator reaps the sandbox from the admin sandbox
list. A reap deletes the machine at the provider, then marks the row
terminated and releases its fleet slot. If the provider returns an error, the
reap still marks the row terminated, and the server log has a warning that
reads `provider destroy failed for <machine> on <provider>`. Only then does
the operator need to check the provider. Neither the `admin.sandbox.reaped`
audit event nor `sandbox.destroyed` records the error. Each hour, Managoat
deletes again any machine whose row is terminated and that the provider still
lists. Do not use a reap as a routine retry.

## Why the lifecycle belongs to the conversation

Tie the machine to the run on it, and three problems solve themselves.

Reclamation gets an owner. When the conversation is idle, the machine is
idle, and no separate record can go wrong.

Cost gets a shape that a user recognises. "This conversation cost something"
reads clearly, and "you have 14 sandboxes" does not.

Memory gets somewhere to live. The runtime keeps its session on the sandbox's
disk. To suspend and wake the machine is therefore the same act as to pause
and resume the conversation on it. Read
[About conversations](conversation.md).

A prompt to a conversation on a parked machine wakes it, and a prompt that
arrives while the machine is *being* parked is answered `503
sandbox_unavailable`: Managoat finishes the park and the retry wakes it.

**Two prompts that arrive together wake the machine once.** The second waits
for the first, and then finds a machine that is already running. If the first
takes long enough that the second gives up waiting, the second is answered
`503 sandbox_unavailable` with a `Retry-After`, and the retry lands on the
running machine. Waking a machine is compute again, so it passes the same
limit as starting one: the fleet ceiling of the provider that holds it
(`SANDBOX_FLEET_CEILING_SPRITES` or `SANDBOX_FLEET_CEILING_E2B`). A machine being woken counts against it from the
moment Managoat allows the wake, not from the moment the
provider answers.

A wake the provider refuses answers `503 sandbox_resume_failed`, and the
machine stays parked with its disk exactly as it was. Retrying is safe.

## One seam, two backends

Each backend plugs into the same seam, `Managoat.Sandbox`. The contract is
executable, and not merely described. The behaviour specifies callbacks,
capabilities and an error taxonomy. A conformance suite that each adapter must
pass covers four things. It covers replay-from-start attach, total
`write_stdin`, exactly one terminal frame for each command, and `allow: []` as
deny-all.

| Provider | What it is | Suspend |
|---|---|---|
| [Sprites](../integrations/sprites.md) | The first backend, and the instance default. | Parks on its own, scales to zero, keeps the disk. |
| [E2B](../integrations/e2b.md) | Hosted. | An explicit pause, with a snapshot of filesystem **and memory**. |

**Daytona was removed in 2026-10.** A migration moved each agent pinned to
`sandbox_provider: daytona` to the instance default, and marked each Daytona
sandbox still recorded as live as terminated. Managoat no longer reaches
Daytona, so if any of those machines still exist, delete them in Daytona's
console.

**The self-hosted runner was removed in 2026-10, too.** A migration did the
same for `sandbox_provider: runner`. Managoat no longer reaches a runner, so
stop the `fountain runner` daemon on its machine, and delete the sandbox
directories it left under its root.

## Capabilities are honest, and that has consequences

An adapter advertises only what it can do, from `:suspend`,
`:network_policy`, `:attach`, `:tty` and `:public_url`. The
lifecycle then degrades to match, and it pretends nothing.

A provider without `:suspend` **destroys on idle**. It does not fake a park. A
resume with a fresh disk would lose the agent's memory without a sound, which
is worse than an honest teardown.

So the idle timeout does not mean the same thing everywhere. On Sprites it
costs nothing. On a provider with no suspend it costs the memory the agent
works from. Read
[Sandbox lifetime and cost](../guides/operate/sandbox-lifetime.md).

Two more consequences matter.

**Only Sprites gives you a TTY.**

**A sandbox never moves.** A parked disk stays where Managoat wrote it, so a
wake never crosses providers. Change the instance default and only new
sandboxes follow it.

## Anything an agent serves can be public

A provider that gives a sandbox its own HTTP endpoint advertises
`:public_url`. Managoat sets the URL in the sandbox as `SANDBOX_URL`, so an
agent can answer when you ask where it runs.

On Sprites that endpoint asks for a platform credential by default. Managoat
opens it, because an agent that serves a page serves it to a person, and that
person holds no such credential.

**So anyone with the URL can reach what an agent serves.** Set
`config :fountain, :sprites_public_urls, false` to keep the default instead.
A sandbox then keeps its URL, and only a token holder can open it.

## Not a container you can hand us

Managoat builds no image and stores no image. A provider applies your
[environment](environment.md) as a recipe at provision time. Two conversations
from the same environment install their packages one by one, on their own
machines.

That costs provision time. It buys you no registry, no build pipeline, and no
garbage-collection problem.

## A Sprites machine that drops quiet connections

This is a known fault in the Sprites platform. Managoat cannot fix it or work
around it.

Some Sprites machines drop a network connection that is idle for about one
second. A connection that moves data without a pause is not affected. The
machine is not told the connection is gone, and neither is the other end.
The program on the machine waits for data that never comes.

We measured this on 2026-09-26 on a hosted Codex machine. We ran the same
requests through the same credential broker session on that machine, on two
other Sprites machines and on a computer outside Sprites.

| Request | Affected machine | Other machines |
|---|---|---|
| A 20 MB download | Complete | Complete |
| One byte every 0.3 seconds | Complete | Complete |
| A reply that starts after 1 second | Nothing arrives | Complete |
| One byte every 2 seconds | The first byte, then nothing | Complete |

The affected machine got worse over three hours of use. Early on, about half
of its model replies finished. By the end, none did. Nothing inside the
machine differed from the healthy ones. The network settings were the same
and it had no firewall. The drop happens outside the machine, in the Sprites
network. We do not know what starts it. The affected machine had opened
several thousand short connections through the broker when it failed. That
may be related, but we have not shown it.

**What you see.** A model streams its reply and pauses while it reasons. On
an affected machine the stream stops at the first pause. Codex prints:

```text
stream disconnected before completion: Transport error: timeout
stream disconnected before completion: Transport error: network error: error decoding response body
```

Codex retries five times, each after about 30 seconds, and then ends the turn.
The reply stops partway. A later retry can repeat text from an earlier
attempt. Other runtimes are also affected if their replies pause for a second
or more.

**What to do.** Start a new conversation, which gets a new machine. On
2026-09-26 new machines did not have the fault. An operator can also reap the
affected machine from the admin sandbox list. A conversation with a live
process on the machine is terminated. A conversation without one keeps its
transcript, and its next prompt builds a new machine, without what was on the
old disk.

Managoat does not replace an affected machine by itself. The operator of a
Managoat deployment can see affected machines on the admin page
`/admin/broker`, under Sandboxes cutting streams, as described in
[Observability](../guides/operate/observability.md#the-broker-admin-page).

## Where to go next

- [The sandbox contract](../integrations/sandbox-contract.md), the executable
  version of this page.
- [About conversations](conversation.md), whose lifecycle this one follows.
- [About workspaces](workspaces.md), a machine several conversations share.
- [Sandbox lifetime and cost](../guides/operate/sandbox-lifetime.md).
- [Add a provider](../integrations/adding-a-sandbox-provider.md), if you want
  a third.
