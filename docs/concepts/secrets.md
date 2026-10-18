# Where a secret comes from

This page explains the whole chain, from the key on the server to the string
an agent's process reads. To put a value somewhere, read
[About environments](environment.md) and [About vaults](vault.md). For the
operator side, read
[Back up and restore](../guides/operate/back-up-and-restore.md).

## Four hops

You type a secret into Managoat. Managoat transforms it four times before an
agent sees it.

```
MASTER_SECRETS_KEY          (the platform key, never in the database)
        |  wraps
        v
per-tenant DEK              (one per user, stored wrapped)
        |  encrypts
        v
the stored value            (AES-256-GCM, at rest)
        |  merged at spawn
        v
environment + vault         (vault wins on collision)
        |  ${VAR} substitution
        v
the process environment     (inside the sandbox)
```

Each hop exists for a different reason. To know which hop you look at is
usually the difference between a five-minute problem and an afternoon.

## Hop 1: the master key wraps a key for each tenant

Each tenant has a data encryption key, a DEK. The DEK is what encrypts that
tenant's values.

Managoat does not store the DEK in the clear. It wraps the DEK with AES-256-GCM
under `MASTER_SECRETS_KEY`, then stores it in `user_data_keys.wrapped_key`.

`MASTER_SECRETS_KEY` is a 32-byte binary, base64url-encoded, and you set it at
runtime. **It is deliberately not in the database.** That is the whole point of
the arrangement, and it is also why a database backup on its own is worth
nothing. Read
[Back up and restore](../guides/operate/back-up-and-restore.md).

In dev and test, Managoat derives a deterministic key from a fixed phrase.
Production refuses to boot without a true one.

If the shape feels familiar, HashiCorp Vault uses the same one. The unseal key
wraps the root key, which wraps the keyring, which wraps the data.
That analogy holds here. Almost nothing else about the word "vault" does. Read
[About vaults](vault.md).

## Hop 2: the DEK encrypts the value

The DEK has a short and explicit lifecycle.

1. Generate a DEK at user creation, wrap it, and store it.
2. Load the tenant key at conversation start, then unwrap the DEK.
3. Hold the unwrapped DEK in the conversation process's own state while the
   conversation runs. Pass it to each encrypt and decrypt explicitly.
4. Drop the DEK from that state when the conversation ends.

Managoat passes the DEK explicitly and does not look it up. That makes tenant
isolation a property of the call, and not a convention. A function that needs a
DEK cannot use somebody else's by accident.

From the outside, values are write-only. A list of a vault or an environment
returns keys and timestamps. No endpoint returns a value, to anybody, and the
owner is nobody special.

## Hop 3: environment and vault merge

A conversation starts. At that moment Managoat resolves the full set.

```
environment secrets  --merge-->  vault secrets  -->  the sandbox
                                       ^
                               wins on collision
```

The merge happens once, at spawn. Edit either one afterwards and the edit does
not reach a sandbox that already runs. A brokered secret is the exception.
When you write or delete a secret in an environment or a vault, Managoat
gives the broker the new value for every running conversation that uses it,
even during a turn. The turn keeps running. The broker reads the value when
the sandbox opens its next connection, so a rotated `GITHUB_TOKEN` works on
the next `git push` of the same turn. The update runs moments after the write
returns, without waiting for the turn, and a write that races a push can miss
that push. A connection that is already open keeps the old value until it
closes.
Plain HTTP requests check the current session on every request. Each server
keeps a local cache of decrypted rules for up to 30 seconds, with at most
1024 entries of at most 64 KiB each. A warm lookup still reads the session
and wrapped tenant key from the database: revocation, expiry, rule rotation
and tenant-key changes take effect without waiting for cache expiry or a
message from another server. Database or cache unavailability refuses the
request; cached rules never substitute for that authority check. A restart
empties the cache. These limits bound plaintext retention; they do not
extend a session's authorization lifetime.

