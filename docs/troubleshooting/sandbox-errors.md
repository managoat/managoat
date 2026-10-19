# Sandbox errors

This guide shows you how to read a failure to provision, and what the retries
already tried for you.

The examples below use the Sprites path, which is the default. The shape is
the same on the other providers, because each adapter normalizes the
provider's errors into one taxonomy. Read
[the sandbox contract](../integrations/sandbox-contract.md).

## What the retries already cover

Managoat tries a transient failure on the provision path up to three times.
That is the first call and two retries, with exponential backoff. Transient
means a 5xx, a 429 or a timeout. `SPRITES_TIMEOUT_MS` bounds each call, and
the default is 30s.

You see a failure only after all three attempts fail.

## What a 4xx means

Managoat does **not** retry these, and that is deliberate.

- **401 or 403.** The provider token is invalid, revoked or absent. Check this
  first. It fails each conversation while everything else looks healthy.
- **409 on create.** Managoat handles this. It adopts the sandbox that already
  exists, so you never see the error.

## During a provider outage

A new conversation fails, and so does a wake. A fresh provision sets the
conversation to `failed`. A wake leaves it resumable for later.

Sign-in, dashboards, configuration and past logs all still work.

The readiness probe deliberately leaves the sandbox provider out. A third
party's uptime does not belong on the request path, so do not expect a pod to
go NotReady over it.

If you scrape metrics, a failure to provision shows as
`fountain_stage_count{stage="provision", status="failed"}`. A success shows as
`status="done"`.

## A full fleet, and not an outage

When the deployment runs as many live sandboxes on a provider as that
provider's ceiling allows (`SANDBOX_FLEET_CEILING_SPRITES` or
`SANDBOX_FLEET_CEILING_E2B`, each 20 by default), a start on that provider gets
`503 fleet_full` while the provider is healthy. Each provider is counted on its
own. A
crashed provision leaves a row that counts until the reaper releases it, each
hour at :07. An admin can release it now with
`POST /api/admin/sandboxes/:id/reap`, or raise the ceiling if the provider
plan allows more. Read
[A conversation is stuck or failed](conversation-stuck-or-failed.md) and
[Admin](../api.md#admin).

## A workspace that failed to set up

A [workspace](../concepts/workspaces.md) runs its environment's packages,
repositories and setup script once, when it is created, with no conversation.
So there is no transcript to read: the workspace's own `status` is `failed`
and its `error` names the failing step and the end of what it printed,
redacted. `managoat workspace show <name>` prints it, and
`managoat workspace create --wait` exits with it.

Nothing retries that setup on its own. The next prompt into any conversation
in the workspace runs it again, and fails with it if it fails again. To change
what failed, fix the environment and create a new workspace: a workspace's
environment is fixed for its life.

A workspace whose machine the provider lost keeps its conversations. The next
prompt into any of them builds a new machine from the environment, and every
conversation in the workspace moves to it, without its runtime session or
anything on the old disk.

## Related

- [A conversation is stuck or failed](conversation-stuck-or-failed.md).
- [The sandbox contract](../integrations/sandbox-contract.md), for the shared
  error taxonomy.
- [Observability](../guides/operate/observability.md), for the alert
  on a failure to provision.
