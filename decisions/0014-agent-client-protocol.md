---
type: ADR
title: "Speaking the Agent Client Protocol to runtimes"
description: "ACP is the only runtime I/O path for claude, codex and gemini; Managoat.Runtimes provisions, and adapter pin bumps are gated on a live suite."
tags: [acp, runtimes]
status: stable
adr: "0014"
adr_status: "Accepted"
date: 2026-08-09
generated: { by: human:jhgaylor, at: 2026-08-22T04:44:07-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-24T00:00:00-04:00 }
---

# 0014 — Speaking the Agent Client Protocol to runtimes

**Status:** Accepted, 2026-08-09. Built: ACP is the only way Managoat speaks
to a coding agent (claude, codex, gemini) and to the `acp` runtime
([0049](0049-the-acp-runtime-runs-a-command-you-name.md)).

## Context

When this was decided, Managoat supported four coding-agent CLIs and paid for
each one twice. At spawn, `Managoat.Runtimes` was a behaviour that existed
because the CLIs disagree about argv, credentials, session resume, config
files and where skills live. At render, the conversation LiveView carried four
hand-written parsers for four proprietary line-delimited JSON dialects, so a
fifth runtime meant a fifth parser in the render path, against an undocumented
format its vendor could change in a point release.

Those parsers all reduced to a vocabulary that already has a specification.
The Agent Client Protocol (ACP, <https://agentclientprotocol.com>) is JSON-RPC
2.0 between a client (here, Managoat) and an agent (the CLI). Its
`session/update` notification carries the block kinds the parsers rebuilt by
hand: `agent_message_chunk` (text), `agent_thought_chunk` (thinking),
`tool_call` and `tool_call_update` (tool use and result, threaded on one `id`,
where three of the four dialects emitted them as unrelated events to rejoin),
plus `plan` and `available_commands_update`. The `session/new` response is the
init block; the `session/prompt` response's stop reason ends the turn.

Two things the old design could not express:

- **Every agent ran with its safety rail removed.** A headless CLI has no
  channel back to a human, so each was spawned with its vendor's bypass flag
  (`--dangerously-skip-permissions`, `--approval-mode yolo`,
  `--dangerously-bypass-approvals-and-sandbox`), and the sandbox was the only
  defence. ACP's `session/request_permission` is an agent-to-client request:
  the agent blocks and the client answers.
- **Two runtimes resumed by guessing.** Gemini's `--resume` and codex's
  `--last` re-entered "the most recent conversation in the workspace",
  correct only while one conversation ever ran there. ACP names the session:
  `session/new`, then `session/prompt`, with `session/resume` or
  `session/load` carrying the persisted id.

## Decision

ACP is Managoat's runtime I/O layer; `Managoat.Runtimes` stays the
provisioning layer. ACP has no opinion about how the agent binary, its
credentials, skills or MCP servers got into the sandbox, so `default_env/2`,
`write_config/2`, `prepare_sandbox/3` and `skills_root/0`
remain; only the argv builder (`build_command/5`, since removed from the
behaviour) and the render-path parsers were in scope. Which sandbox platform
runs the agent is a separate axis that ACP says nothing about.

This ADR is the client half of the protocol. Managoat as an ACP agent, for an
editor to drive, is [0015](0015-fountain-as-an-acp-agent.md); it builds on
this one, because once the server holds ACP blocks the editor-facing side
forwards rather than translates, and the dialects stop at the server boundary.

### Runtimes and adapters

Each runtime's mechanism and pinned version live in the table in
`Managoat.Runtimes.ACP`:

| Runtime | Mechanism | Pinned | `loadSession` | `sessionCapabilities.resume` |
|---|---|---|---|---|
| claude | adapter on the Claude Agent SDK, `claude-agent-acp` | 0.81.2 | yes | yes |
| codex | adapter on the Codex App Server, `codex-acp` | 2.2.2 | yes | yes |
| gemini | native, `gemini --acp` | the image's | yes | no |

A runtime that advertises neither capability is not convertible: it would be
resume-by-guessing plus a JSON-RPC peer. Gemini has `loadSession` only, and
its load replays the whole conversation, which the peer discards (below).
The claude adapter is not the `claude` CLI, but it reads the same skills tree
(`~/.claude/skills`, verified on a live sandbox), so the provisioning layer
did not change. The adapter is installed at provision from a pinned manifest
and symlinked into `~/.local/bin`, because the global npm `bin/` is not on the
sandbox's `PATH`. ACP v1 is what every implementation advertises and what the
peer speaks.

Gemini needs gemini-cli 0.63.0 or later. Before it, gemini's own session
store erased a session in the act of loading it
(google-gemini/gemini-cli#28775): the load built a fresh recorder on the same
id, which wrote a `$set` that replaced the session's messages. Managoat
carried a consolidation of that store after every turn as a registered quirk
(#955, #964, #975) until upstream resolved the session before building the
config (google-gemini/gemini-cli#29463). The pin Managoat installs where an
image has no CLI is 0.64.0, and both images ship a fixed release.

### The connection lives as long as the sandbox's wake

`Managoat.ACP.Peer` is a separate process from the `ConversationServer`,
monitored rather than linked, so a protocol bug fails a turn instead of taking
down the server holding a sandbox handle and a tenant's secrets. One peer
spans many turns: after a prompt response it waits idle for the next prompt
on the same session, with no second `initialize`, resume or model pin. The
server closes it only when the sandbox stops being its own: idle park, ceiling
reclaim, terminate, release, the machine going away, shutdown, or a change in
effective permission policy (`permission_policy_changed`, below).

The connection was first scoped to the turn, because ACP lets a session
outlive the connection that made it, and measured no slower than the legacy
spawn (3.7 s and 5.6 s end to end against 4.6 s for `claude --print`). It was
widened to the sandbox wake (#817) because closing at every turn end
destroyed two things measured on production on 2026-08-22: everything Claude
Code left running in the background (a `Monitor`, a background shell, a
`ScheduleWakeup`), since the adapter disposes the session on connection close;
and codex's "Allow for Session" grant, which lives in the runtime process.
ACP also delivers a background task's follow-up as an out-of-turn
`session/update`. A `session/update` with no turn open opens an autonomous
turn (`turns.origin = "autonomous"`, #1083), a real turn row so the log
budget, redaction and stage events apply, closed on the adapter's
origin-marked `usage_update` or after a quiet period.

The rule that bounds this: **no ACP state may become a reason to keep a
sandbox alive.** `Lifecycle`'s busy check reads the turn, not the connection,
so an idle peer does not defer the idle park, while a live background cycle is
a turn and does. A parked sandbox never holds a live adapter. A connection
scoped to the session, outliving the sandbox's idle window, is out of bounds.

Every deploy restarts every `ConversationServer`, while the adapter in the
sandbox keeps running with its prompt outstanding. The peer reports the
prompt's JSON-RPC id and the server persists it (`turns.acp_prompt_id`); a
reattach starts a peer with `attach: prompt_id` that resumes exactly that
request, without a handshake, answering live requests. A turn without the id
is orphaned and its adapter stopped rather than left to hang. Sprites replays
only the tail of the session, mid-line, so replayed lines are de-duplicated by
content. A background cycle in flight across a deploy is still lost: the
orphaned adapter session is reaped by the conversation's tag, never the head
of the session list. Adopting a live idle session across a deploy is not
built.

### Session continuity

The peer resumes with `session/resume` where advertised, which is specified
not to replay, and falls back to `session/load`. A load replays the
conversation, which Managoat already holds as log events, so the peer discards
updates until none has arrived for 250 ms, capped at 10 s. The window closes
on quiet rather than on the load response because gemini answers the load
first and streams the replay after it (#657); timing is the only
discriminator.

The runtime's session lives in the sandbox's filesystem, so it survives an
idle park, which keeps the disk ([0017](0017-suspend-idle-sandboxes.md)), and
does not survive a fresh sandbox. When a conversation gets one, the server
clears `runtime_session_id` and publishes a `session` stage event (`reset`,
`fresh_sandbox`), so the next turn is `session/new` rather than a resume that
fails `-32002` every time (#778). The agent's memory is lost; the
conversation keeps working and the transcript says why.

### What travels over the protocol

- stdin stays open for the connection: it carries permission answers and
  `session/cancel`. A turn ends on the prompt response or the process exit,
  whichever comes first, and the second is a no-op.
- `fs/*` and `terminal/*` are refused with JSON-RPC `-32601`. Managoat
  declares neither client capability, and silence would hang the agent.
- Image attachments are `image` content blocks in `session/prompt`.
- MCP servers are passed to `session/new` and re-sent on every resume, since
  the adapter tears a session down when its `{cwd, mcpServers}` snapshot
  changes; MCP config travels only there (#636). `env` and `headers` are
  arrays of `{name, value}`, not maps, and a stdio server carries no `type`
  key; both mistakes fail silently.
- Every ACP turn gets protocol-keyed tool spans (#637).

`log_events` has an `acp` stream holding each `session/update` as it arrived,
and `Managoat.ACP.Blocks` translates it. Only ACP events produce structured
transcript blocks and assistant text. The four legacy dialect parsers were
frozen when their runtimes converted (#642) and removed on 2026-09-13; older
conversations' rows stay available as raw `data` through
`GET /api/conversations/:id/events`, including with `blocks=true`. The CLI
interprets ACP output only; setup and provisioning diagnostics print as raw
text, stderr in red.

### Permissions

The request half is the peer; the answer comes from a policy.

**The policy.** A per-tool map of `auto_allow`, `auto_deny` or `ask`, held on
the agent as `permission_policy` and resolvable per launch. A launch may
narrow the agent's map and never widen it, which is what keeps a launch-time
override from being an escalation path. With no policy everything is
`auto_allow`. A key matches the tool call's title, then its ACP `kind`, then
`default` (#958); `kind` is the stable one, because claude and gemini title a
call with its command and codex sends no title.

**Answers.** Every answer picks from the options the agent sent, since each
adapter names them differently (claude `allow`/`reject`, codex
`allow_once`/`reject_once`, gemini `proceed_once`/`cancel`). A deny selects a
rejection option the agent offered (`Managoat.ACP.Permissions.deny_outcome/1`)
and `cancelled` when it offered none. Managoat never synthesises an option.
Adapters number requests from 0 per turn, so Managoat mints the public request
id and reads the adapter's back out of it (#957).

**The wire.** The request is a `permission_request` block on the `acp` stream;
its resolution is a stage event (`stage: "request"`, `state: "done"`, verdict
in `data`), paired on `request_id` as `tool_result` pairs with `tool_use`.
A human answers through `POST /api/conversations/{id}/requests/{request_id}`;
first answer wins.

**Lifetime.** A request lives exactly as long as its turn. It ends on an
answer; on the permission timeout (`:permission_ask_timeout_seconds`, five
minutes by default, under the idle bound), whose expiry is a deny audited
with the verdict `timeout`; or on the turn's end, which denies whatever is
still held (`turn_ended`). A blocked turn is not reported as idle so the idle
park catches it: that would lie about busyness and park a sandbox
mid-request. A request survives a deploy: it is persisted on the turn
(`turns.pending_permission`, #940) the way `acp_prompt_id` is, a reattached
peer restores it so the answer still reaches the adapter, and its timeout
re-arms from the original ask time. A request outliving its turn was built
and removed (below). An
agent that needs to wait hours on a human should end its turn and say what it
needs; the next prompt carries the answer.

**Audit.** Denials and policy changes are audited in the context, per
[0013](0013-audit-trail.md), with tool and verdict only. Allows are not: a
row per allow would make the trail a transcript. A sandbox answering its own
permission request is not permitted; it holds a `MANAGOAT_TOKEN`, and that
loop is closed by name.

**Not every tool call asks.** A request reaches Managoat only when the
adapter sends one, and the pinned adapters skip whole classes of call. The
live adapter suite measured this on 2026-10-15 under a policy that asks about
everything (#2670):

| | claude-agent-acp 0.81.2, `default` mode | codex-acp 1.10.0, `agent` mode |
|---|---|---|
| Shell write inside the workspace | asks | runs, no request |
| Shell write outside the workspace | asks | runs, no request: codex's own reviewer approves the escalation |
| Read-only shell command (`ls -a`) | runs, no request | runs, no request |

Claude also skips the request for anything its trusted allow rules or its
read-only command classifier permit, and plan mode cancels the turn
([0067](0067-read-only-turns.md)). So a `permission_policy` governs the
requests an adapter chooses to send; it does not promise every tool call is
put to it. Gemini asks per tool call (measured on 0.53, #974) and has not been
re-measured. The manual says this per runtime in
`docs/concepts/permissions.md` and `docs/catalog/runtimes/codex.md`.

**Codex runs in its asking mode under a policy that asks (#2708).** Each
codex-acp mode fixes codex's approval policy, reviewer and sandbox for every
turn, outranking `CODEX_CONFIG` and `config.toml`. In its default `agent`
mode codex's automatic reviewer decides every escalation and Managoat is
never asked. `workspace-write` (named `read-only` before codex-acp 2.0.0) has
the same `workspaceWrite` sandbox with the client as reviewer. When the
effective policy has any verdict other than `auto_allow`,
`Fountain.Conversations.CodexApproval` spawns the adapter with
`INITIAL_AGENT_MODE=workspace-write`, replacing an environment's own value,
since `agent-full-access` never asks; otherwise codex keeps `agent` or the
environment's choice. Managoat never selects the new, truly read-only
`read-only` mode, and `mode` stays hidden and refused in `session_config`
(#2675). Writes inside the workspace and read-only commands still run
unasked; what asks is what the sandbox refuses: a write outside it, network
access, and an escalation the model requests. The peer keeps the policy it
was spawned with, so an idle peer under a different effective policy is
closed before the next turn, which also makes a tightened agent policy reach
a conversation on an open connection; a peer reattached after a deploy has
an unknown mode and is respawned on codex under a policy that asks.

Codex offers `allow_once`, an always-allow option and `cancel`, but no
`decline` (agentclientprotocol/codex-acp#556). A rejection, whether a
human's, an `auto_deny` or a timeout, therefore selects `cancel`: the tool
does not run and the turn ends `cancelled`, recorded as `failed` with that
stop reason; the next prompt on the same connection runs normally. This is
accepted rather than handled, because Managoat does not invent options. When
codex offers `decline` (agentclientprotocol/codex-acp#558),
`deny_outcome/1` already picks it, since it is listed before `cancel`. The
live suite's codex `reject_stop` expectation is still `cancelled` on 2.2.2.

### The live adapter gate

What an adapter does with a permission answer, which modes it offers and
which config options it takes can change between versions with every stubbed
test passing. `apps/fountain/test/live/adapter_behaviour_live_test.exs` holds
each runtime's measured answers as data. A change to the ACP peer or the
runtimes, or any adapter pin bump, must pass it; a bump that changes an answer
fails until the PR updates the expectation and the record that cites it.
`contributing/component-libraries.md` ("The live adapter gate") has the
procedure.

## Consequences

- Managoat carries a bidirectional JSON-RPC peer with request correlation,
  agent-to-client dispatch and cancellation. A turn is a connection with
  states (prompting, awaiting a permission answer, cancelled), not a process
  watched for an exit, and its characteristic failure is a peer waiting for a
  message that never arrives. The timeouts, the reattach by prompt id and the
  orphan reaping above exist for that.
- No agent runs with a vendor bypass flag. The rail is a per-agent policy,
  bounded by what each adapter chooses to ask.
- Adapters are a supply-chain surface outside `hex.audit`, versioned
  independently of the CLIs they wrap. Both adapters changed hands within a
  month of this decision (to the `agentclientprotocol` org). They are pinned,
  installed from a manifest and gated on the live suite.
- A new runtime integrates through ACP at the sandbox boundary; nothing is
  added to the render path.
- What was given up is a small, legible spawn path: argv was trivially
  testable and failed loudly.

## Alternatives considered

- **Keep hand-writing parsers.** Correct at four runtimes forever, but it
  cannot produce a permission prompt at any price, and a vendor's point
  release becomes a rendering bug.
- **Normalise to an internal event schema without ACP.** The same render-path
  win, but strictly more work than adopting a spec the vendors target, and it
  still translates from one-way streams with no permission channel.
- **Full cutover in one change.** It would have coupled a protocol migration,
  a process-lifetime change and a reaper change across four runtimes in one
  PR. The conversion went runtime by runtime behind a per-agent flag instead.
- **Managoat as an ACP agent first.** It does nothing for the parsers or the
  permission gap, and would have meant a second copy of the parsers in Go.
  Split out as [0015](0015-fountain-as-an-acp-agent.md), sequenced after.
- **Close the connection at every turn end.** The original rule; replaced by
  the wake-scoped connection for the background-task and session-grant losses
  above.
- **Keep a request open past its turn.** Built for deterministic agents
  waiting days on a human (#1635) and removed (#2676): production had run no
  detached turn in 60 days against 35 requests answered inside a running
  turn.

## History

- 2026-08-09 — Adopt ACP as the runtime I/O layer behind gates, keeping `Managoat.Runtimes` for provisioning; adapter survey picks claude for the first runtime.
- 2026-08-10 — Claude on ACP behind a per-agent flag; live sprites show the ACP turn no slower than the legacy one, and that a session does not survive its sandbox.
- 2026-08-11 — The `session/load` replay window closes on 250 ms of quiet, capped at 10 s, because gemini replays after answering (#657); gemini held back by its session-store defect (#658, #659).
- 2026-08-13 — ACP on by default; permissions follow the conversions rather than gating them (#644). Idle sandboxes park instead of being destroyed (0017).
- 2026-08-14 — Legacy spawn path deleted for claude, codex and opencode (#671-#675); dialect parsers frozen in a separate module (#642); MCP config only in `session/new` (#636); tool spans (#637).
- 2026-08-16 — A reattach after a deploy resumes the in-flight prompt by its persisted id (`turns.acp_prompt_id`).
- 2026-08-18 — A fresh sandbox clears the runtime session and says so (#778).
- 2026-08-21 — Permission policy (#939) and the ask path (#940) built.
- 2026-08-22 — Measured live: opencode never asks and refuses a policy (#959); keys fall back from title to kind (#958); public request ids minted (#957). Gemini on ACP via the registered session-store quirk (#955, #964, #975), asks (#974), and its bypass flag and the last `build_command/5` deleted (#941).
- 2026-08-24 — Connection scoped to the sandbox wake, not the turn; autonomous turns for background cycles (#817, #1080, #1083).
- 2026-09-07 — A permission request may outlive its turn via a `waiting` stop reason (#1635).
- 2026-09-13 — Frozen stdout parsers removed; server and CLI render ACP only.
- 2026-10-12 — opencode runtime removed; an existing opencode agent stays readable but its conversations refuse to start until its runtime changes.
- 2026-10-14 — Detached permission requests removed; a request lives exactly as long as its turn (#2676).
- 2026-10-15 — Measured that adapters skip requests for whole classes of call; adapter pin bumps gated on the live suite (#2670). A policy that asks runs codex in its asking mode (#2708). codex-acp pinned at 2.2.2, where that mode is `workspace-write` (#1731). Hermes plugin removed.
- 2026-10-15 — GitHub skills switched from skills.sh to direct git fetching; `skills_sh_agent/0` was removed, and installation uses `skills_root/0` (#2838).
- 2026-10-16 — The Sprites image's own CLI runs where the image carries one at or above the pinned floor: Claude through `CLAUDE_CODE_EXECUTABLE`, codex through `CODEX_PATH` (#2904). The adapters stay pinned.
- 2026-10-17 — The same codex reuse on E2B, so a cold codex provision no longer pulls its 163 MB platform package through the broker (#2886). Claude on E2B keeps the bundled CLI.
- 2026-10-17 — Adapters install only from their verified bundles ([0092](0092-verified-acp-transport-bundles.md)): the image CLI runs on every provider, and an image without one at the floor fails to provision.
- 2026-10-17 — The unused `build_command/5` callback removed from `Managoat.Runtimes` (#2959).
- 2026-10-19 — Gemini's session-store consolidation retired: gemini-cli 0.63.0 fixed the load that erased a session, re-probed live on Sprites (0.63.0) and E2B (0.64.0) with 0.59.0 as the failing control; the installed pin moves to 0.64.0 (#2097).

## 2026-10-16: reuse the Sprites image's Claude executable

On Sprites, keep `claude-agent-acp` and its JavaScript dependencies pinned,
but use the image's Claude Code when its reported version is at least
2.1.280 (the CLI paired with the pinned SDK). Resolve its executable symlink
at installation and record that path for `CLAUDE_CODE_EXECUTABLE` in the
launcher. Skip the SDK's native optional packages, including on npm fallback.
A missing, failing, unrecognised or older image CLI retains the bundled
installation. E2B retained the bundled installation as well, until
[0092](0092-verified-acp-transport-bundles.md) made the image CLI the only one
on every provider (2026-10-17).

A fresh Sprite measured on 2026-10-16 carried CLI 2.1.296. The pinned
adapter initialized and created a session with it, including cold model
discovery. The JavaScript-only dependency install transferred 7.27 MB in
2.66 seconds; authenticated turns and persisted-session resume were not
checked in that probe.

Accept the image version's model catalog. Preserving older Haiku and Sonnet
model IDs is not a condition of reuse; older configured IDs can be rejected
by the newer CLI. This deliberately trades a fixed CLI version for avoiding
the large binary download on each fresh Sprite. The ACP adapter stays pinned.
Existing complete installations stay as they are. If a recorded image
executable disappears, the next provisioning check reinstalls with a newly
selected image executable or the bundled fallback. A binary disappearing
between provisioning and launch still fails that launch.

## 2026-10-16: the same reuse for codex, through `CODEX_PATH`

Extend that decision to codex on Sprites, on the same terms and with the same
mechanism: keep `codex-acp` and its JavaScript dependencies pinned, but run
the image's `codex` when its reported version is at least 0.160.1 — the CLI
`@openai/codex` is pinned at — and skip the platform packages the bundled one
occupies (`@openai/codex-<platform>`, optional dependencies of the retained
JavaScript `@openai/codex`), on the manifest path and on npm fallback. The
executable symlink is resolved at installation and recorded for `CODEX_PATH`
in the launcher. A missing, failing, unrecognised or older image CLI retains
the bundled installation, as does E2B/Loam, whose floor is not separately
validated. (Superseded 2026-10-17 by [0092](0092-verified-acp-transport-bundles.md):
the bundled CLI is gone, and every provider runs the image CLI or fails.)

`CODEX_PATH` is the counterpart of `CLAUDE_CODE_EXECUTABLE` rather than an
analogue: `codex-acp` 2.2.2's `startCodexConnection` spawns
`$CODEX_PATH app-server` when the variable is set and
`@openai/codex/bin/codex.js` on `process.execPath` when it is not, and its
supervisor respawns on the same path. So one variable moves which binary runs
and nothing else.

Measured on 2026-10-16, on an 8-vCPU Sprite carrying `codex-cli 0.162.1`
against the pinned 0.160.1, both of them `x86_64-unknown-linux-musl`
static-pie builds of the same standalone layout. Driving the pinned adapter
over stdio the way `Managoat.ACP.Peer` does, the image binary and the bundled
one answered `initialize` identically where Managoat reads it (`loadSession`,
`sessionCapabilities.resume`, `additionalDirectories`, the `api-key` method),
offered the same four modes with the same default and the same five session
config options, and read the same `auth.json` as `api_key`. Against a mock
Responses endpoint, a turn, a `session/resume` carrying the previous turn's
context into a fresh process, and a `session/load` replaying it all completed
with the same stop reason and the same `usage` shape. Running the generated
installer for real: 24 attempts and 2,339,195 bytes with reuse against 25 and
165,634,009 without, a 15 MB installed tree against 462 MB, and 1.350–1.376 s
against 3.244–3.437 s over three reps each.

That is a local measurement on one sandbox, not a production replication, and
no production saving is claimed from it. The live adapter suite runs on E2B,
so it exercises the bundled path and not this one; the first production
evidence is `fountain.adapter_install` for Codex/Sprites after a release.
Investigated in #2904.

## 2026-10-17: codex reuse on E2B too

Extend the codex reuse above to E2B, on the same terms: the same floor
(0.160.1), the same probe, the same skipped platform packages and the same
bundled fallback. Claude on E2B keeps its bundled installation; its native
package is small, and nothing here measured it.

The reason is the broker's bandwidth. The codex platform package is 163 MB,
and every byte a sandbox downloads crosses the broker. [#2886](https://github.com/managoat/managoat/issues/2886)
measured that archive at 6.0 s from a home broker to E2B. With the broker back
at home, an image codex removes that download from every cold codex
provision on E2B, as it already has on Sprites.

The floor check is what makes this safe for any E2B template. On 2026-10-17
the `fountain` template that managoat.com runs (loam's
`loam-e2b-fountain@sha256:8e47934b…`) carried `codex-cli 0.162.1`, installed
by npm under `~/.npm-global`, so the resolved executable is the npm
JavaScript wrapper: the same shape the Sprites live gate accepted. A template
without codex, or with one below the floor, installs the bundled CLI exactly
as before. The reference `images/e2b/e2b.Dockerfile` installs a floating
`@openai/codex` too.


Superseded in part the same day by [0092](0092-verified-acp-transport-bundles.md):
the bundled CLI is gone, Claude on E2B runs the image CLI too, and a template
without a CLI at the floor fails to provision that runtime instead of
installing a bundled one.
