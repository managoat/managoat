# API reference

Use the [generated API reference](/api/docs) for endpoints, parameters,
request bodies, response schemas, and error statuses. Managoat builds that
reference from the same OpenAPI descriptions that define its SDK contract.
The [OpenAPI document](/api/openapi.json) is public and needs no credential.

The reference describes the instance that serves it. On a self-hosted instance, open `/api/docs` on that instance.
This page holds the rules, limits and error codes the generated reference
does not explain; it does not maintain a second endpoint catalog.

To authenticate, start a conversation, follow its events and send follow-up
prompts step by step, read [Call the API over HTTP](guides/http-api.md). For
a script, start with the [TypeScript SDK](sdk.md). Use HTTP directly from
another language, or when your workflow needs a surface the SDK does not
expose.

## Authentication

Every request carries an API key as a bearer token
(`Authorization: Bearer ...`). A key comes from the console (**Account**,
**API keys**), from `managoat auth login`, or from Sign in with Managoat.
Each token exchange creates another key, so reuse the one you have.
[Authenticate](guides/http-api.md#authenticate) walks through it.

Check the Auth operations in the [generated reference](/api/docs) for
account recovery, verification, key creation, revocation, and credential
expiry. A sandbox credential has restricted scope. Use an account credential
for administrative workflows.

### What a sandbox credential can do

Each sandbox gets a `MANAGOAT_TOKEN`, a key with `sprite` scope. It reaches
the sandbox's own conversation tree: its own conversation and every
conversation it started, at any depth, but not the conversation that started
it, nor that one's other children. That is enough to fan work out to the
agents you configured.

With it an agent can:

- read what it needs to start a conversation: `GET /api/auth/me`,
  `GET /api/catalog`, and `GET` on agents (with their versions and avatar),
  environments, vaults, and the secret names of an environment or vault. No
  key can read a secret's value;
- start a conversation with `POST /api/conversations`. The new conversation
  is always a child of the sandbox's own. Leave out
  `X-Managoat-Parent-Conversation-Id` or set it to `$MANAGOAT_CONVERSATION_ID`;
  any other value gets `404 parent_conversation_not_found`;
- on a conversation in its tree: show it, read its `turns`, `events`,
  `stream` and turn images, send it a prompt, `interrupt`, `wake` or
  `terminate` it, and delete it. It can label only its own conversation.

A conversation outside the tree answers `404 {"error": "not_found"}`, as
another account's conversation does. Every other request, such as listing
conversations, `/api/search`, the account event stream
`/api/events/stream`, a conversation's `tree`, sandboxes and the audit log,
gets `403` with `error: "insufficient_scope"` and `required_scope: "full"`.
So does a route that a later release adds, unless that release adds it to this
list.

There is no setting that gives `MANAGOAT_TOKEN` the whole account. If an
agent must act on the whole account, put a full-scope key of your own in a
vault or environment for it, and choose that knowingly. To give a sandbox no
key at all, start the conversation with `sandbox_api_access: "none"`.

A sandbox also gets each `MANAGOAT_*` variable under its old `FOUNTAIN_*`
name, such as `FOUNTAIN_TOKEN`, for code written before the project was
renamed. A later release stops setting the old names.

The token cannot change what an agent is, or what its sandbox is built from.
These requests need a full-scope key:

- creating, updating or deleting an agent, its avatar, an environment, a
  vault, or a secret in either, and copying a vault;
- `POST /api/apply`.

The same rule covers API keys, OAuth clients, secret bindings, a
conversation's egress log, inference credentials, account security, and a
sandbox's files.

It also covers [workspaces](#workspaces): every `/api/workspaces` route, and a
`POST /api/conversations` that names a `workspace_id`, answer `403` with
`required_scope: "full"`. A child conversation therefore always gets a
sandbox of its own. In a workspace, though, every conversation can read the
others' `MANAGOAT_TOKEN`, so what one key there reaches is in effect the
union of their trees.

A refused request gets `403` with `error: "insufficient_scope"` and
`required_scope: "full"`. Without this rule, a prompt-injected agent could
rewrite an agent's instructions or an environment's setup script, and the
next launch would run what it wrote. It could also replace your inference
credentials or lock you out of the account.

### Sign in with Managoat (OAuth 2.0 for browser apps)

Browser apps use the authorization code flow with PKCE. The returned token
is a Managoat API key. Register the client and its exact redirect URIs
before you start the flow.

Keep the verifier in the app that initiated sign-in, and validate `state`
on return. [Sign users in from a browser app](guides/http-api.md#sign-users-in-from-a-browser-app)
walks through the flow, [Build a chat app](build/index.md) shows the shape of
such an app, and the OAuth operations in the [generated reference](/api/docs)
define the token exchange.

### Register your own app

Register a client in the console under **Account**, in the **OAuth apps** section, with
`managoat oauth-client create`, or through the API.

```
GET    /api/oauth/clients        # the account's clients
POST   /api/oauth/clients        # {name, redirect_uris} -> {client_id, ...}
GET    /api/oauth/clients/:id
PATCH  /api/oauth/clients/:id    # rename it, or replace the redirect URIs
DELETE /api/oauth/clients/:id
```

These routes need a full-scope key. A sandbox token cannot register a client.
A registered client leads to a full-scope key after consent.

Your client starts in **development mode**. It signs in only the account that
registered it. Every other account gets an error page instead of a redirect.
Only an operator publishes a client for other accounts. After that, only an
operator changes or removes the registration. Every other account signs in
through it, and the `client_id` is random, so a deletion breaks them all.

One account registers a maximum of 25 apps.

A redirect URI must match exactly and must use `https`. A URI on `localhost`
or `127.0.0.1` can use `http` and matches on any port.

The redirect origins also call `/api` from a browser. One registration covers
both sign-in and CORS. It needs no `OAUTH_CLIENTS` or `API_CORS_ORIGINS`
change.

## Account state

Read account identity (`GET /api/auth/me`) before you display
account-specific controls.

For a sandbox key, `/api/auth/me` also returns `conversation_id`, the
conversation the key belongs to. It does the same for the `conversation`-scoped
key that an MCP server receives when an agent names it with
`auth: conversation`. That key can read its own conversation and nothing else.
The server uses `conversation_id` to bind the key to one conversation. For any
other key, `conversation_id` is null. Read
[Your application's own server](catalog/mcp-servers/index.md#your-applications-own-server).

See the account and Auth operations in the [generated reference](/api/docs).

### Account deletion

Treat deletion as a separate, explicit user action. Deletion is immediate and
cannot be undone. See the account operations in the
[generated reference](/api/docs) for the deletion contract.

## Inference credentials

Inference credentials pay the model provider. Configure one when the selected
runtime needs it. A configured credential does not imply that a provider will
accept it.

Store provider keys in your account's
[inference credentials](concepts/secrets.md#inference-credentials). An account
holds one set of up to four: `anthropic_api_key`, `claude_code_oauth_token`,
`openai_api_key` and `gemini_api_key`. Values remain write-only; read
responses report which providers are set.

These routes require a full-scope account key.

| Method and path | Purpose |
|---|---|
| `GET /api/account/inference-credentials` | Which providers are set. |
| `PUT /api/account/inference-credentials/:provider` | Set one provider with `{"value": "..."}`, validated against the provider unless `validate` is `false`. |
| `DELETE /api/account/inference-credentials/:provider` | Clear one provider. |

The resolved source is bound to the conversation and recorded for each turn.
Wake and resume do not silently switch an existing conversation to another
credential after a replacement or deletion. See the
[sharing constraints](concepts/secrets.md#inference-credentials) and the
[generated reference](/api/docs) for response schemas and refusals.

### ChatGPT subscriptions

A codex run on an `openai/` model uses the account's ChatGPT subscription,
then the account's own `openai_api_key` (its own, an environment's or a
vault's). Subscriptions are linked in the console, not through the API; see
[Run Codex on a ChatGPT subscription](guides/chatgpt-subscription.md). A turn
on the account's subscription reports `scope: "grant"`. A conversation whose subscription
was disconnected, refused by OpenAI or linked to another account gets
`409 chatgpt_reconnect_required` on its next prompt or wake.

## Rate limiting

The resource API uses fixed one-minute windows.

- Each authenticated API key has a 600-request allowance.
- Failed authentication has a separate 600-request allowance per client address.
- A coarse ceiling allows 6,000 total attempts per client address before
  authentication. It includes failed authentication and requests over a key's
  quota. Exhausting it blocks every key at that address until its window resets.

Each key retains its individual allowance behind a shared ingress. All keys
count toward the coarse ceiling. Forwarded client addresses are accepted only from configured
`TRUSTED_PROXIES`; a direct caller cannot choose an address through headers.
Individual operations can impose additional limits.

Honor `Retry-After` when a request is rate limited. Avoid immediate retry
loops. A lost response to a mutation does not prove that the mutation failed;
reconcile the resource before you repeat an operation that could spend money.
See each operation's responses in the [generated reference](/api/docs).

## Agents

An agent is reusable configuration for a runtime and model. Create its
[environment](concepts/environment.md) and [vault](concepts/vault.md) first,
then reference them when you configure the agent.

Use version history to inspect configuration changes. Versions are read-only;
to restore one, write its config back to the agent.
See [Agents](concepts/agent.md) for the model and the Agents operations in
the [generated reference](/api/docs) for the complete contract.

## Catalog

Read the instance catalog before you offer runtime, provider, or app choices.
An integration should distinguish an unavailable capability from one that its
workflow does not require. The [generated reference](/api/docs) describes the
catalog response; the [Catalog](catalog/index.md) explains shipped resources.

## Environments

An environment supplies the packages, repositories, scripts, network policy,
and baseline secrets a machine needs. See [Environments](concepts/environment.md).
The [generated reference](/api/docs) defines the editable configuration and
secret operations. A secret write reaches running conversations the way a vault secret write does.

## Vaults

A vault supplies secret overrides without a duplicate environment.
See [Vaults](concepts/vault.md) for precedence and reuse. Submit secret values
through the write operations in the [generated reference](/api/docs); do not
expect read operations to return them. A write or
delete reaches running conversations on the vault during their current turn,
at the sandbox's next connection through the broker. See
[Secrets](concepts/secrets.md#hop-3-environment-and-vault-merge).

To start a vault from another one's secrets, use `POST /api/vaults/:id/copy`.
The server copies the values, so they never cross the API.
See [Copy a vault](concepts/vault.md#copy-a-vault).

## Secret bindings

Use broker bindings when a sandbox should reference a credential while the
broker supplies its value to an approved destination. The credential value stays outside the sandbox.

See [Secrets](concepts/secrets.md) for the security model and the binding
operations in the [generated reference](/api/docs) for configuration.

Every deployment runs the broker, so `GET /api/auth/me` always answers
`brokered: true`; the field stays for clients that read it.

## Connections

A connection is your OAuth grant to one remote MCP server
([ADR 0085](https://github.com/managoat/managoat/blob/main/decisions/0085-mcp-connections.md)).
`POST /api/connections` with `{"url": ...}` discovers the server's
authorization server, registers a client, and returns the pending connection
with an `authorize_url`. Open that URL in a browser signed in to Managoat as
the same account; the connection becomes `active` when the provider sends the
browser back to `/connections/callback`. A `client_required` refusal means
the server lets no client register itself: send `client_id`,
`client_secret` and any `authorize_params` from an app you registered with
the provider.

`GET /api/connections` and `GET /api/connections/:id` list and read them,
`POST /api/connections/:id/authorize` starts a reconnect, and `DELETE`
disconnects and revokes the grant at the provider. None of them ever returns
a token. All of them need a full-scope key.

An agent names a connection in an `mcp_servers` entry as
`"auth": {"connection": id}`. A turn whose connection is pending, revoked,
expired or deleted is refused with `409 connection_reconnect_required` and
the `connection_id`. See [Connect Linear to an agent](guides/connect-an-mcp-server.md).

## Bulk apply

Use `managoat apply` when a checked-in manifest should define several related
resources. The CLI compiles the manifest and submits the resource graph.
Inspect every resource result. One failed resource does not mean that all
other writes failed. Apply needs a full-scope key; a
[sandbox credential](#what-a-sandbox-credential-can-do) is refused.

A manifest holds three kinds. Managoat reconciles them in a fixed order, which
is `Environment`, `Vault` and `Agent`, so an `Agent` can name its
`environment` whatever its position in the file. The name resolves against
the manifest first, then against the records the account already holds. A
name that matches neither fails that document alone.

The document name is the key for every kind. An absent `spec` key leaves
that field alone.

Apply is additive. A document that you delete from the manifest leaves its
record in place. There is no prune.

The audit trail names each applied row. Each row carries the actor and the IP
address of the request that applied it.

Each result row reports `created`, `updated`, `unchanged` or `error`. A
second apply of an unchanged manifest reports `unchanged` for every row, and
writes no audit event for those rows. Inline `spec.secrets` are encrypted
again on each apply, so they keep reporting `upserted` under a row that
reports `unchanged`.

See [CLI](cli.md) for the workflow and the Apply operation in the
[generated reference](/api/docs) for its wire format. Unknown configuration
keys fail validation before Managoat writes that resource's attributes or secrets.

## Conversations

A conversation is created with an agent and an optional first prompt, and
later prompts go to its ID. A new conversation creates another thread.
[Start a conversation](guides/http-api.md#start-a-conversation) and
[Follow its events](guides/http-api.md#follow-its-events) walk through it.

Each turn has a read-only `inference` object that says which inference source
served it. `scope` is one of `credential`, `tenant_secret`, `grant` (the
account's [ChatGPT subscription](#chatgpt-subscriptions)), `none` and
`missing`. Managoat writes the object when the turn starts and does not
change it. A later change to the credential or a restart changes later turns
only. The object is null on a turn from before Managoat recorded it, and on
a turn that ran on a deployment's inference key before Managoat removed
those.

A first prompt is optional. A launch with no prompt creates the conversation
and waits for a later turn. A prompt that is present must contain words.
Managoat refuses blank or whitespace-only text with `422 invalid_prompt`.

Images need that first prompt. Managoat refuses images that arrive with no
text, and the error is `422 invalid_prompt`. An unsupported `media_type`,
empty bytes, or more than 10MB give `422 invalid_images`. Both checks run
before the launch reserves a sandbox, so bad input costs no machine.

This starts real work and can consume sandbox time and provider usage.
[Conversation states](reference/conversation-states.md) explains lifecycle
transitions. The Conversations operations in the
[generated reference](/api/docs) define prompt admission, permission answers,
interruption, termination, history, images, and event streams.

Use history for a durable transcript and SSE for live delivery. Persist the
event cursor so a reconnect can resume after the last event processed.
Request structured blocks to render ACP output. Historical vendor stdout
formats are no longer parsed; those events remain available as raw data.

### Open a thread at its newest turns

`GET /api/conversations/{id}/events` pages forward from `after` by default.
A long conversation holds thousands of events, and a client that shows only
the newest turns does not need to read all of them first. Ask for the newest
page instead:

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  "$MANAGOAT_URL/api/conversations/$ID/events?order=desc&limit=200&whole_turns=true&blocks=true&prompts=true"
```

With `order=desc`, `data` is newest first. `meta.next_cursor` is the oldest
event ID on the page. Pass it as `before` to get the page before it.
`meta.has_more` says that older events exist. `page.newest_cursor` is the
newest event ID on the page. Pass the first page's value as `Last-Event-ID`
to follow the conversation over SSE from there.

`whole_turns=true` keeps a turn on one page. When the event at `limit` belongs
to a turn that started earlier, the page extends to that turn's first event.
The page keeps every event in that range, including events of another turn and
events with no turn. A page can therefore hold more events than `limit`. The
next page with `before` starts below the oldest event, so it returns earlier
turns only. Events with no turn, such as the setup before turn 1, page by
`limit` alone.

A page holds at most 5,000 events. A turn that is larger than that is cut
there, and `page.turn_split` is `true`. The rest of the turn is on the next
page. `whole_turns` requires `order=desc`, and Managoat answers `422` without
it.

Event IDs are global to the server, so the IDs in one conversation have gaps.
Use the cursors that a page returns, and do not compute one from an ID.
`streams`, `blocks` and `prompts` work the same in the two directions. Every
page has a `page` object with `order`, `oldest_cursor`, `newest_cursor` and
`turn_split`. Forward pages also accept `before` as an upper bound.

### Find the turn your prompt opened

`POST /api/conversations/{id}/prompts` answers before the turn exists. A
conversation with no machine must wake first, and the turn opens after that.
So the response cannot give you a turn ID. Give Managoat your own name for the
prompt instead. [Send a follow-up and find its turn](guides/http-api.md#send-a-follow-up-and-find-its-turn)
walks through the steps; this section holds the rules.

The wake runs after the response, and so does the wait for a sandbox that is
still being set up or reattached. The request still refuses what needs no
sandbox to decide: a missing agent, a sandbox
being destroyed, or no room for one more sandbox. A wake that fails later is a
`wake` stage event with the `failed` state. Its `reason` says why, and
`retryable` says whether sending the prompt again can succeed. A refusal that
you have to act on, such as `sandbox_provider_disabled`, also has an `advice`
that says what to change. No turn opens for that prompt.

```json
{"prompt": "Run the approved plan.", "client_request_id": "plan-7-step-3"}
```

The response repeats the value. Managoat stores it on the turn that the prompt
opens, and `GET /api/conversations/{id}/turns` shows it as `client_request_id`.
The turn holds the value you sent, character for character. It is the record.

The `turn` stage event with the `started` state carries the value next to
`turn_id`. Use that event to find a candidate turn quickly. Then read the turn
and compare its `client_request_id` with the value you sent. Bind your work
item only after that comparison.

Do not bind on the event alone. Managoat removes the sandbox environment values
from the data of every event. So an event shows `[REDACTED]` in the place of a
value that your ID contains, and a different client can send that same text as
its own ID. The two events are then equal and the two turns are not. Every
later event of the turn carries the same `turn_id`.

Two clients can send a prompt at the same moment. A conversation runs one turn
at a time, so one prompt opens the turn. The turn carries the value of that
client. Turn order cannot tell you that. When the conversation has a machine
that is awake, Managoat answers `conversation_busy` to the other client. When
the conversation must wake first, Managoat answers `queued` to the two clients.
It then drops the prompt that arrives second, and says so on the stream with a
`wake` stage event in the `failed` state and the reason `conversation_busy`.

The value is a string of 1 to 200 characters. It cannot contain a null
character; Managoat answers `422` for one that does. Send it in the request
body: Managoat does not read this field from the query string. Make the value
unique in the conversation. Managoat does not check that. **It is not an
idempotency key.**
A second prompt with the same value opens a second turn, and the two turns
carry the same value. Do not send a prompt again only because a response was
lost. Read the turns first.

`POST /api/conversations` takes the same field for its first prompt. The value
goes to turn 1 of a new conversation. Managoat ignores the value
when the request has no `prompt`. When a `channel_id` request returns a resumed
conversation, it does not deliver the prompt. Send the prompt to that
conversation on the prompts route, with the value.

An accepted prompt does not always open a turn. Managoat can refuse it after
the response: a limit on the conversation stops it, or another prompt opened the turn first. The stream reports some of these
refusals and not others. So do not wait without a limit for a `started` event
that carries your value. Set a time limit. Then read the turns.

A turn that carries your value shows that the prompt ran. No turn with your
value shows nothing. The prompt can still be waiting for the machine that must
start first. In that outcome you do not know whether the prompt ran. If you
send it again, the work can run two times.

A turn that Managoat opened by itself has the `autonomous` origin and a null
`client_request_id`.

The TypeScript SDK sends the value for you. It takes it on a run and on a
follow-up prompt: `run(prompt, { clientRequestId })` and
`send(prompt, { clientRequestId })`. A client that resumes a conversation with `channel_id` sends the value
again on the prompts route, because that request opens the turn. A client that
gets no value sends no field.

The CLI takes `--client-request-id` on `managoat run` and `managoat conv prompt`.
The ACP bridge takes `_meta.clientRequestId` on each `session/prompt`; see
[ACP prompt metadata](integrations/acp.md#_meta-extensions-on-sessionprompt).

### When the fleet is full

A start or a wake that would take the deployment past the fleet ceiling of
the provider the sandbox runs on (`SANDBOX_FLEET_CEILING_SPRITES`,
`SANDBOX_FLEET_CEILING_E2B`, each defaulting to `SANDBOX_FLEET_CEILING`) gets
`503 fleet_full` with `Retry-After: 60`. Nothing queues:
send the request again once a sandbox frees.

### Spawn depth

An agent can start another conversation from inside its sandbox, and that
one can do the same. Each conversation has a read-only `depth`: 0 when it was
started from outside any sandbox, and one more than the conversation it came
from when it was started from inside one. Managoat counts from the
`X-Managoat-Parent-Conversation-Id` header and from the sandbox's own token
(`$MANAGOAT_TOKEN`), and takes the deeper of the two, so leaving the header
out does not start a chain again at 0. A start made with the sandbox's own
token is always a child of that sandbox's conversation, header or not.

A start deeper than `CONVERSATION_MAX_DEPTH` (default 5;
[Configuration](configuration.md#spawn-depth)) is refused before it reserves
a sandbox:

```json
{
  "error": "conversation_depth_exceeded",
  "message": "this conversation would be at depth 6 of its spawn chain, and the deepest this instance allows is 5 (CONVERSATION_MAX_DEPTH)",
  "depth": 6,
  "max_depth": 5
}
```

The status is 422. Retrying does not help: finish the work at the current
depth, or ask the operator to raise the ceiling. A sandbox that holds the
owner's own full-scope key instead of its token, and sends no header, is
counted as a start from outside, at depth 0.

### Labels

A label is a `key=value` pair of strings on a conversation. A program stamps
its own runs with the facts it knew when the turn ended. Examples are
`env=prod`, `drift=true` and `gated=apply`. Labels are not searched. Use them
to slice a list.

Set them at creation, and read them back on every conversation object.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"YOUR_AGENT_ID","labels":{"env":"prod"}}' \
  "$MANAGOAT_URL/api/conversations"
```

Filter a list with a repeatable `label` parameter. Managoat combines the
values with AND. The example keeps the conversations that carry both pairs.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  "$MANAGOAT_URL/api/conversations?label=env:prod&label=drift:true"
```

Each value splits on its first colon. The key is the part before it, and the
value is all of the rest. `label=path:apps/fountain:lib` therefore filters the
key `path` for the value `apps/fountain:lib`. A value with no colon, or with
an empty key, returns 400 `invalid_label_filter`.

The parameter is an array in the OpenAPI document, with `style: form` and
`explode: true`. A client that builds arrays as `label[]=env:prod` is
accepted too.

`PATCH /api/conversations/{id}/labels` merges labels into a conversation. A
key the body does not name stays as it is. A key with a `null` value is
removed.

```bash
curl --fail-with-body -X PATCH \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"labels":{"drift":"true","env":null}}' \
  "$MANAGOAT_URL/api/conversations/$CONVERSATION_ID/labels"
```

A conversation holds at most 32 labels. A key is at most 64 bytes and a value
is at most 256 bytes. Neither can contain a NUL byte. A write that breaks one
of these limits returns 422 and names the offending key under
`errors.labels`. The count applies to the merged result, so a merge can fail
against labels that are already there. The key named is one you sent, and
never one that was already on the conversation.

A create call to `POST /api/conversations` with a `channel_id` that resumes
a conversation also takes `labels`, and merges them into that conversation.

The account's own API key can label any of its conversations. A sandbox
callback token can label only the conversation it was minted for. A
conversation it started returns 403
`sprite_may_not_label_another_conversation`, and one outside its tree returns
404. This applies to both doors that write labels, which are the labels route
and a `channel_id` resume.

### An agent that labels its own run

An agent inside a turn does not need the route above. It sends an ACP
extension notification on the session it already holds. ACP keeps names that
start with `_` for extensions.

```json
{"jsonrpc":"2.0","method":"session/update","params":{
  "sessionId":"sess_1",
  "update":{"sessionUpdate":"_fountain/labels",
            "labels":{"drift":"true","env":"prod"}}}}
```

Managoat merges the map with the same rules as the route. A `null` value
removes a key. The notification never reaches the transcript, and it opens no
turn of its own. A stamp that breaks a limit is logged and dropped, and the
turn continues. Nothing in a stamp can end a run.

### Choose the model

A conversation runs its agent's model unless it names one of its own. Name one
at creation with `model`. The value is in canonical `provider/model_id` form.
It applies to this conversation only, for its whole life, and the agent keeps
its own model.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"YOUR_AGENT_ID","prompt":"Hello","model":"anthropic/claude-sonnet-5"}' \
  "$MANAGOAT_URL/api/conversations"
```

The conversation object reports the override as `model`, and `null` means it
follows the agent. Each turn records the model it asked for under
`model_selection`.

Managoat checks the model as it checks an agent's model. A provider that the
runtime does not drive returns `422 model_invalid`. So does any model on the
`acp` runtime, which resolves none. Managoat does not check the model id
against a list, so a model released today works today.

A conversation without a `model` follows its agent. After you edit the agent's
model, its next turn returns `409 inference_source_changed`; start a new
conversation for the new model. A conversation with a `model` does not read
the agent's model, so the edit does not reach it.

The model is not part of a channel's resume key. A create request that resumes
a conversation through `channel_id` and names another model returns
`409 conversation_model_differs` before Managoat sends its prompt. Set
`fresh: true` to start a new conversation on it.

### Choose the working directory

A conversation's agent runs in its runtime's default directory unless the
launch names one: `/home/sprite` for `claude`, `codex` and `acp`, and
`/tmp/gemini-workspace` for `gemini`. Name another at creation with `cwd`, an
absolute path inside the sandbox. Managoat creates it if it is missing, after
the environment's repositories are cloned and its setup script has run, and
the agent's session starts there.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"YOUR_AGENT_ID","prompt":"Run the tests","cwd":"/home/sprite/app"}' \
  "$MANAGOAT_URL/api/conversations"
```

The path must be `/home/sprite` or a directory under it, or for a `gemini`
agent, also under `/tmp`. It may also be a repository's `mount_path` in the
environment the launch runs with, or a directory under one: the agent's
environment, the one the launch names, or with `workspace_id`, the
workspace's. So an environment that clones to `/work/app` can run an agent in
`/work/app`. A `mount_path` that is `/`, `/home/sprite` or one of its
ancestors, inside `/home/sprite/.managoat`, under another home in `/home`,
or in a system tree (`/.sprite`, `/bin`, `/boot`, `/dev`, `/etc`, `/lib*`,
`/nix`, `/proc`, `/root`, `/run`, `/sbin`, `/snap`, `/sys`, `/usr`, `/var`) is
still cloned, but does not widen this rule. A `cwd` outside `/home/sprite` (and,
for gemini, `/tmp`) must also lie in a checkout on the machine (the clone, or a directory
under it) when the conversation starts there; otherwise its first turn fails
setup. This matters for a workspace, whose machine clones only at setup: a
mount added to the environment afterwards is not there yet. The
path may not be inside `/home/sprite/.managoat`, where Managoat keeps each
conversation's config home. Anything else returns `422 validation_failed`
with the reason under `errors.cwd`. Managoat normalises the path
(`/home/sprite/a/../b/` is `/home/sprite/b`).

The directory is fixed for the conversation's life. The conversation object
reports it as `cwd`, the default included. A create request that resumes a
conversation through `channel_id` may omit `cwd` or name the one it runs in;
another returns `422 validation_failed` too. Codex's own sandbox lets the
agent write to this directory, and the [file routes](#files-git-status-and-git-diff)
resolve a relative path from it, except on an explicit workspace's machine, which several
conversations share and where a relative path resolves from `/home/sprite`. The CLI takes it as `--cwd` on `managoat run`
and `managoat acp`.

### Launch into a workspace

A conversation gets a sandbox of its own unless the launch names a
`workspace_id`, one of the caller's [workspaces](#workspaces). It then runs on
the workspace's machine, beside the conversations already there, with a
config home and an adapter process of its own. Name a `cwd` too, so that each
agent works in its own folder.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"YOUR_AGENT_ID","workspace_id":"YOUR_WORKSPACE_ID","cwd":"/home/sprite/app/api","prompt":"Run the tests"}' \
  "$MANAGOAT_URL/api/conversations"
```

The agent supplies the runtime, model, skills, MCP servers, system prompt and
permission policy. The workspace supplies the environment, the vault and the
sandbox provider, and the agent's `sandbox_provider` is not read. The
conversation object reports `workspace_id`.

| Refusal | When |
|---|---|
| `404 not_found` | The workspace is another account's, an implicit one, or being deleted. |
| `422 workspace_fixes_environment` | The launch names an `environment_id` or `vault_id` other than the workspace's. Naming its own is accepted. |
| `422 environment_not_allowed`, `422 vault_not_allowed` | The agent's `allowed_environment_ids` or `allowed_vault_ids` leaves out the workspace's. |
| `422 invalid_sandbox_api_access` | `sandbox_api_access` is `none`, which needs a sandbox of the conversation's own. |
| `422 machine_name_with_workspace` | The launch names a `machine_name`; the workspace names its machine. |
| `403 insufficient_scope`, `required_scope: full` | The caller is a sandbox's own key. A conversation started from inside a sandbox always gets a sandbox of its own. |

`sandbox_id` on a launch is still `422 sandbox_attach_unsupported`.
`workspace_id` is how two conversations share a machine. No fleet slot is
reserved for the launch: the workspace's machine is already counted.

What happens next depends on the machine. On a `ready` one the conversation's
adapter starts at once. On a parked, provisioning, failed or lost machine
nothing starts until the conversation's first prompt, which wakes a parked
machine, waits for a setup in progress, runs a failed setup again, or builds a
new machine after a loss. A launch with no prompt wakes nothing.

With a `channel_id`, a launch that names a `workspace_id` resumes only a
conversation in that workspace, and a launch without one never resumes a
conversation in a workspace.

**Conversations in one workspace can read and influence each other**: they
run as one user on one disk. Leave out `workspace_id` when a conversation must
be isolated. [About workspaces](concepts/workspaces.md#one-trust-boundary)
says what that boundary means.

### Set reasoning effort and fast mode

Runtimes that speak ACP offer session config options beyond the model. The two
that clients ask for are reasoning effort and fast mode:

| Runtime | Effort | Fast mode |
|---|---|---|
| `claude` | `effort` | `fast` |
| `codex` | `reasoning_effort` | `fast-mode` |

Set them on the agent, with `session_config`: a map of option id to a string
or a boolean. Every turn of the agent's conversations requests them. A
conversation copies the agent's options when it's created, so an edit to the
agent reaches the conversations you create after it, not the ones that
already exist. To run a conversation with other options, create an agent with
them, or edit the agent and start a new conversation.

```bash
curl --fail-with-body -X PUT \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"session_config":{"effort":"high","fast":true}}' \
  "$MANAGOAT_URL/api/agents/$AGENT_ID"
```

A conversation and a prompt don't take options of their own. A
`session_config` on `POST /api/conversations` or on
`POST /api/conversations/{id}/prompts` returns
`422 session_config_agent_only`. `null` and `{}` are accepted, because older
clients send them.

Before each prompt, after the model, Managoat applies the options through ACP
`session/set_config_option`:

- An option already in force isn't sent again.
- An option the runtime doesn't offer for the current model is skipped, and
  the turn continues. Claude offers `effort` only on models that support it.
- A value the runtime refuses fails the turn before the prompt is sent, with
  the runtime's own message.

Managoat checks only the shape of `session_config`: at most 16 options, ids of
letters, digits and `._:-`, and values that are a string or a boolean. A
malformed map is refused with `422`. `model` is refused, so use the `model`
field for it. Managoat doesn't check ids or values against a list, because
they differ by runtime and by model.

The runtime's permission mode is refused too: `mode` on `claude` and `codex`,
and `collaboration_mode` on `codex`. Those options include
`bypassPermissions` and `agent-full-access`, so an agent that set one could
widen its own `permission_policy`. Use `permission_policy` instead. An agent
that stored one of these ids before the refusal still runs, but Managoat
doesn't send that option. `session_config_options` doesn't list them.

A conversation's `session_config` is the options its turns request: its
agent's, as they were when it was created. To see what the current model
offers, read the conversation's `session_config_options`: the options the
runtime advertised before the latest prompt, each with its `id`, `category`,
`type`, `options` and `currentValue`. It's `null` until a turn has run. Each
turn records its options under `config_selection`:

- `requested`: the options the turn asked for;
- `applied`: each id mapped to the value the runtime confirmed;
- `skipped`: the ids the runtime didn't offer;
- `status` and `error`: set when the runtime refused a value.

A turn from before 2026-10-15 may also carry `restored`, from when a prompt
could set an option for one turn.

Each option also emits a `config` stage event on the conversation's stream:
`done` with `outcome` set to `applied` or `skipped`, or `failed`.

### Workers without Managoat API access

Set `sandbox_api_access` to `none` when the host must retain Managoat API
authority. Managoat omits its sandbox callback credential before provision
and on every wake or reattachment. The default, `owner`, retains existing
behavior.

This setting is immutable, like the conversation's sandbox. A channel resume
with a different explicit setting fails. `none` needs a sandbox of the
conversation's own, so a launch with it and a `workspace_id` is
`422 invalid_sandbox_api_access`.

Discover support in `GET /api/catalog` under `sandbox_api_access`. The host
can still send prompts and read events and files. The worker cannot use
Managoat MCP tools or connections that require its callback credential.

This option controls the credential Managoat creates. It does not remove
credentials supplied through environments, vaults, or custom MCP configuration.
Use a dedicated account containing only these workers for mutually untrusted
repositories. Keep the account's full API keys on the service host.

### Every conversation on one stream

The account event stream carries a conversation-change notification for
each conversation, so a conversation list stays live on one stream. It does
not replace a conversation's history, which is what a client reconciles
from after a reconnect.

It also carries a `workspace.status` event whenever one of the caller's
[workspaces](#workspaces) changes status, or an edit to a ready one's
environment moves its revision, with data `{workspace_id, name, status, error,
revision, built_from_revision, stale, changed_fields}`. The event has no id and is not
replayed after a reconnect, and `?streams=` does not filter it. A client that
reconnects reads the workspace again with `GET /api/workspaces/{id}`. While a
workspace's setup runs, `workspace.setup` events carry what it prints, in the
same way: see [Follow a workspace's setup](#follow-a-workspaces-setup).
[Follow every conversation on one stream](guides/http-api.md#follow-every-conversation-on-one-stream)
walks through it.

The Events operations in the [generated reference](/api/docs) define stream
selection, cursors, and framing. See [Build a chat app](build/index.md) for
how a client combines the list, transcript, and live stream.

## Workspaces

A workspace is a sandbox the caller keeps: set up once from an environment
and an optional vault, then any number of conversations launched into it with
`workspace_id`, each in its own working directory. Its name, environment,
vault and sandbox provider are fixed at create, though a setup reads the
environment and vault as they are then, so an edit reaches the next retry or
rebuild. Read
[About workspaces](concepts/workspaces.md) for the lifecycle, and
[Run several agents on one machine](guides/agents-in-one-workspace.md) for
the task. Every workspace route needs a full-scope key; a sandbox's own key is
`403 insufficient_scope`.

| Route | Does |
|---|---|
| `POST /api/workspaces` | Create one: `name` and `environment_id`, optional `vault_id` and `sandbox_provider`. Answers `201` with `status: "provisioning"` and starts the setup at once. |
| `GET /api/workspaces` | The caller's workspaces, newest first. `?implicit=true` adds the implicit ones, one per conversation launched without a workspace. |
| `GET /api/workspaces/{id}` | One workspace, with its machine's state, and `setup_step`, the step its setup is running while it is `provisioning`. |
| `GET /api/workspaces/{id}/setup-log` | What its last setup printed, step by step, redacted. See [Follow a workspace's setup](#follow-a-workspaces-setup). |
| `POST /api/workspaces/{id}/rebuild` | Destroy its machine, **with everything on its disk**, and set up a new one from the environment as it is now. Every conversation keeps its transcript and stays in the workspace. Optional body `{"interrupt": true}`. Answers `202` with `status: "provisioning"`. See [Rebuild a workspace](#rebuild-a-workspace). |
| `DELETE /api/workspaces/{id}` | Terminate every live conversation in it, keeping their transcripts, and destroy its machine. `204`. Not refused while conversations are running. |
| `POST /api/workspaces/{id}/retry` | Set a `failed` workspace up again, with no prompt, from its environment and vault as they are now. Answers `202` with `status: "provisioning"`; `workspace.status` events follow, as on create. |
| `GET /api/workspaces/{id}/files`, `/file`, `/diff`, `/git-status` | Read the workspace's current machine. See [Files, git status and git diff](#files-git-status-and-git-diff). |

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"app-box","environment_id":"YOUR_ENVIRONMENT_ID","vault_id":"YOUR_VAULT_ID"}' \
  "$MANAGOAT_URL/api/workspaces"
```

A workspace carries two statuses, and they answer different questions:

| Field | Values | Says |
|---|---|---|
| `status` | `provisioning`, `ready`, `failed` | Whether its machine's setup finished. `failed` comes with `error`, the failing step and the end of what it printed, redacted. A retry, or a rebuild after a loss, sets it back to `provisioning`. A park does not move it. |
| `sandbox_status` | `pending`, `starting`, `ready`, `suspended`, or `null` | What its current machine is doing. `suspended` is parked, and the next prompt wakes it. `null` means it has no live machine, after a loss or a failed setup, and the next prompt builds one. |

`sandbox_id` names the current machine, and is `null` when there is none. It
changes when a lost machine is rebuilt, so keep the workspace's id, not the
sandbox's. `implicit` is `true` for a conversation's own workspace, which has
no name and ends with its conversation; `DELETE` answers `404` for one.

A workspace also says whether its machine is behind its environment, since an
edit to the environment does not change a machine already built:

| Field | Says |
|---|---|
| `revision` | The environment's current revision. It changes on every edit of a field a machine is built from: `repositories`, `packages`, `setup_script`, `setup_timeout_seconds`, `env_vars`, `networking_type` and `networking_config`. Editing `name`, `metadata` or a secret leaves it alone; secrets reach a running machine without a rebuild. The environment itself carries the same `revision`. |
| `built_from_revision` | The revision the current machine was built from, or `null` when there is no live machine or it was built before Managoat recorded this. |
| `stale` | `true` when at least one of those fields differs from what the machine was built from. An edit that was then reverted moves `revision` but is not stale. |
| `changed_fields` | The names of the fields that differ, such as `["packages", "env_vars"]`. Only names: no value is ever sent, `env_vars` included. |

`stale` describes the machine as built. A conversation launched or woken after
an edit to `env_vars` or the networking fields already runs with the new
values; the machine's env file and the conversations already running keep
the old ones until a rebuild. See
[About workspaces](concepts/workspaces.md#what-a-workspace-is).

Each change of `status` on a workspace you created is a `workspace.status`
event on [the account event stream](#every-conversation-on-one-stream), and so
is every edit that moves the `revision` of a ready workspace's environment.
The event carries the four fields above, so a client can show "rebuild
needed" without polling. It is live only, so read the workspace after a
reconnect.

### Follow a workspace's setup

A setup runs these steps, each reported only when it has something to do:
`machine` (the provider creates it), `broker` (the egress broker's floor, CA
and relay), `environment` (the environment's and vault's variables written to
the machine), `packages`, `repositories`, `setup_script`, and
`runtime_template` (copying the runtime template into a conversation's config
home, when a conversation's prompt rebuilds a lost machine). The same steps
run on create, on a retry, on a rebuild after a loss and on
`POST /api/workspaces/{id}/rebuild`.

While it runs, each step is a series of `workspace.setup` events on
[the account event stream](#every-conversation-on-one-stream):

```json
{"workspace_id": "…", "sandbox_id": "…", "step": "packages", "status": "running",
 "lines": ["Reading package lists...", "Setting up jq (1.7.1-3)"], "omitted_lines": 0,
 "at": "2026-10-19T12:00:03.120Z"}
```

- One event as a step starts (`status: "running"`, no lines) and one as it
  ends (`succeeded` or `failed`, with any lines still held). A setup's first
  event is its `machine` step starting; `sandbox_id`, the machine it builds,
  is new for each setup, so a client clears what it showed when it changes.
- Output comes as **whole lines**, at most one event every 500 ms with at
  most 16 KiB of lines. Lines printed faster than that are left out of the
  event, oldest first, and counted in `omitted_lines`; they are still in the
  log below. A line is cut at 4 KiB, and a progress bar shows its last state.
- Lines are **redacted** like a transcript: every value of the environment
  and vault, each line of a value that spans lines, and the setup's own
  broker token are replaced with `[REDACTED]`. A value split across two
  chunks of output is still redacted, because a line is redacted only once
  it is whole. If Managoat cannot read the secrets, the step's output is
  withheld and one line says so.
- The events are live only, like `workspace.status`. A client that connects
  late reads `setup_step` on `GET /api/workspaces/{id}` and the log.

`GET /api/workspaces/{id}/setup-log` answers what the last setup printed:

```json
{"data": {"workspace_id": "…", "sandbox_id": "…", "status": "failed", "step": "setup_script",
  "started_at": "…", "finished_at": "…",
  "steps": [{"step": "machine", "status": "succeeded", "started_at": "…", "finished_at": "…",
             "output": "", "omitted_lines": 0, "omitted_bytes": 0},
            {"step": "setup_script", "status": "failed", "started_at": "…", "finished_at": "…",
             "output": "npm ERR! missing script: build\n", "omitted_lines": 0, "omitted_bytes": 0}]}}
```

Each setup replaces the previous one's log. Managoat keeps it, not the
machine, so it is there after a loss or a rebuild, and reading it never wakes
a parked machine. While the setup runs it is written as each step starts and
ends, and at most every 5 s in between. Each step keeps its last 64 KiB of
whole lines and the log 256 KiB in all, the earliest step giving way first;
`omitted_lines` and `omitted_bytes` say what a step dropped. `data` is `null`
until a setup has begun. An implicit workspace's setup is in its
conversation's transcript, so the route answers `404` for one.

| Refusal | When |
|---|---|
| `404 environment_not_found`, `404 vault_not_found` | `POST` names another account's environment or vault, or one that does not exist. |
| `422 validation_failed` | No `name` or `environment_id`, a `name` longer than 200 characters, or a `sandbox_provider` the instance does not know. |
| `422 sandbox_provider_disabled` | `sandbox_provider` names one this instance has not enabled, or a retry finds the workspace's provider no longer enabled. |
| `503 fleet_full` | Every sandbox slot on the provider is in use, on a create or a retry. Honor `Retry-After`. |
| `503 sandbox_unavailable` | A retry whose setup could not be started. The workspace stays `failed`; retry again. |
| `409 workspace_not_failed` | A retry of a workspace that is `provisioning` or `ready`. Follow one being set up instead. |
| `404 not_found` | Another account's workspace, on every route, and an implicit one on `DELETE` and on a retry. |
| `409 source_in_use_by_workspace` | `DELETE /api/environments/{id}` or `DELETE /api/vaults/{id}` on one a workspace was created from. Delete the workspace first. |

### Rebuild a workspace

An edit to the environment does not reach a machine already built (`stale`
says when one is behind). `POST /api/workspaces/{id}/rebuild` applies it: it
replaces the machine with a new one set up from the environment as it is now.

!!! warning "The disk is wiped"

    The rebuild destroys the workspace's machine and everything on its disk:
    uncommitted changes, unpushed commits, build output, files an agent wrote.
    Save what you need first. `GET /api/workspaces/{id}/diff` (and `files` and
    `file`) read the machine while it is `ready`.

What happens, in order:

1. Every conversation in the workspace moves to the new machine. Each keeps
   its transcript and stays in the workspace, but loses its runtime session,
   so its agent starts fresh, without memory of earlier turns, on its next
   prompt, which also sets its config home, skills and MCP configuration up
   again on the new machine. A conversation with a live process is told on
   its stream that the workspace is being rebuilt.
2. The old machine is destroyed.
3. The workspace goes `provisioning` and its new machine is set up, as on
   create, then `ready` or `failed`. Each change is a `workspace.status`
   event. Once it is `ready`, `built_from_revision` is the environment's
   current `revision` and `stale` is `false`.

The vault is not touched: its secrets reach the machine through the broker.
The rebuild is audited as `workspace.rebuilt`, with the caller.

| Refusal | When |
|---|---|
| `409 turns_running` | A conversation in the workspace has a running turn, or a prompt Managoat accepted that has not started its turn yet (its machine is still waking, say). `conversation_ids` names them. Wait for them to end, or send `{"interrupt": true}`, which ends each as `interrupted` (reason `machine_destroyed`), keeping its transcript. |
| `409 rebuild_in_progress` | The workspace is `provisioning`: its create, a retry, a rebuild after a loss or another rebuild is still building its machine. Wait for `ready` or `failed`. |
| `404 not_found` | Another account's workspace, or an implicit one, as for `DELETE`: an implicit workspace is a conversation's own sandbox. |
| `422 sandbox_provider_disabled` | The workspace's sandbox provider has been disabled since it was created (its credentials were removed). Nothing was changed: the machine, its disk and the conversations are as they were. Set the provider's credentials, or create a workspace on another provider. |
| `503 fleet_full` | Every sandbox slot on the provider is in use. Nothing was changed. |
| `503 sandbox_unavailable` | Another operation (a park, a wake) holds the machine right now. Nothing was changed; send it again shortly. |

```bash
curl --fail-with-body -X POST \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"interrupt":true}' \
  "$MANAGOAT_URL/api/workspaces/YOUR_WORKSPACE_ID/rebuild"
```

A workspace's machine parks when idle and wakes on the next prompt, like any
sandbox. At the `SANDBOX_MAX_LIFETIME_HOURS` ceiling it is parked rather than
destroyed, after its running turns are interrupted. So it lives until the
workspace is deleted or the provider loses it, and Managoat caps neither how
many workspaces an account keeps nor how long a parked one stays. See
[Sandbox lifetime and cost](guides/operate/sandbox-lifetime.md).

## Sandboxes

A sandbox is the machine that hosts a conversation. A conversation has one of
its own, unless it was launched into a [workspace](#workspaces), whose
machine several conversations share. The sandbox operations are read-only:
list them, and get one with its conversations.

See [Sandboxes](concepts/sandboxes.md) and
[Sandbox lifetime](guides/operate/sandbox-lifetime.md). The Sandboxes operations
in the [generated reference](/api/docs) describe the fields.

A sandbox's `machine_name` is the machine's name at its provider, whichever
provider that is. Pass `machine_name` when you start a conversation to choose
the name's suffix; Managoat keeps your account's prefix on it. The same value
also appears as `sprite_name`, the field's name from when Sprites was the only
provider, in sandbox responses, in audit events about a sandbox and in the
`reattach` stage event. A launch still accepts `sprite_name`, and refuses the
two with different values (`422 machine_name_conflict`). `sprite_name` is
deprecated: it is removed in the release that drops the aliases for the old,
pre-Managoat names,
planned for about 2026-11-15. Read `machine_name`.

A sandbox response includes `transition`, which is `null` when no machine
operation is unfinished. During a wake it is `resuming`. Sprites resumes only
finish after a no-op command succeeds; a provider lookup alone is not readiness.
Wait for `status: "ready"` **and** `transition: null` before reading files.
A failed or interrupted implicit wake can leave `ready` with `resuming`; retry
the conversation's wake to recover it.

### Files, git status and git diff

Use the sandbox read operations to inspect files and changes while an agent
works. A read never resumes a sandbox Managoat parked: a `suspended` one
answers `409 sandbox_not_ready`. A `ready` row with an unfinished resume,
park or destroy answers `503 sandbox_unavailable`. A `ready` sandbox whose provider put it to sleep by
itself, as Sprites does when nothing runs, is woken by the read, and the
provider bills for that time. See
[Reads and provider sleep](integrations/sandbox-contract.md#reads-and-provider-sleep).
A diff compares tracked content
only. To see a file the agent made and never staged, use the git status
operation. Its entry paths are relative to the repository root, not to the
sandbox home.

A path may lie under `/home/sprite`, the conversation's working directory, or
a repository mount of the sandbox's environment, by the same rule as a
[launch's `cwd`](#choose-the-working-directory). The environment is read as it
is at the time of the read, so a mount counts only where the machine has a
checkout there (a `.git`): a mount added after the machine was set up reads
nothing until a setup clones it. Paths are checked where they
physically lie, so a symlink that leads out of them, or a working directory or
mount replaced by a symlink to somewhere else, is refused.

The same four reads are served by workspace, at
`/api/workspaces/{id}/files`, `/file`, `/diff` and `/git-status`. They read the
workspace's current machine, so they keep working across a rebuild that
changes its `sandbox_id`. On a workspace's machine, by either route, a
relative path resolves from `/home/sprite`, a path may lie under
`/home/sprite` or the working directory of any live conversation in the
workspace, and the output is redacted with the workspace's environment and
vault and every live conversation's credentials. A workspace with no machine
at all answers `404`; one whose machine is parked, being set up, failed or
lost answers `409 sandbox_not_ready` with that `status`.

The [generated reference](/api/docs) defines path confinement, byte limits,
truncation, encoding, comparison options, and the untracked modes. Check
truncation before you show a response as a complete file. Treat redacted
output as a display value.

## Search

Use account-scoped search to find resources and conversation content the caller
can access. Search results are navigation aids; fetch the selected resource
before you act on its current state. See Search in the
[generated reference](/api/docs).

## A long-lived agent, or one on a clock

Managoat has no team and no scheduler of its own; both were removed. An app
that wants one agent it talks to for weeks keeps that conversation's id and
sends each message to `POST /api/conversations/{id}/prompts`. A suspended
conversation wakes on the prompt. To find it again by a key of your own,
create it with a `channel_id` (a Slack channel, a ticket number): a later
create with the same `channel_id` resumes it, and one that has ended is
replaced under the same binding.

An app that wants work on a clock runs its own cron and sends the prompt
when it fires. A `503 fleet_full` or `sandbox_unavailable` carries
`Retry-After`; retry after it. See
[Keep one agent for weeks, or run on a clock](guides/http-api.md#keep-one-agent-for-weeks-or-run-on-a-clock).

A browser client on another origin needs a registered OAuth client or an
`API_CORS_ORIGINS` entry. Read [configuration](configuration.md). A bearer
key is the one credential that crosses an origin.

## Admin

`/api/admin/*` needs an account with the admin role and an admin key, a key
with `admin` among its `scopes`. No other key an admin holds works there: not
a key from `managoat auth login` or `POST /api/auth/token`, not the token an
app receives from Sign in with Managoat, and not one minted at
`POST /api/auth/api-keys`. Each of those gets `403` with
`error: "admin_key_required"`.

Mint an admin key as the admin, under **Account → API keys** with **Admin key**
checked, or with a release task (see
[Run a release task](guides/operate/run-a-release-task.md)):

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.create_admin_key("ops@example.com", "provisioner")'
```

The release task prints the key once. Give an admin key to one place, such
as a platform's provisioner, and revoke it there when you rotate it. Taking
the admin role away stops its admin keys working.

Use tenant-scoped resource reads for ordinary application work. An operator's
metadata access does not grant access to another tenant's prompt or output.

See Admin in the [generated reference](/api/docs) for account controls,
sandbox maintenance, and privilege-trail events.

## Audit

Use the audit trail to investigate who changed a resource and when.
A transcript describes agent work; the audit trail describes account and
resource actions. The [generated reference](/api/docs) defines filters,
pagination, and returned metadata.

## Error responses

Every JSON error status declares one schema, `Error`. Its `error` field is
the machine-readable code to branch on. The other fields accompany particular
codes and are absent otherwise: `message` is a sentence for a human, `errors`
holds field validation messages beside `validation_failed`. A refusal for a
key's scope is `403` with `error: "insufficient_scope"` and
`required_scope: "full"`, the scope that is allowed; its `reason` repeats the
code for clients written when `error` was a sentence. Some older refusals
still put a sentence in `error`, with the code, when there is one, in
`reason`. Among them: the key-authentication refusals (`401`, and `403` for
an unverified email), whose `reason` is `api_key_invalid`,
`api_key_expired`, `api_key_revoked` or `email_unverified`; an unmatched
`/api` path, `404` with `reason: "not_found"`; a rejected inference
credential, with a `reason` such as `invalid` or `timeout`; and the
missing-field and not-found refusals of the `/api/auth` routes, which have
no code. A 406 is the one
exception: content negotiation fails before any operation runs and renders
`{"errors": {"detail": "Not Acceptable"}}`.

The [generated reference](/api/docs) declares shared pipeline errors alongside
controller responses. Reconcile state after a timeout before you retry a
mutation. Honor retry guidance where present, and refresh credentials when
the response identifies an expired or revoked key.

## LLM-native discovery

Use `/llms.txt` for a short introduction, `/llms-full.txt` for the manual,
and `/skill` for an editor skill. They are published with this manual at
`https://managoat.com`, and an instance redirects its own copies of those
paths there. Use the instance's `/api/openapi.json` for machine-readable
endpoint contracts.
See [LLM integration](llm-integration.md) for integration guidance.
