# @managoat/sdk

Give an agent a computer, your repos and your credentials — in one call.

```ts
import { Managoat } from "@managoat/sdk";

const managoat = new Managoat();

const run = await managoat.run("Upgrade us to Phoenix 1.8 and open a PR", {
  agent: "reposage",
  vault: "github-bot",   // the token lands in the sandbox, never in the prompt
});

console.log(run.text);   // what the agent said
console.log(run.url);    // where a human can watch it happen
```

That is the whole thing. The agent ran on a real machine with your repository
cloned and your GitHub token attached at spawn time, and the machine is still
there when you want to ask it something else.

## Why not just call a model?

A model API takes a prompt and returns tokens. To make it do work you supply
the computer, the checkout, the tools and the secrets — and you keep supplying
them, on every call, because nothing persists between them.

Managoat's unit is not a message. It is **a sandbox with an agent in it**:

| | model API | `managoat.run()` |
|---|---|---|
| where it runs | your process | an isolated sandbox, provisioned per run |
| your repo | you paste it in | already cloned, from the **environment** |
| your secrets | in the prompt, or in your process | attached at spawn from a **vault**, never in the transcript |
| the next question | resend the whole context | `resume(id).send("...")` — same machine, same session |
| watching it | your logs | `run.url`, a live transcript |

`vault` is the argument to look at. Its values are decrypted into the sandbox's
environment when the sandbox spawns; they are never part of the prompt, never
in the model's context, and never in the log feed this SDK reads. Swapping
`vault: "github-bot"` for `vault: "github-readonly"` changes what the agent can
do without changing a word of the task.

There is a second layer under that, and it is worth knowing about because it
changes what you can safely let an agent do: Managoat redacts every value of 8
bytes or more that it placed in the sandbox's environment out of the
conversation's output, on the single write path every log event goes through.
An `env`, a `set -x`, a `cat .env`, or an agent simply asked to print its token
persists as `[REDACTED]`. The secret reaches the process that needs it and not
the transcript, the database, or this SDK.

## What it replaces

Every integration that ever talked to Managoat wrote the same wrapper first —
open a conversation, send the prompt, follow the log feed, decide when the turn
is over, glue the text back together. This is that wrapper, once:

<details>
<summary>The same run, by hand</summary>

```bash
# 1. find the agent, the vault, the environment (three listings, by name)
curl -sH "$AUTH" $BASE/api/agents | jq -r '.data[] | select(.name=="reposage") | .id'
curl -sH "$AUTH" $BASE/api/vaults | jq -r '.data[] | select(.name=="github-bot") | .id'

# 2. open the conversation
CONV=$(curl -sH "$AUTH" -H 'Content-Type: application/json' \
  -d '{"agent_id":"...","vault_id":"...","prompt":"Upgrade us to Phoenix 1.8"}' \
  $BASE/api/conversations | jq -r .data.id)

# 3. follow the feed — and now the real work starts:
#    - page /events?blocks=true&after=N until has_more is false
#    - keep only events whose turn_id is *your* turn's
#    - keep only `text` blocks; `tool_use` is not the answer, `thinking` is not either
#    - join ACP chunks without an added separator,
#      and start a new paragraph after any tool call
#    - stop on stage/turn/done — or failed, or interrupted
#    - and when the connection drops mid-turn, resume from the last event id
#      or you will either miss output or replay it twice
curl -sH "$AUTH" "$BASE/api/conversations/$CONV/stream?blocks=true" | ...
```

</details>

Those rules are not incidental complexity you could skip — get the paragraph
rule wrong and every transcript reads as one run-on sentence; get the cursor
wrong and a deploy mid-turn silently drops the answer. They are in here, with
tests.

## Install

```bash
npm install @managoat/sdk
```

Node 20.19+ (native `fetch` and ESM). No runtime dependencies.

Pin a major. The REST API is not additive: a Managoat release can remove an
endpoint, and the SDK follows with a major version that names that release.
An older major is tested against no newer server and has no support window.
The policy is at the top of [CHANGELOG.md](CHANGELOG.md).

## Credentials

`new Managoat()` resolves the same way the `managoat` CLI does, so a script
inherits whatever already works in your terminal:

```
apiKey:  option → MANAGOAT_API_KEY → MANAGOAT_TOKEN → ~/.managoat/credentials
baseUrl: option → MANAGOAT_BASE_URL → ~/.managoat/credentials → hosted
```

```ts
new Managoat({ apiKey: process.env.MANAGOAT_API_KEY, baseUrl: "https://fountain.internal" });
new Managoat({ profile: "work" });   // a profile from ~/.managoat/credentials
```

`MANAGOAT_TOKEN` is what a Managoat sandbox exports for the agent running
inside it. An agent that imports this SDK therefore delegates with the token it
already has, and the conversations it starts are recorded as its children — no
extra configuration to fan work out.

## Waiting, or not

`run()` starts the work and hands back a handle. What you do with the handle
decides how much of the run you see; there is no second request behind any of
these.

```ts
// await it — the finished answer
const result = await managoat.run(prompt, { agent: "reposage" });

// stream the words
const run = managoat.run(prompt, { agent: "reposage" });
for await (const chunk of run.textStream) process.stdout.write(chunk);
const result = await run;                      // same run, now finished

// or watch everything: tools, thinking, lifecycle
for await (const event of run) {
  if (event.type === "tool") console.log("→", event.name);
  if (event.type === "text") process.stdout.write(event.text);
}

// or don't wait at all — fan out, collect later
const runs = agents.map((agent) => managoat.run(prompt, { agent }));
const results = await Promise.all(runs);
```

A `RunResult` is:

```ts
{
  conversationId: string;   // keep it — the sandbox is still there
  url: string;              // where a human watches
  turnNumber: number;
  text: string;             // the answer, tool noise removed
  toolsUsed: string[];
  state: "done" | "failed" | "interrupted" | "timeout";
  exitCode: number | null;
  reason: string | null;    // stop_reason, or why it failed
  status: string | null;    // the conversation's status
}
```

A turn that **fails** is a result, not an exception — the agent ran and has
something to say about it. Check `state`. Only a transport failure, a rejected
request or a timeout throws.

## When the agent asks first

An agent whose `permission_policy` has an `ask` entry stops before the tool
call and waits to be told. Nothing else in the turn moves until it is answered,
and an unanswered request is denied when it expires — so an `ask` agent driven
by a caller that ignores these finishes having quietly skipped the work.

```ts
for await (const event of run) {
  if (event.type !== "permission") continue;

  console.log(event.request.summary);          // "Run rm -rf build"
  const allow = event.request.options.find((o) => o.kind === "allow_once");
  await run.answer(event.request.requestId, allow!.optionId);
}
```

`options` is whatever the agent offered, in its order; `kind` is the part worth
branching on (`allow_once`, `allow_always`, `reject_once`, `reject_always`).
Sending an id the agent did not offer is a `ValidationError`, not a forwarded
answer. `resume(id).answer(...)` is the same call from a process that is not
the one following the turn.

The default policy is `auto_allow` and never asks, so this is opt-in per agent.

## Defining what you run

`run()` names an agent; this is where the agent comes from. The whole
vocabulary fits on one screen:

```ts
const environment = await managoat.environments.create({
  name: "fountain-ci",
  packages: { apt: ["ripgrep"] },
  env_vars: { MIX_ENV: "test" },
  repositories: [
    { url: "https://github.com/managoat/managoat", mount_path: "/work/fountain" },
  ],
  setup_script: "cd /work/fountain && mix deps.get",
  networking_type: "limited",
  networking_config: { allowed_hosts: ["github.com", "hex.pm", "api.anthropic.com"] },
});

const vault = await managoat.vaults.create({ name: "github-bot" });
await managoat.vaults.secrets.set("github-bot", "GITHUB_TOKEN", process.env.GITHUB_TOKEN!);

const agent = await managoat.agents.create({
  name: "reposage",
  runtime: "claude",
  model: "anthropic/claude-sonnet-5",
  system: "You are a careful reader of other people's code.",
  environment_id: environment.id,
  skills: [
    { source: "obra/superpowers", ref: "v2.1.0" },
    { name: "house-style", content: "# House style\n\nPrefer small diffs." },
  ],
  mcp_servers: { linear: { command: "npx", args: ["-y", "linear-mcp"] } },
  allowed_vault_ids: [vault.id],   // this agent may attach that vault, and no other
});

await managoat.run("Find every N+1 query and open a PR", {
  agent: "reposage",
  vault: "github-bot",
});
```

