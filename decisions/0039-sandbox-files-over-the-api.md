---
type: ADR
title: "A sandbox's files and git diff over the API, and no exec"
description: "Apps that watch an agent get four read-only full-scope requests on a sandbox (listing, file, git status, git diff), redacted, confined, and never resuming a parked sandbox; a raw exec endpoint is refused."
tags: [api, sandbox, security, apps]
status: stable
adr: "0039"
adr_status: "Accepted"
date: 2026-09-02
generated: { by: claude-fable/5.1, at: 2026-09-02T02:00:00-04:00 }
verified: { by: claude-opus/5, at: 2026-09-04T12:00:00-04:00 }
---

# 0039 — A sandbox's files and git diff over the API, and no exec

**Status:** Accepted, 2026-09-02. Built: `Fountain.SandboxFiles`,
`FountainWeb.SandboxFilesController`, the four routes, and the SDK's
`sandboxFiles`, `sandboxFile`, `sandboxGitStatus` and `sandboxDiff`.
Nothing described here is unbuilt.

## Context

Two of the apps built on the API (ADR 0003, [0021](0021-oauth-for-first-party-apps.md))
asked for "sandbox exec and file APIs". Both watch an agent work, and the
transcript is not always enough: the app wants to show the file the agent
just wrote, the tree it is working in, and what changed in the repository
since the turn began.

What shapes the answer:

- **The seam has exec and no read.** `Managoat.Sandbox` ([0018](0018-sandbox-provider-abstraction.md))
  requires `exec/4`, `spawn/4` and `write_file/4` of every adapter and has
  no `read_file`, `list_dir` or download callback. Managoat reads a file out
  of a sandbox by `exec`ing a command. Exec is cheap to expose; a file API
  would need new seam work in every adapter (today `Managoat.Sandbox.Sprites`
  and `Managoat.Sandbox.E2B`).
- **Nothing under `fountain_web/` touches a sandbox.** Every side effect goes
  through `Fountain.Conversations` and its server, which is what makes audit
  ([0013](0013-audit-trail.md)) and redaction hold by construction.
