---
type: ADR
title: "A sandbox's own key is confined to its conversation tree"
description: "A conversation's MANAGOAT_TOKEN reaches its own conversation and the ones it spawned, at any depth, plus read-only agents, environments, vault and secret names and the catalog; every other route refuses it, an out-of-tree conversation reads as 404, a start is always the key's child, and there is no account-wide opt-in."
tags: [security, sandbox, api]
status: stable
adr: "0096"
adr_status: "Accepted"
date: 2026-10-17
---

# 0096 — A sandbox's own key is confined to its conversation tree

**Status:** Accepted, 2026-10-17. Decided by Jake. Built (#2981). Amends
[0045](0045-sandbox-api-access.md), whose "per-conversation callback
authorization" alternative this is, [0083](0083-spawn-depth-ceiling.md),
whose sandbox starts now record their parent from the key, and the
Consequences of [0086](0086-mcp-servers-authenticated-as-the-conversation.md).

## Context

Every conversation hands its sandbox a `sprite`-scoped API key,
`MANAGOAT_TOKEN`. The key authenticates as the account, and the conversation
routes check the account, not the key. So code running in one sandbox, such
as a prompt-injected agent or a malicious package, could list every
conversation, read each one's events and stream, search every transcript,
follow the account event stream, and prompt, end, delete or start any
conversation, spending the owner's inference credentials.

0039 (amended 2026-10-14) already refuses the key every write to
configuration, and 0086 (amended for #2934) gives an `"auth": "conversation"`
MCP server a narrower key of its own. Neither narrowed the sandbox's own
key. The only mitigations were `sandbox_api_access: none` (0045) or a
dedicated account.

The bundled `managoat` skill fans work out with this key: it reads agents
and vaults, starts children, polls and streams them, prompts them, and ends
them.

## Decision

1. **The tree.** A sandbox key's tree is the conversation the key was minted
   for (`callback_api_key_id`, or `handover_callback_api_key_id` during a
   handover) and every conversation that descends from it through
   `parent_conversation_id`, at any depth. An ancestor and a sibling are
   outside it. `Conversations.in_spawn_tree?/3` decides membership, scoped
   to the account.
2. **Inside the tree** the key may show a conversation and read its `turns`,
   `events`, `stream` and turn images; send it a prompt; interrupt, wake and
   terminate it; patch labels (whose own rule still limits a sandbox to its
   own conversation); and delete it. A conversation outside the tree answers
   `404 {"error": "not_found"}`, the same body as another account's
   conversation, so an id is not confirmed to exist.
3. **Starting a child.** `POST /api/conversations` with a sandbox key always
   makes a child of the key's conversation, with `source: "agent"`. The
   `X-Managoat-Parent-Conversation-Id` header may be absent or name that
   conversation; any other value, and a key no conversation names, is
   refused with `404 parent_conversation_not_found`. A `channel_id` that
   resolves to a conversation outside the tree is `404 not_found`. So the
   tree stays closed: nothing the key starts or reaches is outside it.
4. **Outside the tree** the key may read only what spawning needs:
   `GET /api/auth/me`, `GET /api/catalog`, and `GET` on agents (with their
   versions and avatar), environments, vaults, and the secret names of an
   environment or a vault. No API returns a secret value to any key.
5. **Deny by default.** `FountainWeb.Plugs.SandboxKeyScope`, in the `:api`
   pipeline after `Audit`, is an allowlist over method and path segments.
   Every route not on it, including `/api/apply`, `/api/search`,
   `/api/events/stream`, the conversation list, a conversation's `tree`,
   `read` and `requests`, sandboxes, the audit log and any route added
   later, refuses the key with `403` `insufficient_scope` and
   `required_scope: "full"`. A refused write is still on the audit trail as
   the sandbox's. A test walks the router and fails if the set of routes
   that pass changes.
6. **Workspaces are full scope** ([0097](0097-workspaces.md), step 5). The
   key may not create, list, show or delete a workspace (the routes are not
   on the allowlist, and sit behind `:require_full_scope`), nor name a
   `workspace_id` on a start (`403 insufficient_scope`, `required_scope:
   "full"`), so a child it starts gets a sandbox of its own. The tree
   confinement holds per implicit workspace; inside a shared one, every
   process can read every conversation's key, so a key's reach there is in
   effect the union of the trees of the conversations on it, which 0097's
   one trust boundary accepts.
7. **No opt-out.** There is no `sandbox_api_access` level for account-wide
   reach. An owner who wants a sandbox to act on the whole account puts a
   full-scope key of their own in a vault or environment. `none` is
   unchanged.

## Consequences

- Code with execution in one sandbox reaches its own tree's transcripts and
  can spend inference only on children of its own conversation. It can
  still read the names, but not the values, of every vault and environment
  secret, and every agent's configuration.
- Breaking: a client inside a sandbox that used `MANAGOAT_TOKEN` to list
  conversations, search, follow the account stream, read the spawn tree,
  look at sandboxes, mark a conversation read, or reach a conversation
  outside its tree now gets 403 or 404. The TypeScript SDK's `run()` and the
  bundled skill's fan-out keep working. With this key the SDK's
  `conversations()`, `search()`, `events()`, `sandboxes()`, `sandbox()` and
  the sandbox file reads, and a conversation's `tree()` and `markRead()`,
  are refused.
- A start from a sandbox now records its parent even without the header,
  which changes `source` and the list's sub-conversation filter for those
  starts. 0083 named that as a provenance change to make on its own; this
  is it.
- The permission-answer route now refuses the key at the allowlist, with
  `insufficient_scope`, before the context's `sprite_may_not_answer` rule.
- A request on a tree route costs two indexed queries: the key's
  conversation, and a walk up from the named conversation to it.
- Unbuilt: a sandbox listing the conversations of its own tree. The
  conversation list and the `tree` route are refused rather than filtered.

## Alternatives considered

- **Remove only `/api/search` and `/api/events/stream` from the `sprite`
  scope** — the same key would still list every conversation and read each
  one's events.
- **The whole spawn tree, ancestors and siblings included** — a child could
  then read and drive its parent and every sibling's work, which is the
  reach the decision exists to take away.
- **An `api_access: account` opt-in** — a second level to reason about, for
  what a full-scope key in a vault already gives an owner who wants it.
- **403 for an out-of-tree conversation** — it would confirm the id exists
  on the account.
- **Silently re-parent a start whose header names another conversation** —
  refusing it says the request was not honoured.
- **Check the tree in each controller** — a route added later would be open
  by default.

## History

- 2026-10-17 — Decided by Jake and built (#2981).
- 2026-10-18 — Amended by [0097](0097-workspaces.md) step 5: workspaces are full scope, a start from a sandbox may not name a `workspace_id`, and the tree confinement is bounded by a shared workspace's one trust boundary (decision 6).