`agents`, `environments` and `vaults` all have the same five verbs — `list`,
`get`, `create`, `update`, `delete` — and take a name or an id:

```ts
await managoat.agents.update("reposage", { model: "anthropic/claude-opus-5" });
await managoat.environments.secrets.set("fountain-ci", "HEX_API_KEY", "…");
await managoat.vaults.secrets.list("github-bot");   // keys only — never values
await managoat.vaults.secrets.delete("github-bot", "GITHUB_USER");
```

Secret values are write-only. `list` returns keys and nothing else: the SDK can
put a credential into a sandbox and cannot read it back out.

An MCP server that wants OAuth is connected once, in a browser, and then named
by the agents that use it. The token never leaves the server:

```ts
const { connection, authorize_url } = await managoat.connections.create({
  url: "https://mcp.linear.app/mcp",
});
console.log("Open", authorize_url); // signed in to Managoat, within ten minutes

await managoat.agents.update("reposage", {
  mcp_servers: {
    linear: { type: "http", url: "https://mcp.linear.app/mcp", auth: { connection: connection.id } },
  },
});
```

**Why `environment_id` and not `environmentId`.** Resource payloads use the
API's own key names, so one definition reads identically in the SDK, in the
REST API and in a `managoat.yml` manifest. Options that control the SDK's own
behaviour — `timeoutMs`, `signal` — are camelCase, because those are not data.

## A conversation that lasts

A thread you keep messaging is a conversation you keep. Hold on to its id and
`resume(id).send(...)`, or bind it to a channel name of your own and let the
server find it again:

```ts
// Same channel, agent and vault: continues the conversation instead of opening one.
const reply = await managoat.run("Any disks over 80%?", {
  agent: "watchtower",
  channelId: "ops:watchtower",
});
console.log(reply.text);

for await (const event of managoat.events({ streams: ["stage"] })) {
  if (event.stage === "turn" && event.state === "done") refreshList();
}
```

`managoat.events()` is every conversation the caller owns on one connection.
Stream attachment tolerates up to 180 seconds of continuous unavailability.
Configure `recoveryTimeoutMs` on a stream, or `recovery.recoveryTimeoutMs` on
`run`, `runRequest`, and `send`. `onReconnect` in the same options reports
`attempt`, `after` (the cursor), and `delayMs`. Cancellation and an overall run
timeout still stop waiting. Create and prompt POSTs are never automatically
replayed; a lost response needs inspection before another submission.

An accepted prompt that never reaches admission returns a failed run with its
reason and optional `retryable` indication, even if the conversation stays
promptable. After a deployment this can be `wake/failed: deployment_interrupted`.

It reconnects from its last event id on its own, and carries server-parsed
`blocks` like every other feed, so one connection is enough to render a list
and its threads. Managoat runs no schedules: an app that wants a routine runs
its own timer and sends the prompt.

Opening a thread is two calls, and every app wrote both by hand first:

```ts
const conversation = managoat.resume(id);
const events = await conversation.history({ streams: ["acp", "stage"] });  // paged to the end
await conversation.markRead();
```

To render both sides of the thread, ask for the prompts too. Each turn's
`turn`/`started` stage event then carries one `prompt` block with the prompt
that opened it, apart from the agent's `text`:

```ts
const transcript = await conversation.history({ streams: ["acp", "stage"], prompts: true });
```

Autonomous turns get no prompt block: nobody typed them. The prompt rides a
`stage` event, so `streams: ["acp"]` drops it; include `"stage"` when you
filter streams. `history()` sends the filter you give it and never widens it.
`eventPage(after, limit, { prompts: true })` takes the same flag. Run
following and the SSE streams do not carry prompts.

## One machine, several agents

Every run gets a machine of its own unless you give it a workspace: a
machine you keep, set up once from an environment, that any number of runs
share, each in its own folder.