- **The API key scopes that matter here are `full` and `sprite`.** (An
  admin key also carries `admin`, which only `/api/admin` checks; see
  #2660.) Everything under
  the plain `:api` pipeline is reachable with a `sprite` key, the token a
  conversation hands its own sandbox, so that the bundled `managoat` skill
  can fan out sub-agents. That fact decides the shape of anything that reads
  a disk.
- **`.env` on a sandbox disk is the identity's secrets in plaintext.** The
  callback token and the broker session token are process-only and never
  reach it (`Fountain.Conversations.Identity`).
- **Redaction is applied in one place,** `Conversations.log!/1`. Raw exec
  output and raw file bytes never pass it.
- **The broker's protection is network-shaped** ([0019](0019-egress-credential-brokerage.md)):
  a placeholder is worthless off the box because egress is pinned to the
  proxy. A read channel out of the box is one the proxy does not sit in
  front of.

A sandbox of an implicit workspace belongs to exactly one conversation
([0073](0073-one-sandbox-per-conversation.md), [0097](0097-workspaces.md)),
so the files a read returns are that conversation's alone. An explicit
workspace's machine is shared by every conversation launched into it, and
its files are all of theirs (decision 11).

## Decision

1. **Read-only requests, on the sandbox.** `GET /api/sandboxes/:id/files`
   (a directory), `/file` (one file's bytes), `/diff` (`git diff`, with
   `staged` and `ref`) and `/git-status`. They are addressed by sandbox
   because the disk is the sandbox's, not the conversation's.

2. **No exec.** The four operations are fixed scripts in
   `Fountain.SandboxFiles`; the caller chooses a path and a few flags,
   never a command. A raw exec endpoint would be a second I/O path beside
   ACP ([0014](0014-agent-client-protocol.md)) that routes around the
   governance proxy ([0016](0016-governance-as-an-acp-proxy.md)); it would
   cost provider time that no turn records; its output would never pass
   redaction; and it would reach the process environment that `Identity`
   keeps out of `.env`. A further purpose-shaped read gets the same
   treatment: a fixed script, a named endpoint, this ADR amended. `git
   status` was added that way.

3. **Full scope only.** The routes sit behind `require_full_scope`. A
   `sprite` key must never read another sandbox of the account, whose disk
   was built from a different vault; otherwise that leak would be one HTTP
   call from inside any sandbox.

4. **Confined to the home and the workspace.** A path resolves against the
   conversation's runtime working directory (`Managoat.Runtimes.ACP.cwd/1`)
   and must be `/home/sprite`, that directory, or inside one of them
   (`422 path_outside_sandbox`). Paths cross `Managoat.Sandbox.host_path/2`.
   Both git reads find their repository with `git rev-parse
   --show-toplevel`, which walks up the request path's ancestors, so the
   root it lands on is checked against the same bounds, and a root outside
   them is `not_a_repository`.

5. **Redacted like the transcript.** Every byte that leaves (file content,
   diff text, status paths, a failing command's output) passes the same
   replacement `Conversations.log!/1` applies: the values of the identity's
   environment and vault (decrypted for the request, eight bytes or longer)
   plus whatever a live `ConversationServer` registered, which covers the
   inference credential and the callback token. Without this, `.env` would
   be readable back through a third-party app holding the user's key.

6. **Never resumes what Managoat parked.** Only a `ready` row answers. A
   `suspended` row is `409 sandbox_not_ready` and stays parked. A read is
   admitted against the machine's owner: `Fountain.Machines.Reads` re-reads
   the row under the per-sandbox advisory lock a lease claim takes
   ([0058](0058-the-machine-has-one-owner.md)); a row with a transition stamp or a live
   lease is `503 sandbox_unavailable` with a `Retry-After`. An admitted read
   is recorded, before the lock is released, as an entry with a 40-second
   expiry in an ETS table owned by `Fountain.Machines.Reads.Table`. A park
   or destroy that claims the machine afterwards waits for unexpired entries
   before its provider call, and no read is admitted while that operation's
   lease is live, so a polling client cannot hold off a park. The exec runs
   in a task killed five seconds before the window ends, because the
   adapter's `:timeout` bounds only output collection. In-memory entries
   suffice because Managoat runs as one node
   ([0072](0072-fountain-runs-as-one-node.md)).

   A read on a `ready` row may still wake a machine the provider put to
   sleep by itself, and Managoat does not promise otherwise (#2395):

   | Provider | When a `ready` row's machine is asleep | What an exec does |
   |---|---|---|
   | Sprites | Routinely. A sprite scales to zero on its own when nothing runs, and Managoat's `suspend/1` is a no-op. | Wakes it; it sleeps again on its own. The exec endpoint takes only the sprite's name. |
   | E2B | When its timeout lapsed without a heartbeat (`autoPause: true`). | The adapter calls `/connect`, which resumes it with a 30-minute timeout, then runs the command. |

   Neither provider offers a run-only-if-awake exec, and a preflight probe
   would be two calls the provider can sleep between, so Managoat does not
   probe and does not describe a probe as enforcement. `GET
   /api/sandboxes/:id` and its `status` come from the database and never
   call the provider.

7. **Over `exec`, not a new callback.** The scripts run through
   `Managoat.Sandbox.exec/4` with the path as a positional parameter
   (`bash -c SCRIPT NAME ARGS…`), so a filename is data whatever it
   contains. Bytes travel base64-encoded so they survive whichever transport
   an adapter streams stdout over.

8. **Bounded.** A file read returns at most `max_bytes` (default 256 KiB,
   cap 4 MiB) and reports `size` and `truncated`; a listing or a git status
   returns at most 2,000 entries; a diff is capped the same way; every
   script has a 30-second timeout. Reads are not audited (0013 audits
   mutations).

9. **`git status`, because a diff cannot show a new file.** `git diff`
   compares tracked content, so a file the agent created and never staged
   is invisible to `/diff`; that is the common case for an app rendering
   "what changed". The route is `/git-status`, not `/status`, because a
   sandbox has a `status` field of its own. The response is one entry per
   changed path with git's two porcelain columns read separately (`index`,
   `worktree`), the rename origin, the branch, and paths relative to
   `repo_root` rather than to the sandbox home; the field is named for that
   reason. One flag, `untracked` (`normal`, `all`, `no`), is mapped by a
   `case` in the script to a fixed `--untracked-files` value; it decides
   whether a new directory is one entry or 40,000. `--no-optional-locks`
   keeps the read from taking `index.lock` and breaking the agent's own
   commit. A 1 MiB byte cap sits under the entry cap, because `-uall` on a
   large tree is read into memory before anything counts it; a record the
   cap cuts in half is dropped, and `truncated` says so.

10. **A `sprite` key cannot rewrite what a launch runs.** It may read what
    a launch is built from, and run it, but not change it. Create, update
    and delete on `/api/agents` (and the avatar writes),
    `/api/environments` and their secrets, `/api/vaults`, their secrets and
    `/api/vaults/:id/copy`, and `POST /api/apply` sit behind
    `:require_full_scope` and answer `403` with `reason:
    "insufficient_scope"` and `required_scope: "full"`. Reads of agents,
    environments, vaults and their secret metadata stay open, because the
    `managoat` skill lists `/api/agents` from inside a sandbox, and so do
    starting, prompting, streaming and ending conversations. `POST
    /api/conversations` accepts no provider, runtime, command or setup
    script, its `environment_id` and `vault_id` must be on the agent's
    allowlists, and its
    `permission_policy` may only narrow
    ([0016](0016-governance-as-an-acp-proxy.md)). So a sandbox token can
    launch only what the owner configured. A refused attempt still leaves an
    audit row with `actor: "sprite"` ([0013](0013-audit-trail.md)).

11. **Also addressed by workspace** ([0097](0097-workspaces.md), Files).
    `GET /api/workspaces/:id/files`, `/file`, `/diff` and `/git-status` are
    the same four reads of the workspace's current machine, full scope only,
    with the same admission, bounds and never-resume rule. On an explicit
    workspace's shared machine a relative path resolves from `/home/sprite`,
    and the confinement roots are `/home/sprite` and the working directory of
    every live conversation on it; redaction already covers every
    conversation on the machine. The `/api/sandboxes/:id` routes stay, and
    on such a machine read it the same way.

## Consequences

- The apps get a file tree, a file, a status and a diff through four SDK
  calls beside `sandboxes()`, and nothing they did not ask for.
- The one new attack surface is a read channel out of the sandbox, bounded
  by full scope, path confinement and redaction. It does not cover a secret
  an agent wrote to disk itself (the transcript has the same limit), and a
  brokered API's response written to a file is readable by the same user
  who could have asked the agent to print it.
- A read can wake a machine its provider put to sleep. The machine then
  runs, and the provider bills, until the provider sleeps it again (Sprites'
  own idle sleep, E2B's 30-minute `/connect` timeout) or Managoat's idle
  park comes first. A read is not turn activity, so it does not postpone the
  idle park (`SANDBOX_IDLE_TIMEOUT_MINUTES`); with the idle timeout `0`,
  nothing bounds it. That time is outside any turn, and no turn records it.
- Managoat's tests prove the lifecycle half (a `suspended` row is refused
  with no exec; the admission and drain orders). They mock `exec/4`, so the
  provider's own sleep and wake is its documented behaviour as of
  2026-10-15, not something tested here.
- The `api_spec_test` route walk and the SDK freshness check mean the routes
  cannot land undocumented.

## Alternatives considered

- **A raw `POST /api/sandboxes/:id/exec`.** Refused, for the reasons in
  decision 2. The honest version of "we need exec" is a list of the
  commands the app would run, and that list is a set of named endpoints.
- **`read_file` / `list_dir` callbacks on the seam.** The cleaner
  architecture, and the right move if a provider offers a file API
  materially cheaper than a process. Deferred: it is work in every adapter
  for no behaviour the scripts do not already deliver.
- **Conversation-scoped routes** (`/api/conversations/:id/files`). The
  disk is the sandbox's, and a conversation's own `sprite` key would reach
  the route through the plain `:api` pipeline unless it too were
  full-scope, at which point the conversation adds only a misleading name.
- **Any absolute path.** Nothing an app watching an agent needs lives
  outside the home and the workspace.
- **Waking a parked sandbox on read.** Provider time outside any turn, and
  a surprise to a user whose parked sandbox starts costing money because a
  dashboard polled it.
- **Strict no-wake against the provider's own sleep.** No provider
  operation supports it and no Managoat check can be atomic with it; it
  would mean refusing most Sprites reads outside a turn. The narrower
  promise is bounded by the idle park on default settings.
- **A flag on `/diff` for untracked files.** No combination of `staged` and
  `ref` shows a file that is in neither the index nor a commit.

## History

- 2026-09-02 — Decided and built: three read routes over `exec`, full scope, confinement, redaction, never a wake; SDK 1.15.0.
- 2026-09-04 — `/git-status` added under decision 2's procedure.
- 2026-09-18 — Reads admitted under the per-sandbox lock and excluded from a concurrent park or destroy (#1715, #2394).
- 2026-10-14 — Agent, environment, vault and apply writes moved behind full scope, closing a sandbox-token path to a shell on a self-hosted runner; reapply was gated too.
- 2026-10-14 — Credits removed (#2609), so "unmetered" reads as "unaccounted"; Daytona adapter removed (#2613).
- 2026-10-14 — Reapply removed (#2676).
- 2026-10-14 — Self-hosted runner removed ([0071](0071-hosted-sandbox-providers-only.md), #2676); its reasons here are history, its gates stay.
- 2026-10-14 — One sandbox per conversation ([0073](0073-one-sandbox-per-conversation.md), #2676).
- 2026-10-15 — Team routes and the `create-team` skill removed ([0074](0074-remove-the-team.md)).
- 2026-10-15 — Admitted reads held in ETS instead of `sandbox_reads` rows (single node); the table dropped by migration `20261017120000`.
- 2026-10-15 — "Never a wake" narrowed to what Managoat parked; a provider's own sleep may be woken by a read (#2395).
- 2026-10-17 — Context names the `admin` scope added since; the `full`/`sprite` reasoning is unchanged.
- 2026-10-18 — Amended by [0097](0097-workspaces.md) step 5c: the reads are also addressed by workspace, and on an explicit workspace's shared machine resolve from `/home/sprite` with every live conversation's working directory as a root (decision 11); "a sandbox belongs to exactly one conversation" holds for implicit workspaces only.
