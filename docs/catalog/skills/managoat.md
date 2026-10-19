# managoat

> Lets an agent start more Managoat conversations from inside its own sandbox,
> and stream them.

## Summary

| | |
|---|---|
| Bundled | Yes, in each sandbox. |
| Declared by | Nobody. Managoat always adds it. |
| Source | `apps/fountain/priv/sprite_skills/managoat/SKILL.md` |
| Reads | `MANAGOAT_BASE_URL`, `MANAGOAT_TOKEN`, `MANAGOAT_CONVERSATION_ID`, `MANAGOAT_SANDBOX_ID` |
| Was called | `fountain`, before the project was renamed. A sandbox also still gets the old `FOUNTAIN_*` variables, for a while. |

## What it gives the agent

Managoat's own API, from the inside. An agent that has it can fan work out
across other agents, then collect the answers.

The skill writes two patterns out. It can fan out N conversations in parallel
and gather their results. It can also drive one sub-conversation over several
turns.

That is what makes "delegate to another agent" work when a user asks for it.

## The credential it uses

`MANAGOAT_TOKEN` is a **key for one conversation, confined to that
conversation and the ones it starts**. It is not a long-lived admin token.

Managoat rotates it at each fresh provision and at each reattach, such as
after a deploy or a BEAM restart, and revokes the previous value. A request
that returns 401 with `"reason": "api_key_revoked"` means the agent cached a
stale copy. The agent must read the variable from its environment again.

## Provenance comes for free

`MANAGOAT_CONVERSATION_ID` is always in the sandbox's environment. A
`POST /api/conversations` made with `MANAGOAT_TOKEN` always records this
conversation as the parent, with or without
`X-Managoat-Parent-Conversation-Id: $MANAGOAT_CONVERSATION_ID`, which the skill
still sends. A header naming any other conversation is refused. An operator
can then rebuild the whole spawn chain.

## Each child gets its own machine

Every child conversation gets a sandbox of its own, even when its parent runs
in a workspace, so it never shares the parent's disk. The skill tells the agent to pass what
the child needs in the prompt instead. `MANAGOAT_SANDBOX_ID` is still set, as
the id of the sandbox the agent runs on, but there is no attaching to it. See
[Sandboxes](../../concepts/sandboxes.md#one-machine-per-conversation).

`GET /api/sandboxes` lists the machines the token's owner has, with the
conversation on each. Read [Sandboxes](../../api.md#sandboxes) and
[Conversations](../../api.md#conversations) for the fields.

## Limits

**A spawned agent has the same skill.** Managoat caps how deep the chain goes
at `CONVERSATION_MAX_DEPTH` (default 5): a start past it gets
`422 conversation_depth_exceeded` ([Spawn depth](../../api.md#spawn-depth)).
Nothing caps fan-out, one agent starting many siblings, so a runaway fan-out
is still a real way to spend money.

**Each conversation is a real sandbox.** The skill says plainly that an
orphaned conversation runs until the idle timeout, and that the agent must
terminate it without delay. Read
[Sandbox lifetime and cost](../../guides/operate/sandbox-lifetime.md).

**The sandbox must reach your instance.** `MANAGOAT_BASE_URL` is the
instance's [`PUBLIC_URL`](../../configuration.md), and the call comes from the
sandbox's provider, not from your machine. A `localhost` URL reaches nothing.
On a local instance, put a tunnel such as
[cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
or [ngrok](https://ngrok.com) in front of it and set `PUBLIC_URL` to the
tunnel's URL. A `limited` environment must also allow that host.

**The token reaches its own tree.** `MANAGOAT_TOKEN` has `sprite` scope. It
can read the owner's agents, environments and vaults, but not change them. It
can start conversations, which are always children of its own, and prompt,
stream, end and delete its own conversation and the ones it started, at any
depth. Any other conversation reads as 404. It cannot list or search the
account's conversations, follow the account event stream, or apply a
manifest. Read
[what a sandbox credential can do](../../api.md#what-a-sandbox-credential-can-do) for the full list.

**The bare `/conversations` path returns 404.** The API is under `/api`.

## Related

- [API reference](../../api.md), the same surface from outside.
- [Skills](index.md).
- [About conversations](../../concepts/conversation.md).