```ts
const env = await managoat.environments.get("app");
const ws = await managoat.workspaces.create({ name: "app-box", environment_id: env.id });
await managoat.workspaces.waitForReady(ws.id);   // throws WorkspaceFailedError on a failed setup

await Promise.all([
  managoat.run("Add a dark mode toggle", { agent: "web-dev", workspace: ws.id, cwd: "/home/sprite/app/web" }),
  managoat.run("Add a theme endpoint", { agent: "api-dev", workspace: ws.id, cwd: "/home/sprite/app/api" }),
]);

await managoat.workspaces.gitStatus(ws.id, { path: "/home/sprite/app" });
await managoat.workspaces.delete(ws.id);   // ends its conversations and its machine
```

Runs in one workspace run as one user on one disk, so they can read and
change each other's files and tokens. Leave `workspace` out for isolation. A
workspace's machine has no lifetime limit: delete the ones you are done with.

## Errors

Branch on `code`, not status — `conversation_busy` is a 400, `provisioning`
and `fleet_full` are 503s:

```ts
if (error instanceof ConversationBusyError) …   // the turn in flight must finish
if (error instanceof NotReadyError) …           // error.retryAfter, from the server
if (error instanceof ValidationError) …         // error.fieldErrors
```

Every error carries `status`, `code`, `body`, `retryAfter` and `retryable`.

| class | when |
|---|---|
| `AuthError` | 401, or no key configured at all |
| `NotFoundError` | 404 — wrong id, or it belongs to another account |
| `ValidationError` | 422 — read `fieldErrors` |
| `RateLimitError` | 429 |
| `ConversationBusyError` | the agent is still on the previous prompt |
| `NotReadyError` | the sandbox is still coming up, or every sandbox slot is in use (`fleet_full`) — retry after `retryAfter` |
| `TimeoutError` | the SDK stopped waiting — carries `conversationId` and `partialText` |
| `ResolutionError` | a name matched no agent/vault/environment, or matched several |
| `ConnectionError` | the request never reached Managoat — in a browser, usually CORS |

A `ResolutionError` names what the account actually has, so a typo is a
one-line fix rather than a trip to the console.

## In a browser

The default entry imports no Node built-in, so it bundles as-is; the
credentials-file reader lives behind the `node` export condition.

```ts
const managoat = new Managoat({ baseUrl, apiKey });   // from your own settings UI
```

Your origin has to be in the server's `API_CORS_ORIGINS`, or every call fails
before it starts — `ConnectionError` says so, because "Failed to fetch" has
sent more than one person hunting through their own code.

## Generated underneath

`src/generated/openapi.ts` is produced from the same OpenAPI document the
server serves, and CI regenerates it and fails on a diff — so the types cannot
drift from the API. `import type { components, paths } from "@managoat/sdk"` for
the raw shapes. What is hand-written is what a spec cannot express: that many
log events fold into one turn, and which of 85 paths are worth a verb.

## Follow-ups

```ts
const first = await managoat.run("Find every N+1 query in this repo", { agent: "reposage" });

const second = await managoat.resume(first.conversationId).send("Fix the worst three.");
```

The second turn costs one prompt. The sandbox is the same machine, the checkout
is where the first turn left it, and the agent's session still holds everything
it learned — this is the part a stateless API cannot do at any price.

## Timeouts and cancellation

By default `run()` waits as long as the turn takes; agent work legitimately
runs for hours.

```ts
try {
  await managoat.run(prompt, { agent: "reposage", timeoutMs: 5 * 60_000 });
} catch (error) {
  if (error instanceof TimeoutError) {
    // The turn did not stop — only the waiting did.
    console.log(error.partialText);
    const rest = await managoat.resume(error.conversationId).send("status?");
  }
}
```

- `timeoutMs` — stop waiting, throw `TimeoutError`. The agent keeps working.
- `signal` — an `AbortSignal` that stops the waiting, same deal.
- `run.interrupt()` — ask the agent to stop the turn. The sandbox stays up.
- `run.terminate()` — tear the sandbox down. Nothing resumes after this.

## The rest of the API

The verbs above are the ones worth wrapping. Everything else Managoat exposes —
audit, API keys, conversation trees, search, sandbox files
and images — is one call away, with the same auth and error mapping:

```ts
await managoat.request("GET", "/api/audit", { query: { limit: 50 } });
await managoat.request("POST", "/api/vaults", { body: { name: "staging" } });
```

