# TypeScript SDK

The REST API describes machinery. Conversations, turns, log events, blocks.
The SDK describes the job.

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

The source lives in
[`sdk/typescript/`](https://github.com/managoat/managoat/tree/main/sdk/typescript).
It has no runtime dependency, and it needs Node 20.19 or newer.

```bash
npm install @managoat/sdk
```

Up to version 10 the package was `@managoat/fountain-sdk`. Code written
against it needs only the new package name: `import { Fountain }` and
`FountainError` still work, as deprecated names for `Managoat` and
`ManagoatError`.

## What the second argument is for

The first argument is a prompt, and each LLM SDK has one. The second argument
is the part that is Managoat.

| | what it does |
|---|---|
| `agent` | Which named agent config to run. That is its runtime, model, skills and MCP servers. |
| `environment` | Which baseline to provision the sandbox from. That is the packages, the cloned repos and the setup script. |
| `vault` | Which secrets to attach at spawn. They win over the environment's on a key collision. |

Managoat decrypts a vault's values into the sandbox's environment when the
sandbox spawns. They are not in the prompt, not in the model's context, and
not in the log feed the SDK reads.

Change `vault: "github-bot"` to `vault: "github-readonly"`, and you change
what the agent can do. You change not one word of the task.

There is a second layer under that, and it changes what you can safely let an
agent do.

Managoat redacts each value of 8 bytes or more that it placed in the sandbox's
environment out of the conversation's output. It does that on the one write
path that each log event takes.

An `env`, a `set -x`, a `cat .env`, and an agent that you ask outright to
print its token all persist as `[REDACTED]`. The secret reaches the process
that needs it. It reaches neither the transcript, nor the database, nor this
SDK.

Read [the four primitives](primitives.md) for what each one is.

## Credentials

`new Managoat()` resolves exactly as the [CLI](cli.md) does. So a script
inherits whatever already works in your terminal.

```
apiKey:  option → MANAGOAT_API_KEY → MANAGOAT_TOKEN → ~/.managoat/credentials
baseUrl: option → MANAGOAT_BASE_URL → ~/.managoat/credentials → https://managoat.com
```

The last fallback, `https://managoat.com`, is the maintainer's own instance,
which has signup closed. Set `MANAGOAT_BASE_URL` or `baseUrl` to your own.

Each variable falls back to its old `FOUNTAIN_*` name, and the credentials
file to `~/.fountain/credentials`, while the new one is unset or missing.

`MANAGOAT_TOKEN` is the token that a Managoat sandbox exports for the agent
inside it. It reaches that conversation and the ones it starts, and reads the
agents, environments and vaults to start them from. `managoat.conversations()`,
`search()`, `events()`, the sandbox reads, and a conversation's `tree()` and
`markRead()` are refused with it. Read
[What a sandbox credential can do](api.md#what-a-sandbox-credential-can-do).

So an agent that imports this SDK delegates with the credential it already
holds. Managoat records the conversations it opens as its children. Fan-out
therefore needs no more configuration.

## Awaiting, streaming, or neither

`run()` starts the work and returns a handle. No second request hides behind
any of these. They are three views of one run.

```ts
// the finished answer
const result = await managoat.run(prompt, { agent: "reposage" });

// the words, as they arrive
const run = managoat.run(prompt, { agent: "reposage" });
for await (const chunk of run.textStream) process.stdout.write(chunk);

// everything: lifecycle, tools, thinking, raw events
for await (const event of run) {
  if (event.type === "tool") console.log("→", event.name);
}

// fan out: nothing is awaited, so every sandbox provisions at once
const results = await Promise.all(agents.map((agent) => managoat.run(prompt, { agent })));
```

A turn that **fails** is a result, and not an exception. So check
`result.state`, which is `done`, `failed`, `interrupted` or `timeout`. Only a
transport failure, a request the server rejected, or a timeout throws.

## When the agent asks first

An agent can hold a tool call and wait for a person. Give its
`permission_policy` an `ask` entry, and the agent stops before that tool. The
turn does not continue until an answer comes back.

```ts
for await (const event of run) {
  if (event.type !== "permission") continue;

  console.log(event.request.summary);
  const allow = event.request.options.find((o) => o.kind === "allow_once");
  await run.answer(event.request.requestId, allow.optionId);
}
```

The `options` list holds the choices of the agent, in the order of the agent.
Branch on `kind`, which is `allow_once`, `allow_always`, `reject_once` or
`reject_always`. An `optionId` that the agent did not offer causes a
`ValidationError`. To answer from a different process, use
`managoat.resume(id).answer(...)`.

A request that gets no answer expires, and the server then denies it. The turn
continues, but the agent did not do that step. Answer each request, or give the
agent the default `auto_allow` policy.

### When Claude asks a question

A claude agent whose `permission_policy` has an `ask` entry can ask you to
choose, with its `AskUserQuestion` tool. The run yields an `elicitation`
event, and the turn waits for the answer.

```ts
for await (const event of run) {
  if (event.type !== "elicitation") continue;

  console.log(event.request.message, event.request.schema);
  await run.answerElicitation(event.request.requestId, {
    action: "accept",
    content: { question_0: "Postgres" },
  });
}
```

`content` is keyed by the fields in `schema`. Send `{ action: "decline" }` to
skip the questions. A form that gets no answer expires, and the server then
declines it. Read
[when Claude asks a question](catalog/runtimes/claude.md#when-claude-asks-a-question)
for the shape of the form.

## A whole definition, in code

`run()` names an agent. Here is where that agent comes from. The point of the
whole definition is that the vocabulary fits on one screen.

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
  description: "Reads a repository and answers questions about it",
  system: "You are a careful reader of other people's code.",
  environment_id: environment.id,
  skills: [
    { source: "obra/superpowers", ref: "v2.1.0" },
    { name: "house-style", content: "# House style\n\nPrefer small diffs." },
  ],
  mcp_servers: { linear: { command: "npx", args: ["-y", "linear-mcp"] } },
  allowed_vault_ids: [vault.id],
});

// ...and now the one-liner at the top of this page has something to run.
await managoat.run("Find every N+1 query and open a PR", {
  agent: "reposage",
  vault: "github-bot",
});
```

That is an [environment](primitives.md), a [vault](primitives.md) and an
[agent](primitives.md). Those are three of the four primitives. The
conversation is the fourth.

Here are the fields that need a word.

| Field | What it decides |
|---|---|
| `runtime` | `claude`, `codex`, `gemini` or `acp`. The provider in `model` must match it, and `acp` needs no model at all. |
| `runtime_command` | The command that the `acp` runtime launches. It is a shell line, and Managoat resolves it inside the sandbox. The field is required for `acp`, and a 422 on each other runtime. |
| `model` | The canonical `provider/model_id`. Managoat checks it against no list, so a model that ships today works today. Leave it out on `acp`. |
| `system` | The agent's system prompt. |
| `skills` | Either `{ source, ref? }`, which installs from GitHub, or `{ name, content }`, which Managoat writes into the sandbox word for word. Each entry takes exactly one shape. |
| `sandbox_provider` | `sprites` or `e2b`. A `null` takes the instance default. |
| `allowed_vault_ids` | Which vaults a conversation can attach. A `null` permits each one, `[]` permits none, and a list is an allowlist. A vault value overrides the environment, so this is what scopes who can override a config that somebody reviewed. |
| `allowed_environment_ids` | The same shape. It covers a launch of the agent under a different environment. |

Every agent runs on the account's
[inference credentials](concepts/secrets.md#inference-credentials).
Existing conversations retain their resolved source on wake and resume.

Each collection reads the same way.

```ts
await managoat.agents.list();                                  // or .list("search")
await managoat.agents.get("reposage");                         // by name or id
await managoat.agents.update("reposage", { model: "anthropic/claude-opus-5" });
await managoat.agents.delete("reposage");
```

`environments` and `vaults` have the same five verbs, and `secrets` as well.

```ts
await managoat.environments.secrets.set("fountain-ci", "HEX_API_KEY", "…");
await managoat.vaults.secrets.setAll("github-bot", { GITHUB_TOKEN: "…", GITHUB_USER: "bot" });
await managoat.vaults.secrets.list("github-bot");    // keys only, never values
await managoat.vaults.secrets.delete("github-bot", "GITHUB_USER");
```

A secret value is write-only. `list` returns the keys and nothing else. The
SDK can put a credential into a sandbox, and it cannot read one back out.

!!! note "Why `environment_id` and not `environmentId`"

    A resource payload uses the API's own key names. So one definition reads
    the same way in the SDK, in the [REST API](api.md) and in a
    `managoat.yml` manifest, and this page doubles as the API reference.

    An option that controls the SDK's own behaviour is camelCase. `timeoutMs`
    and `signal` are the two, and neither one is data.

## A conversation that lasts

A chat app wants one agent, one sandbox that stays up, and one thread that you
send to again and again. That is a conversation you keep. Store its id, and
send to it.

```ts
const first = await managoat.run("Any disks over 80%?", { agent: "watchtower" });
const reply = await managoat.resume(first.conversationId).send("And inodes?");
console.log(reply.text);
```

Or let Managoat keep the mapping. A `channelId` of your own binds the
conversation, and the next `run` with the same agent and `channelId` resumes
it rather than opening a new one.

```ts
await managoat.run(text, { agent: "watchtower", channelId: `slack:${channel}` });
```

[**Build a chat app**](build/index.md) covers the job each piece does.

Managoat runs nothing on a clock. For a routine, run your own cron and send
the prompt when it fires.

### One stream for everyone

```ts
for await (const event of managoat.events({ streams: ["stage"] })) {
  if (event.kind === "stage" && event.stage === "turn" && event.state === "done") {
    refreshList(event.conversation_id);
  }
}
```

The stream covers each conversation you own, and reconnects from its last
event id on its own. So the caller sees neither a deploy nor an idle timeout.
The SDK sends `blocks` for you, so an event arrives parsed, not in the
runtime's own dialect.

## Reading a thread

Two calls cover what each application does when somebody opens a thread.

```ts
const conversation = managoat.resume(conversationId);

const events = await conversation.history({ streams: ["acp", "stage"] });  // paged until drained
await conversation.markRead();                                            // clears the unread badge
```

`history()` pages the log feed to the end for you. Without it, every app
writes that loop by hand.

The feed holds what the runtime wrote, so a replayed thread reads as a
monologue in the agent's voice. Pass `prompts: true` for the human side too:

```ts
const transcript = await conversation.history({ streams: ["acp", "stage"], prompts: true });

for (const event of transcript) {
  for (const block of event.blocks ?? []) {
    if (block.kind === "prompt") console.log("you:", block.body);
    if (block.kind === "text") console.log("agent:", block.body);
  }
}
```

Each turn's `turn`/`started` stage event then carries one `prompt` block with
the prompt that opened the turn. Nothing is added, removed or reordered, so
event ids and paging are the same as without it. The server applies three
rules:

- An autonomous turn gets no prompt block, because nobody typed it.
- The prompt rides a `stage` event, so `streams: ["acp"]` excludes it. Include
  `"stage"` when you filter streams. `history()` sends the filter you give it
  and does not widen it.
- Only the JSON feed carries prompts. Run following and the SSE streams do
  not.

`eventPage(after, limit, { prompts: true })` takes the same flag for a client
that pages by hand.

## Follow-ups

```ts
const first = await managoat.run("Find every N+1 query in this repo", { agent: "reposage" });
const second = await managoat.resume(first.conversationId).send("Fix the worst three.");
```

The second turn costs one prompt. The sandbox is the same machine. The
checkout is where the first turn left it, and the agent's session still holds
what it learned. A [suspended](reference/conversation-states.md) sandbox wakes
for it. To pay for that wake before the prompt is ready, call
`managoat.resume(id).wake()` when the conversation opens.

## Labels

A conversation carries `key=value` strings. A run stamps them with what it
found, and a list slices on them.

```ts
await managoat.resume(id).setLabels({ env: "prod", drift: "true" });
await managoat.resume(id).setLabels({ drift: null });   // null removes a key

await managoat.conversations({ labels: { env: "prod", drift: "true" } });
```

`setLabels` merges, so a key you do not name stays as it is. The filter
combines the pairs with AND. A conversation holds at most 32 labels, a key is
at most 64 bytes and a value is at most 256 bytes. The
[API reference](api.md#labels) has the limits, the sandbox rule and the ACP
extension an agent stamps its own run with.

## Workspaces

A workspace is a machine you keep: set up once from an environment and a
vault, then any number of runs launched into it, each in its own folder.
`run` takes `workspace`, a name or id, and `cwd`.

```ts
const env = await managoat.environments.get("app");
const ws = await managoat.workspaces.create({ name: "app-box", environment_id: env.id });
await managoat.workspaces.waitForReady(ws.id);   // WorkspaceFailedError if its setup fails

const [web, api] = await Promise.all([
  managoat.run("Add a dark mode toggle", { agent: "web-dev", workspace: ws.id, cwd: "/home/sprite/app/web" }),
  managoat.run("Add a theme endpoint", { agent: "api-dev", workspace: ws.id, cwd: "/home/sprite/app/api" }),
]);

await managoat.workspaces.gitStatus(ws.id, { path: "/home/sprite/app" });   // files, file, diff too
await managoat.workspaces.rebuild(ws.id, { interrupt: true });   // wipes the disk: a new machine from the environment now
await managoat.workspaces.delete(ws.id);   // terminates its conversations, destroys the machine
```

`create` takes the API's own names (`environment_id`, `vault_id`,
`sandbox_provider`) and comes back `provisioning`. `waitForReady` reads the
workspace until it is `ready`, retrying a 5xx, and throws
`WorkspaceFailedError`, carrying the workspace and its `error`, when the setup
failed. `list({ implicit: true })` adds each conversation's own implicit
workspace.

A run in a workspace that names a different `environment` or `vault` is a
`ValidationError` with code `workspace_fixes_environment`. A sandbox's own key
cannot use workspaces: every call is a 403, so a run started from inside a
sandbox always gets a machine of its own. That refusal is a `ManagoatError`
with code `insufficient_scope`, and its body's `required_scope` is `full`.
Any refusal for a key's scope has that code. A workspace name is
matched exactly, never by prefix as agent and vault names are.

!!! warning "Runs in one workspace can read and influence each other"

    They run as one user on one disk, so each can read the others' files and
    tokens. Leave `workspace` out for a run that must be isolated.

A workspace's machine has no lifetime limit, and Managoat does not cap how
many you keep. Delete the ones you are done with. Read
[About workspaces](concepts/workspaces.md) and
[Run several agents on one machine](guides/agents-in-one-workspace.md).

`rebuild` replaces the machine with one set up from the environment as it is
now, and **wipes its disk**: read what you need with `diff` first. Every run's
conversation stays in the workspace with its transcript and starts a fresh
session. A running turn refuses it with code `turns_running` unless
`interrupt: true`; one while the workspace is provisioning is code
`rebuild_in_progress`.

A workspace says whether its machine is behind its environment: `stale`, and
`changed_fields`, the names (never the values) of the environment's fields
that changed since the machine was built, typed as `WorkspaceField[]`, beside
`revision` and `built_from_revision`.

`events()` also carries a `workspace.status` frame, `{workspace_id, name,
status, error, revision, built_from_revision, stale, changed_fields}`, when
one of your workspaces changes status or an edit to a ready one's environment
moves its revision, as it carries the
`conversations` change notice, `{reason}`. Neither is a log event, and
neither is replayed after a reconnect. The SDK sets each one's `kind` to its
event name, so a switch on `kind` tells all four apart and narrows the type:

```ts
for await (const event of managoat.events()) {
  if (event.kind === "workspace.status") showWorkspace(event.workspace_id, event.status);
  else if (event.kind === "conversations") refreshList();
  else if (event.kind === "stage") showStage(event.conversation_id, event.stage, event.state);
}
```

## Sandboxes

A sandbox is the machine a conversation runs on. A conversation has one of
its own unless it runs in a workspace. The client reads them.

```ts
await managoat.sandboxes({ status: ["ready", "suspended"] });  // the list, with the conversation on each
await managoat.sandbox(id);
```

The [API reference](api.md#sandboxes) has the fields.

## Timeouts

`run()` waits as long as the turn takes, and agent work fairly runs for hours.
`timeoutMs` stops the *wait*, and never the agent.

```ts
try {
  await managoat.run(prompt, { agent: "reposage", timeoutMs: 5 * 60_000 });
} catch (error) {
  if (error instanceof TimeoutError) {
    console.log(error.partialText);
    await managoat.resume(error.conversationId).send("status?");
  }
}
```

`run.interrupt()` asks the agent to stop the turn, and leaves the sandbox up.
`run.terminate()` takes the sandbox down.

## Errors

Branch on `code`, and not on the status. `conversation_busy` is a 400, and
`provisioning` and `fleet_full` are 503s. What you want
to say about each one has nothing to do with those numbers.

```ts
try {
  await managoat.resume(conversationId).send(prompt);
} catch (error) {
  if (error instanceof ConversationBusyError) return "Still working on the last one.";
  if (error instanceof NotReadyError) return `Starting up, retry in ${error.retryAfter}s.`;
  if (error instanceof ValidationError) return Object.entries(error.fieldErrors)[0]?.join(" ");
  throw error;
}
```

| Class | Code / status | Retryable |
|---|---|---|
| `ConversationBusyError` | `conversation_busy` (400) | Yes. The turn in flight must finish. |
| `NotReadyError` | `provisioning`, `fleet_full`, `sandbox_unavailable` (503) | Yes. It carries the server's `Retry-After`. |
| `ValidationError` | 422 | No. Read `fieldErrors`. |
| `AuthError` and `NotFoundError` | 401 and 404 | No. |
| `ConnectionError` | It never reached the server. | In a browser, the cause is usually CORS. |

Each one carries `status`, `code`, `body`, `retryAfter` and a `retryable`
flag. So a generic retry wrapper needs no table of its own.

Managoat sends two more codes that mean the same thing and are not yet mapped
to `NotReadyError` in any client: `sandbox_probe_failed` (Managoat could not
reach the sandbox provider) and `sandbox_resume_failed` (the provider would not
wake a parked machine). Both are 503 with a `Retry-After`, so
**retry on the status or on `retryAfter`, not on the class**, and a wrapper
that does will handle them today and keep handling them when they are mapped.

## In a browser

The SDK's default entry pulls in no Node built-in, so it bundles as it is. The
reader for the credentials file sits behind the `node` export condition.

In a browser you pass what you have.

```ts
const managoat = new Managoat({ baseUrl, apiKey });   // from your own settings UI
```

The server must admit your origin through a registered OAuth client or
`API_CORS_ORIGINS`. Otherwise each call fails before it starts.

`ConnectionError` says exactly that. "Failed to fetch" has sent more than one
person to search their own code for an hour.

## Everything else

The SDK wraps the verbs that are worth a wrapper. The rest of the API is one
call away, with the same auth and the same errors. That rest is audit, API
keys and admin.

```ts
await managoat.request("GET", "/api/audit", { query: { limit: 50 } });
```

The [API reference](api.md) covers those, and so does the generated
`GET /api/openapi.json`.

## Generated underneath

Nobody writes the types by hand. `src/generated/openapi.ts` comes from the
OpenAPI document that the server serves at `GET /api/openapi.json`.

CI generates it again and fails on a diff. So a field that somebody adds to a
schema in Elixir reaches the SDK on the next build. A type here can never
describe an API that has gone.

```ts
import type { components, paths } from "@managoat/sdk";

type Agent = components["schemas"]["Agent"];
```

What people write by hand is the part a spec cannot express. That many log
events fold into one *turn*. That you can await a run or stream it. Which of
83 paths are worth a verb.

## How CI publishes it

CI publishes every version. No person publishes from a workstation. npm accepts
a release only from the `Publish SDK` workflow in this repository. Each tarball
therefore carries a provenance attestation. To examine it, install the package
and then run this command:

```bash
npm audit signatures
```

A verified attestation identifies the workflow and the commit that made the
tarball. A package that a person sends by hand has no such attestation.

## Versions and compatibility

The SDK versions independently of the server, and the REST API is not
additive. A Managoat release can remove or change an endpoint. An SDK pinned
before that release then calls a route that answers `404`, or one whose
shape has changed.

- A major SDK version removes or changes public SDK API. That is a client
  method, an error class, an exported type, or a generated type. One follows
  each server release that removes or changes something the SDK exposes, and
  its changelog entry names that server release. A minor version adds. A
  patch fixes.
- Each SDK release is tested against one server, the one built from the same
  commit. An older major gets no fixes and has no support window. It keeps
  working against a newer server only while every route it calls is still
  there in the same shape. Nothing guarantees how long that is.
- A breaking API change is announced under **Upgrade notes** in the
  [release notes](https://github.com/managoat/managoat/releases) of the
  server release that makes it. It is then
  announced again in the
  [SDK changelog](https://github.com/managoat/managoat/blob/main/sdk/typescript/CHANGELOG.md),
  in the major that follows.

So pin a major, and read a server release's upgrade notes before you take it.
When they remove or change an API, upgrade to the SDK major that names that
release. [Upgrading](guides/operate/upgrade.md) covers the server's own
version numbers.

## Other languages

TypeScript is the one SDK Managoat maintains. The Python
(`fountain-agent-sdk` on PyPI), Elixir (`fountain_sdk` on Hex) and Swift
(`sdk-swift-v*` tags) SDKs are retired: their published releases stay where
they are, but they are no longer maintained or tested against new servers.
For another language, call the [HTTP API](guides/http-api.md) directly. The
[`managoat` CLI](cli.md)'s `managoat run`, in Go, is a worked reference for
following a turn: it streams the log feed over SSE.

That reference implements the rules that the TypeScript SDK implements. Keep
your own turn's events, and no other. Keep the `text` blocks, and no other
kind. Join ACP chunks with nothing between them.
Start a new paragraph after a tool call. Resume from the last event id when a
connection drops mid-turn.

## Credit error removal

Managoat no longer has credits, and the server never sends
`insufficient_credits` or a 402. The TypeScript SDK removed
`InsufficientCreditsError` and `error.upgradeUrl` in 7.0.0. Delete the branch
that handled them. A 402 from something in front of the server, such as a
proxy, is now the client's generic error and carries its status. A retired
SDK that still handles `insufficient_credits` keeps a branch the server never
takes.
