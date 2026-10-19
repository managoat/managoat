# `managoat acp`, the ACP agent reference

`managoat acp` is the one process that each ACP client of Managoat spawns.
[Editors](editors.md) such as Zed and [OpenClaw](openclaw.md) both speak the
[Agent Client Protocol](https://agentclientprotocol.com) to it over stdio. It
then drives a conversation in a Managoat sandbox.

Those two pages cover how to configure *the client*. This page is the
reference for the adapter itself. It says what the adapter accepts, what it
does with that, and what it deliberately ignores. The two pages then do not
each state it again.

**What it is, and is not.** It is a control surface for a conversation on your
Managoat instance. Open it, prompt it, watch it, interrupt it, reopen it
tomorrow. It reaches nothing on the machine it runs on, beyond its own stdio
and the CLI's credentials. Each path it reports is inside the sandbox.

## Invocation

```bash
managoat acp --agent <name-or-id> [--vault <name-or-id>] [--environment <name-or-id>] [--workspace <id-or-name>] [--cwd <dir>] [--permission ask] [--log-level debug]
```

| Flag | Meaning |
|---|---|
| `--agent` | **Required, in practice.** The Managoat agent that each session runs. ACP has no field for it, so you configure it for each process. Use one client entry for each agent you want to reach. |
| `--vault` | A vault that attaches to each conversation this process opens. Vault values override the agent's environment, so a secret for one entry belongs here. An identity the agent posts under is the example. Two entries on the same agent with different vaults stay apart. |
| `--environment` | Provisions each conversation from this environment, and not from the agent's own. One agent config then runs under several environments, with one entry for each. The vault still wins on a key collision. When the agent sets `allowed_environment_ids`, the environment must be on that list. |
| `--workspace` | Opens each conversation on this [workspace](../concepts/workspaces.md)'s machine, beside whatever else runs there, instead of a sandbox of its own. The workspace fixes the environment and vault, so `--environment` and `--vault` may only name its own. With a `channelId`, a session resumes only a conversation in that workspace. Conversations in one workspace can read and change each other's files. |
| `--cwd` | The directory inside the sandbox the agent runs in: `/home/sprite` or a folder under it (for a gemini agent, also under `/tmp`), or a repository's `mount_path` in the environment it runs with, or a folder under that, created if missing. It is not your editor's project directory. With `--workspace`, it gives each entry its own folder on the shared machine. |
| `--permission` | What happens before the agent runs a tool. `ask` sends the question to your client, as an approval prompt. `auto_deny` refuses. The default, `auto_allow`, runs the tool. To narrow it for one kind of tool, give `key=verdict` pairs, such as `execute=ask`. See [Permission prompts](#permission-prompts). |
| `--log-level` | The verbosity on stderr. One of `debug`, `info`, which is the default, `warn` and `error`. |
| `--profile` | Which saved CLI credentials to use. It is a global flag. |

**The credentials are the CLI's.** They come from `MANAGOAT_API_KEY` and
`MANAGOAT_BASE_URL` in the environment, or from the profile that
`managoat auth login` saved. There is no login inside the protocol.
`authenticate` verifies what the CLI already holds, and its one advertised
method says only "run `managoat auth login`".

**stdout carries the protocol and nothing else. Diagnostics go to stderr.**
Your client's agent-server log shows them, and that is the first place to look
when something is wrong.

## The protocol surface

The protocol version is **1**, and Managoat negotiates down to the client's
version when that is lower. `agentInfo` is `managoat`, with the CLI's version.

| Method | What Managoat does |
|---|---|
| `initialize` | The capability handshake. Managoat logs the client's own capabilities, which are `fs` and terminals, and uses neither. This agent works on a sandbox filesystem, and not on yours. |
| `authenticate` | Verifies the CLI's saved credentials against the instance. Managoat advertises it only when it holds none. |
| `session/new` | Resolves `--agent`, then opens a conversation. **The ACP session id *is* the conversation id**, as below. It responds with the agent's model, as the one model available. |
| `session/prompt` | Sends the turn, as text and images. It drops another block with a warning, and refuses a prompt where it can use nothing. It then streams the conversation's ACP output back as `session/update` notifications, until the turn ends. |
| `session/cancel` | Interrupts the turn that runs. |
| `session/load` | Reopens a conversation that this process did not start. It replays the stored `session/update` history **before** the response, as the spec demands. A conversation recorded before its runtime spoke ACP has no such history, so it opens empty; its transcript is in the apps. |
| `session/set_model` | Not implemented. Choose a conversation's model through the API when you create it ([Choose the model](../api.md#choose-the-model)). |
| `session/set_config_option` | Accepted, and not applied. Reasoning effort, fast mode and the runtime's other session options belong to the Managoat agent, and a conversation keeps the agent's from its launch ([Set reasoning effort and fast mode](../api.md#set-reasoning-effort-and-fast-mode)). The reply's `_meta.fountain.applied: false` says so. The push isn't refused, because some clients push their controls at every spawn and abort on an error. |
| `session/request_permission` (agent → client) | Goes to your client when the policy for that tool is `ask` ([#708](https://github.com/managoat/managoat/issues/708)). It carries the agent's own options. Your answer goes back to the agent. See [Permission prompts](#permission-prompts). |

Managoat advertises `loadSession: true`. On prompts it advertises
`image: true`, `audio: false` and `embeddedContext: false`. A client cannot
inline a local file, which would be context about a machine the agent cannot
see.

Managoat logs `cwd` and `mcpServers` on `session/new`, and ignores both. The
sandbox clones its own checkout, and a Managoat agent carries its own MCP
configuration to the sandbox. It never adds the client's.

### The session id is the conversation id

`session/new` returns the Managoat conversation id as the ACP `sessionId`
([ADR 0015](https://github.com/managoat/managoat/blob/main/decisions/0015-fountain-as-an-acp-agent.md),
[#699](https://github.com/managoat/managoat/issues/699)).

That is what makes `session/load` work across processes and across days. An
editor hands back an id from last week, and it resolves to a real
conversation. It does not resolve to a map that died with the process that
minted it. It is also why the same id appears in the web UI, in
`managoat conv`, and in the audit trail.

### What streams back

The sandbox runtime already speaks ACP to Managoat
([ADR 0014](https://github.com/managoat/managoat/blob/main/decisions/0014-agent-client-protocol.md)).
So the adapter is a proxy, and not a translator. It forwards
`agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`
and their siblings as they arrive, and rewrites the `sessionId` to yours.

Two adjustments follow, and both are about the machine boundary.

- **Managoat moves `tool_call.locations` to
  `_meta["managoat.sandboxLocations"]`.** They name files in the sandbox.
  Leave them in place, and an editor opens a path on your machine, or fails to
  open one.
- **A stop reason comes from the sandbox**, such as `end_turn`, `refusal` or
  `cancelled`. Some things have no vocabulary in the sandbox. A sandbox that
  never provisioned, one that Managoat reclaimed mid-turn, and a conversation
  that somebody terminated are the three. Managoat reports each of those as a
  JSON-RPC error, and does not dress it up as "the agent finished".

A dropped SSE connection is not a lost turn. The server closes an idle stream
after 60 s, and the adapter reconnects and continues from where it stopped.

### Conversation titles from the harness

Managoat uses the sandbox harness's standard ACP
[`session_info_update`](https://agentclientprotocol.com/protocol/v1/session-list#updating-session-metadata)
to name conversations. It makes no separate inference request for a title.
The harness can send this notification during a turn or after the prompt
response:

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "the-harness-session-id",
    "update": {
      "sessionUpdate": "session_info_update",
      "title": "Fix login redirect"
    }
  }
}
```

The title is saved on the conversation and refreshes the sidebar. A later
notification can revise a harness title; an omitted `title` leaves it alone,
and `null` clears it. Managoat redacts registered secrets before normalizing
or shortening the title. It collapses whitespace, removes NUL characters,
and limits titles to 120 characters. Complex emoji and combining characters
may shorten this further to fit storage, without splitting a character.
A blank title also clears it. A failed title update leaves the turn running.

Explicit titles, including existing titles whose origin is unknown, stay
unchanged. Renaming a conversation claims its title, even when the name is
unchanged. If a
harness supplies no title, the existing untitled display fallback applies.
Metadata arriving after a turn ends updates the title without opening a new
turn or extending a background turn's quiet timer. The notification is stored
in the transcript only while a turn is open.

For other harness-created values, ACP supports custom data in
[`_meta`](https://agentclientprotocol.com/protocol/v1/extensibility#the-_meta-field).
Managoat does not map arbitrary `_meta` values to conversation fields.

## `_meta` extensions on `session/new`

These are out-of-band fields that a chat harness sends. Managoat ignores each
other field in `_meta`.

| Field | Meaning |
|---|---|
| `channelId` | Names the external channel that this session serves. With it, `session/new` **resumes** the conversation already bound to that channel, for this user, agent and vault. That is the same conversation, the same sandbox and the same runtime session, with a fresh ACP id on the client's side. A harness that forgets its sessions on restart therefore lands back where it was ([#774](https://github.com/managoat/managoat/issues/774)). A destroyed sandbox also stops the resume. Its disk does not survive it, so Managoat opens a new conversation on a new sandbox ([#779](https://github.com/managoat/managoat/issues/779)). Without it, each `session/new` is a new conversation. |
| `freshSession` | With `channelId`, it skips the resume this one time. It unbinds the current conversation, which continues and then retires like any other idle one. It opens a new conversation, and binds the channel to that. A chat harness's "start over" command turns into this ([#788](https://github.com/managoat/managoat/pull/788)). Managoat ignores it without `channelId`. |

The same knobs exist on the API, as `channel_id` and `fresh` on
`POST /api/conversations`. Read [Conversations](../api.md#conversations).
Each session's conversation runs on a sandbox of its own, unless the process was started with `--workspace`. With it, a `channelId` resumes only a conversation in that workspace.

## `_meta` extensions on `session/prompt`

Send `_meta.clientRequestId` to name one prompt submission:

```json
{
  "sessionId": "<conversation-id>",
  "prompt": [{"type": "text", "text": "Run the approved plan."}],
  "_meta": {"clientRequestId": "plan-7-step-3"}
}
```

The bridge sends it as `client_request_id` on the prompts API route, for both
the first prompt and later prompts, including in resumed sessions. It belongs
to that submission; the bridge does not reuse it for the next prompt or derive
it from the JSON-RPC request ID. Omit it, or send null, to send no correlation
field. Other `_meta` keys are ignored.

The server validates the value: a string of 1 to 200 characters without a null
character. Managoat stores it on the resulting turn. It is not an idempotency
key. See [prompt correlation](../api.md#find-the-turn-your-prompt-opened) for
how to find that turn and the limits of the contract.

## Permission prompts

With `--permission ask`, the agent stops before it runs a tool and asks. The
request starts in the sandbox. It goes to Managoat, then to your client, as an
ACP `session/request_permission`. Your client shows its approval prompt. Your
answer goes back the same way. The tool then runs, or it does not.

Your client gets the agent's own options, and only those. Managoat adds none.
A client that answers with an option that the agent did not offer gets a
refusal, and Managoat denies the call.

**Each other outcome is also a denial.** These are the outcomes.

- Your client dismisses the prompt, or closes, or fails.
- Nobody answers before the server's timeout, which is 5 minutes.
- Another client answers first, and the first answer wins. Your client then
  sees a request that no longer waits.

A denial does not stop the turn. The agent reads that it has no permission for
that tool, and continues.

**A key matches the tool card's title first, and then ACP's kind.** The kinds
are `execute`, `edit`, `read`, `delete`, `move`, `search`, `fetch`, `think`
and `other`. Prefer a kind. The claude runtime puts the command itself in the
title, so a title matches one command and nothing else.

**A launch can only narrow what the agent permits.** A `--permission` that
makes the agent's own policy less strict gets a 422, at `session/new`, that
names the tool. To set the agent's own policy, use the API or a manifest.

## Lifecycle, sandboxes, and what survives

- **A turn ends when the conversation says so.** That is the terminal `turn`
  stage event, with its stop reason. It is not the moment the output goes
  quiet.
- **An idle sandbox suspends, and is not lost.** The next prompt resumes it. A
  sandbox that Managoat reclaimed at its maximum lifetime, or one that fails
  to reattach, comes back as an error on the turn that met it. Prompt again to
  provision a fresh one. Managoat keeps the transcript either way, and
  `session/load` replays it. The agent's own memory in the sandbox does not
  survive ([#649](https://github.com/managoat/managoat/issues/649)).
- **To close the client stops nothing.** The conversation is on the server,
  and the process is a window onto it. Reopen it with `session/load`, from one
  of the [apps](../concepts/surfaces.md#to-watch-an-agent-work-use-a-different-application),
  or with `managoat conv`.

## When something goes wrong

Start with stderr. Add `--log-level debug` when the default is not enough.
Managoat words an error for a reader inside an editor, and not for one at a
terminal.

| Message | Meaning |
|---|---|
| `no Managoat agent configured` | The entry has no `--agent`. |
| `agent "x" runs the … runtime, which does not speak ACP` | A `managoat` CLI older than this server. Servers after v0.27.0 no longer send the `acp` field that older CLIs check, so those CLIs refuse every agent. Upgrade the CLI. |
| `credentials for … were rejected` | Run `managoat auth login`. The message names the instance it tried, and that is usually the surprise. |
| `could not resolve agent "x" on …` | The wrong name, or the right name on a different instance. |
| `the sandbox never started: …` | The provision failed, and the reason belongs to the sandbox provider. |
| `could not reattach to the sandbox, prompt again to provision a fresh one` | Managoat reclaimed the sandbox. The transcript survives. |

To run the binary by hand is a fair diagnostic. It sits and waits for JSON-RPC
on stdin, which proves that the process starts and finds its credentials.

## Who spawns it

| Client | Who spawns it | Page |
|---|---|---|
| Zed and other ACP editors | The editor, from its agent-server config. | [Editors](editors.md) |
| OpenClaw, on Telegram, Discord or Slack | The `acpx` plugin on the OpenClaw host. | [OpenClaw](openclaw.md) |