`GET /api/openapi.json` is the generated, always-current spec for those.

## Names, not ids

`agent`, `vault` and `environment` all take a name or an id. Names resolve
against the account (exact match first, then a unique prefix) and the listings
are memoized per client. A UUID in a script tells the next reader nothing;
`vault: "github-bot"` tells them everything.

## Development

```bash
npm install
npm test          # node --test, against an in-process fake Managoat
npm run typecheck
npm run build
```

The tests run a fake Managoat over real HTTP and real SSE, including the parts
that are easy to get wrong: a connection that dies mid-turn, output belonging
to another turn, and the two different ways runtimes chunk their text.

`npm test` runs the TypeScript sources directly, which needs Node 22.6+ even
though the published package only needs 20.19 — the tarball is compiled. CI
runs on Node 24.

A route added to `test/server.ts` has to answer in the same envelope the real
one does. Nearly everything is `{data: …}`; the nine that are not are listed at
the top of that file. A fake that wraps one of those turns a green suite into a
lie, which is how `me()` shipped returning `null`.

### Releasing

**CI is the only publisher.** `npm publish` from a checkout refuses, and npm is
configured to accept releases only from this repository's `Publish SDK`
workflow — so a tarball on the registry always carries provenance tying it to
a commit and a workflow run.

There is no release command and no tag to push. **Merging a version bump is the
release.**

```bash
cd sdk/typescript
npm version patch          # or minor / major — edits package.json + the lockfile
```

Then update two things `npm version` does not touch, and open a PR as usual:

- `USER_AGENT` in `src/http.ts`
- a `## [x.y.z]` section in `CHANGELOG.md`

The `SDK release gate` check on the PR fails if either is missing, if the
version is already on npm, or if you changed what the package ships without
bumping at all. When the PR merges, `Publish SDK` sees a version the registry
does not have, publishes it, and tags the merge commit `sdk-typescript-v<version>`.

A PR that touches only tests, examples or the changelog needs no bump; the
gate stays quiet, and the publish workflow finds nothing to do. To change the
published surface deliberately without releasing, label the PR
`release:skip-sdk`.

## License

[Apache-2.0](LICENSE), like the server and the CLI. Talking to the API, or
shipping this SDK inside a proprietary application, puts no licence
obligation on your code beyond keeping the licence and notice.

## Credit removal (7.0.0)

Managoat no longer has credits, so the server never answers 402.
`InsufficientCreditsError` and its `upgradeUrl` are removed: delete the
`instanceof InsufficientCreditsError` branch and its import. A 402 from
something in front of the server (a proxy, say) is now a plain
`ManagoatError` carrying its `status`.

### API-shaped launches

Use `client.runRequest(request, options)` to send any conversation creation
field using its API name. `ConversationInput` is derived from OpenAPI; new
fields require regeneration, not a new helper option.

```ts
await client.runRequest({
  agent_id: agent.id,
  prompt: "Review the repository",
  labels: { source: "nightly" },
  sandbox_api_access: "none",
}, { timeoutMs: 120_000, collectEvents: true });
```

This path uses IDs directly and forwards values unchanged, including explicit
null, false and empty collections. Omitted properties stay omitted. Local run
options are a separate argument. It does not combine raw fields with the
name-based options of `run(prompt, config)`; existing `run` calls still work.
A run needs a non-empty prompt. Use `client.api.request` for promptless
creation.

With `channel_id`, `runRequest` follows turn 1 when the server creates a
conversation, including fresh launches. When the server resumes a channel,
it submits the prompt, its images and its `client_request_id` to that
conversation and follows the next turn.

### Name your submission

`POST .../prompts` answers before the turn exists, so no response can give you
a turn id. Name the submission instead: the value reaches the turn the prompt
opens and that turn's `started` stage event, so you read back which turn was
yours instead of counting turns.

```ts
await managoat.run("Run the approved plan.", {
  agent: "reposage",
  clientRequestId: "plan-7-step-3",
});
await managoat.resume(id).send("And the next step.", {
  clientRequestId: "plan-7-step-4",
});
```

It is a correlation, not an idempotency key: the same value sent twice opens
two turns. A channel resume sends it again on the prompts route, because that
second request is the one that opens the turn.