Managoat also reads both again before each turn, which covers a conversation
whose machine was parked or whose update failed. An unbrokered secret is in
the sandbox's process environment, so only a new conversation sees an edit.
Inference credentials
have a separate source binding: replacing the selected value requires a new
selection before another turn, even when that value came from a vault. The section
[Bindings](#bindings) says which
secrets the broker holds.

A conversation can name a different environment from its agent's default, and
it can attach a vault. The agent's `allowed_environment_ids` and
`allowed_vault_ids` scope both.

Managoat merges the non-secret `env_vars` from the environment in as well. It
stores those in the clear and returns them in the clear. So the difference
between `env_vars` and `secrets` is about who can read a value back. It is not
about who can use one.

Every sandbox also gets a small set of variables from the egress broker. These divide into two halves with opposite
precedence.

The certificate variables (`SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`,
`CARGO_HTTP_CAINFO`, `GIT_SSL_CAINFO`, `HEX_CACERTS_PATH`, `NODE_EXTRA_CA_CERTS` and
`UV_NATIVE_TLS`) are defaults.
An `env_vars` entry or a secret with the same name replaces them. You can
point a tool at a different trust store. That store must hold the broker
root, or the agent cannot reach a brokered host.

The proxy variables (`HTTPS_PROXY`, `HTTP_PROXY`, their lower case twins and
`NO_PROXY`) always win in the environment an agent runs in. The broker is
where Managoat attaches credentials to egress and makes a record of it.

Managoat keeps the four proxy URL names out of `/home/sprite/.env` because
the broker address contains a conversation's session token. This filter
applies to every assignment with one of those names, including your own
`env_vars` or secrets. The process still receives the broker's proxy values.

Inference auth inputs also stay out of that shared file. This includes
`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`,
`GEMINI_API_KEY` and its alias
`GOOGLE_GENERATIVE_AI_API_KEY`. The rule applies whether a value comes from
your inference credentials, an environment or a vault.

Managoat passes auth inputs to each process through its environment. The
`setup_script` receives them too. A later shell cannot recover these values
with `source .env`; use the environment inherited by the script. Filtering
this file does not isolate processes from each other or remove runtime-owned
auth files such as Codex's `auth.json`.

## Inference credentials

Your provider keys live in your account's **inference credentials**: up to
four values, an Anthropic key, a Claude OAuth token, an OpenAI key and a
Gemini key. An account holds one set of these. The first provider write
creates it.

A tenant environment or vault secret can override a static credential of the
same kind. Vault wins over environment; supported aliases resolve to the
same kind. Conflicting alias values within one layer are refused. The
runtime then selects the kind it supports: Claude prefers its OAuth token
over an API key. The model provider bills whoever owns the resolved
source, which is always you: the deployment holds no inference key of its
own.

Each conversation binds its resolved source, revision, model, runtime,
environment and vault. Each turn records the source that served it. Before
each turn, and on wake and resume, Managoat resolves the source again and
compares it with the binding.

A different source is refused with `409 inference_source_changed` rather
than silently replaced with another key. A source is different when it is
read from another place: another environment, vault or secret row, another
credential kind, a deleted credential, or a secret deleted and created again.
Start a new conversation when the binding can no longer be used.

A key rotated in place keeps its source. Editing the value of a bound
credential, environment secret, vault secret or `env_vars` entry keeps the
conversation running, and its next turn uses the new value:

The broker holds the value, so Managoat rewrites the broker's rules and the
agent's process keeps running. A rotated environment or vault secret reaches
a turn that is already running. A rotated inference credential reaches the
next turn.

Codex reads its API key from `$CODEX_HOME/auth.json`, in the conversation's
config home, not from its environment.
That file holds a placeholder, so it stays as it is and the broker's rules
carry the new key.

A Codex conversation on a ChatGPT subscription keeps its own rule: it follows
token refreshes and asks you to reconnect when the subscription changes.

Each `env_vars` entry has its own revision, so editing one variable does not
count as a change to a credential stored in another. Saving the value a
credential already holds changes nothing.

The credential is not part of sandbox identity. A sandbox serves exactly one
conversation, so that conversation's bound source is the whole check, and a
Codex sandbox's auth directory belongs to that one conversation alone. A
different source needs a new conversation, which gets a new sandbox. Use
separate accounts when different customers need isolation.

Set your keys at `/account/inference-credentials`, or over the API under
`/api/account/inference-credentials`.

## Hop 4: substitution, then the process

An agent config string takes `${VAR}` interpolation, which Managoat resolves
against the merged map. That is how an MCP server declaration gets a
credential, with no credential written into the agent.

```yaml
mcp_servers:
  github:
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PAT}"
```

Substitution is recursive, so it reaches inside maps and lists. It is also
fail-complete. Managoat reports each absent variable at once, and not one for
each attempt. The alternative is a config you fix one name at a time.

`$$` is a literal `$`.

## What the chain does not do

**No automatic static-key rotation.** Managoat does not replace provider keys
for you. A source check can refuse a changed inference credential, but it does
not renew that credential with its provider.

**No revocation of a live process.** Remove a vault from an agent's allowlist,
and no later conversation can attach it. A sandbox that already runs keeps what
you gave it. By then the value sits in a process environment, on a machine.

**No read audit.** Managoat audits the write, by key, and never by
value. It cannot audit the read, because that read happens in the sandbox.

**No protection against the agent.** The code in that sandbox can read
everything in the merged map. That is why the value is there at all. Scope the
credential. Do not scope the agent.

## Hop 5, a hop back: Managoat scrubs the output

Managoat writes everything a sandbox sends to stdout or stderr into
`log_events`, word for word, and streams it over SSE. That table has none of
the envelope encryption above, and it outlives the conversation.

So an `env`, a `set -x`, a `cat .env` in a setup script, or an agent that
prints its own environment would write plaintext credentials into Postgres.
Managoat removes each known secret value from the output before it stores it.

Two results matter.

**A smoke test that echoes a secret prints `[REDACTED]`.** That is the system
at work. To confirm that a value arrived, ask for a character count instead.

**There is a length floor of 8 bytes.** A sandbox environment holds many short
non-secrets, such as `true`, `1`, a port or a region. To redact those would
turn logs into noise and protect nothing. The case this misses is a short
password that somebody chose on purpose. Do not choose one.

**Only the secrets are scrubbed.** The values that come from a credential go
into the registry: your environment and vault values, the inference credential,
the callback token and the values the broker holds. Managoat's own identifiers
do not. The conversation id, the sandbox id and the sandbox URL stay in the
output, where you can read them.

The values live in a registry that the one log writer reads. Managoat does not
pass them to each caller. The scrubber this replaced ran on the HTTPS clone
path and not on the SSH one. A redaction that each caller must remember is a
redaction that a new caller will one day forget.

## Bindings

Every conversation runs behind the egress credential broker. The operator
sets it up; read the
[configuration reference](../configuration.md#sandboxes).

A secret can have one or more **bindings**. A binding names a host. By default the broker
replaces the secret's placeholder wherever it appears in a request to that
host. The agent uses the placeholder as it would use the secret, in any
header, in the query or in the path. It never has to know the shape the API
wants. The broker does not rewrite a request body.
Four other shapes are there for an API the agent cannot address itself. A
bearer header. Basic auth with a username of yours, which the client encodes
before it leaves. A header with an optional prefix. Custom headers with
`{{ KEY }}` in them.

A secret with a binding does not enter the sandbox. The agent sees a
placeholder, `__stripe_secret_key__` for `STRIPE_SECRET_KEY`. The broker puts
the real value on each request to the bound host. A secret with no binding
enters the sandbox in the clear. The four hops above describe that path.
`GITHUB_TOKEN` and `GH_TOKEN` have built-in bindings to `api.github.com` (API),
`api.githubcopilot.com` (MCP), and `github.com` (Git over HTTPS). These apply
until you make one of your own. The runtime's inference credential has one
too. `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY` go to
`api.anthropic.com`, `OPENAI_API_KEY` to `api.openai.com`, and
`GEMINI_API_KEY` to `generativelanguage.googleapis.com`. The runtime sees a
placeholder that keeps the vendor's prefix, such as
`sk-ant-oat01-__claude_code_oauth_token__`.

After a conversation, `GET /api/conversations/:id/egress` lists what left the
sandbox through the broker. URL paths, queries and fragments are withheld.
The `path` field contains `/[REDACTED]`, including for older rows. A credential
can be part of any path segment, even the first. Each row shows the host, the
binding that matched
and so the credential attached, the status, and the latency. A row for a host
you allowed, but bound no credential to, names no binding. A refused host
shows the refusal. The broker writes a row when the request ends, so a long
stream gets its row at the end of the stream. The latency is the duration of
the whole request, not the time to the first byte. The list stays for `BROKER_LOG_RETENTION_HOURS` after the
conversation ends. The route needs a key with full scope. The token a sandbox
holds cannot read it. Read the
[Conversations section](../api.md#conversations) of the API reference.

You manage bindings on Account, then Credential bindings, or with
`GET /api/secret-bindings` and its siblings, in the
[Secret bindings section](../api.md#secret-bindings) of the API reference.
A binding is about the name of
a secret. So it applies to every environment and vault that holds a secret
of that name.

## Where to go next

- [About environments](environment.md), the baseline half of the merge.
- [About vaults](vault.md), the override half.
- [Back up and restore](../guides/operate/back-up-and-restore.md), because
  hop 1 decides what a backup is worth.
- [Architecture](../architecture.md), for where each piece runs.
