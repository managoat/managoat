---
type: ADR
title: "Opt out of sandbox Managoat API credentials"
description: "An immutable conversation option omits Managoat callback credentials from the sandbox for untrusted host-managed work."
tags: [security, sandbox, api]
status: stable
adr: "0045"
adr_status: "Accepted"
date: 2026-09-05
generated: { by: human:jhgaylor, at: 2026-09-05T23:00:00-04:00 }
verified: { by: claude-code/opus-5, at: 2026-10-13T00:00:00-04:00 }
stale_after: 2027-01-13
---

# 0045 — Opt out of sandbox Managoat API credentials

**Status:** Accepted, 2026-09-05. Built (d4fb0eb8): `sandbox_api_access` is a
conversation option (`owner` or `none`) and `GET /api/catalog` lists it.

## Context

A host application can process several repositories under one Managoat
account. The sandbox callback key Managoat generates authenticates as the
account with `sprite` scope, and the conversation APIs enforce account
ownership, not the identity of the conversation that received the key. A
separate machine for each repository therefore does not, by itself, separate
their API authority. (Since [0096](0096-sandbox-key-confined-to-its-conversation-tree.md)
the key reaches only its own conversation tree and the read-only inputs to
spawn.)

A host such as Review Loop needs workers that inspect and fix untrusted PR
content while the host owns policy enforcement, GitHub writes and Managoat
orchestration. Those workers return files and need no Managoat callback
tools.

## Decision

Conversation creation accepts an immutable `sandbox_api_access`. `owner`, the
default, keeps the callback credential; `none` never mints one. The
callback-key path honors the option on initial provision, wake and
reattachment. The conversation response records it and the catalog
advertises the supported values. A channel resume that asks for a different
setting is refused, so a credential cannot be injected later.

Every conversation launched without a `workspace_id` has a sandbox of its own
([0073](0073-one-sandbox-per-conversation.md), an implicit workspace in
[0097](0097-workspaces.md)), so a `none` conversation can never inherit a
credential from another conversation's machine. `none` is a claim about a
machine, so it exists only there: a launch naming a `workspace_id` with
`none` is refused with `422 invalid_sandbox_api_access`. In a shared
workspace this option's guarantees are bounded by 0097's one trust
boundary: every conversation there can read the others' credentials.

## Consequences

The host keeps its account API key and can send prompts and retrieve events
and files. The worker loses the Managoat MCP tools and connections that need
the callback credential. Model inference credentials are a separate concern.

This is not a credential scrubber or network isolation. An operator can still
supply credentials through an environment, vault or custom MCP configuration.
A host processing mutually untrusted repositories must use a dedicated
account containing only `none` workers and keep full account keys outside
them. Live provider and application acceptance tests remain release work.

## Alternatives considered

- Separate machines alone leave account-scoped callback API authority intact.
- Revoking or removing credentials after launch leaves a provisioning race and
  does not establish behavior on wake or reattachment.
- Per-conversation callback authorization could keep selected worker tools,
  but needs its own authorization design across the callback API surfaces.
  Built since as [0096](0096-sandbox-key-confined-to-its-conversation-tree.md):
  the key is confined to its conversation tree. `none` still gives a worker
  no key at all.
- One account per repository changes account lifecycle; it does not give a
  worker without host API authority within one account.

## History

- 2026-09-05 — Decided and built: `none` omits the callback credential and requires a fresh ephemeral sandbox, refusing an existing-machine attach and later sharing (d4fb0eb8).
- 2026-10-15 — Every sandbox is a conversation's own (0073), so the fresh-sandbox requirement and its attach and sharing refusals no longer distinguish `none`; the channel-resume refusal stands.
- 2026-10-17 — The `owner` key is confined to its conversation tree and the read-only spawn inputs, with no account-wide level ([0096](0096-sandbox-key-confined-to-its-conversation-tree.md), #2981).
- 2026-10-18 — Workspaces ([0097](0097-workspaces.md), step 5): `none` is refused with a `workspace_id` (`422 invalid_sandbox_api_access`) and holds per implicit workspace; in a shared one the guarantee is bounded by 0097's one trust boundary.
