---
type: ADR
title: "Egress credential brokerage: the sandbox holds placeholders, the broker holds the credential"
description: "Every conversation is brokered: outbound HTTP credentials are attached at a forward proxy the sandbox reaches over HTTPS_PROXY, so the sandbox holds only placeholders."
tags: [security, secrets, sandbox, egress, governance]
status: stable
adr: "0019"
adr_status: "Accepted"
date: 2026-08-14
generated: { by: human:jhgaylor, at: 2026-08-14T04:45:00-04:00 }
verified: { by: claude, at: 2026-10-15T00:00:00-04:00 }
stale_after: 2027-03-03
---

# 0019 — Egress credential brokerage

**Status:** Accepted, 2026-08-14. Built and live in production. Every
conversation on every deployment is brokered, and a release without
`BROKER_LISTEN_PORT` and `BROKER_PROXY_URL` does not boot. The broker is
`Managoat.Broker` (the `managoat_broker` hex library), run inside the
Managoat server. Two parts are not built: the `unbrokerable` label of §7 and
content rewriting at the proxy (§10).

## Context

### The sandbox held every secret, and could reach anything

Before this decision two facts composed badly. Environment and vault secrets
were decrypted with the tenant DEK and appended to the sandbox's environment
verbatim, with a second copy in `/home/sprite/.env`. And egress was open
unless a tenant said otherwise: `networking_type` defaults to `unrestricted`,
which made no sandbox call at all. A conversation was a process running
untrusted model output, holding every credential its tenant configured, on a
host that could reach anywhere. A prompt injection did not need an exploit
chain; it needed `curl`.

### The control existed and nobody used it

Production, measured twice:

| | 2026-08-14 | 2026-08-24 |
|---|---|---|
| Environments with `networking_type = 'limited'` | 0 | 0 |
| Environments with `networking_type = 'unrestricted'` | 20 | 36 |
| Environment secrets | 56 | 79 |
| Vault secrets | 22 | 50 |
| Inference credentials | 3 | 6 |
| Plaintext credentials reaching sandboxes | 78 | 135 |

Ten days, no change in posture, 73% more exposure. Two tenants (of 128
accounts) held every one of those secrets. Grouped by key name, 73 of the 129
stored secrets were token-shaped (`GITHUB_TOKEN` ×31, `RENDER_API_KEY`,
`POSTHOG_API_KEY`, `HONEYCOMB_API_KEY`, …), 9 were URLs or DSNs and 40 were
not secrets at all, so a scheme assuming every row is a brokerable HTTP
credential would be wrong about a third of them. Some can never be brokered:
`BUZZ_PRIVATE_KEY` (×6) signed Nostr events in-process and spoke to a relay
over a WebSocket.

`NetworkPolicy` is intent-level and default-deny, and every provider
advertises `:network_policy` ([0018](0018-sandbox-provider-abstraction.md)).
It protected none of those secrets, because using it required a tenant to
know it existed, choose `limited` and enumerate every host the agent would
need. A safety default that requires configuration is not a safety default.
Any fix that leaves the safe posture opt-in produces the same table a year
later.

`Fountain.Conversations.Redaction` scrubs secret values (8 bytes or more)
from log events at the single write path. It protects the transcript, not
the credential: it does nothing about a secret sent over a socket.

### A base-URL broker reaches only inference

[0016](0016-governance-as-an-acp-proxy.md) §4 named the problem ("we hand the
key to the thing we are governing") and proposed a broker reached by pointing
each runtime's provider base URL at the server. That reaches only inference,
3 of the 78 secrets, and depends on each runtime's config surface, which is
why 0016 needed a per-runtime survey.

A TLS-intercepting forward proxy does not. `HTTPS_PROXY` is honoured by the
HTTP client stack, not by the application, so it covers every runtime, CLI,
MCP server and `curl` in a setup script without their cooperation. The agent
holds a placeholder (`__github_token__`) and the real credential is attached
at the proxy. [Agent Vault](https://github.com/Infisical/agent-vault) was such
a proxy and was the first implementation (§8).

This is the one governance control with no dependency on ACP. It absorbs
0016's gate 3: inference credentials need no base-URL survey.

## Decision

The sandbox receives placeholders and a proxy address for brokerable HTTP
credentials, and the only host it may reach is the broker. Non-HTTP and
unbound secrets remain exceptions.

### 1. Placeholders replace plaintext

`Fountain.Broker.split/2` divides a conversation's secrets into what the
sandbox gets and what the broker gets. Brokered are:

- a secret with an enabled binding (`Fountain.SecretBindings`): per tenant,
  per secret name, one row per host with an auth shape (bearer, basic with a
  username, API-key header with optional prefix, custom headers). Managed at
  `/account/bindings` and `/api/secret-bindings`;
- `GITHUB_TOKEN` and `GH_TOKEN` with no binding of their own, bound by a
  built-in catalog to `api.github.com` (bearer) and `github.com` (basic
  `x-access-token`);
- the runtime's inference credential (`CLAUDE_CODE_OAUTH_TOKEN` or
  `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`), handed to the
  runtime as a vendor-shaped placeholder (`sk-ant-oat01-__claude_code_oauth_token__`)
  with an implicit binding to the provider's host. `Claude.fall_back_to_api_key/2`,
  which switches a running conversation to an API key, re-prepares the
  broker session rather than injecting the key.

Every other secret still enters the sandbox as a value: encrypted storage
does not imply brokered delivery. Environment and vault secrets are the same
case; brokering happens after the merge, so vault-wins-on-collision is
unchanged. `environments.env_vars` is injected verbatim and is not encrypted
at rest, so it is the wrong home for a credential regardless.

Storage does not change. `Fountain.Crypto`, the per-tenant DEK and the
`secrets` and `vault_secrets` tables remain the system of record the broker
is loaded from. What changes is custody at the far end.

Every service carries a substitution for its key: the proxy replaces the
placeholder wherever it appears in a header value or the request target
(path and query), so the agent sends whatever shape the API wants. That one
mechanism covers Anthropic's `x-api-key`, the OAuth bearer, OpenAI's bearer,
Gemini's `x-goog-api-key`, a `?key=` parameter and the bot-API shape
`/bot<token>/sendMessage`. A binding's explicit shape additionally sets a
header the agent did not send; `basic` is the one shape substitution cannot
reach, because the client encodes the value. The credential is written byte
for byte, so one needing percent-encoding is declared already encoded, and
one that cannot be written where its placeholder sits (a space or control
character in a target, CR or LF in a header) is refused with 403.

### 2. The network floor is `allow: [broker]`, and it is not optional

Every sandbox gets `%NetworkPolicy{allow: [broker_host]}`
(`Provisioning.apply_broker_floor/3`): written on cold provision, and
asserted on every reattach (a wake, or the first turn after a restart).

A write is not free on Sprites. It resets the guest's open TCP flows when it
takes effect, which on production can be a couple of seconds after the API
answers. A second write about a second after the first left 6 of 6 test
sprites cutting 1–2.5 % of their flows for the 50 s they were watched
(#2964). Three rules follow from that:

- **On Sprites the floor is the first thing written.** A cold provision
  starts the write when the machine exists, beside the host-side steps
  (callback key, sandbox URL, broker session), and awaits it before the
  sandbox config, whose CA install starts the transport relay and its
  readiness handshake to the broker. Nothing before that opens a guest
  connection, so the floor's write still precedes anything that dials out.
  Its effect can lag the answer, so the relay handshake may meet it. A cut
  handshake costs up to the relay's 10 s setup timeout, then a retry. E2B
  keeps the old order: config, then the floor, then the packages.
- **The first prompt waits for the floor to settle.** A Sprites provision or
  reattach does not finish until 2 s after its floor step returned
  (`Fountain.Conversations.FloorSettle`). The wait is measured from that
  moment, so it adds nothing when the steps after the floor already took
  that long.
  - On 2026-10-17 all 29 stalled cold first turns had sent their first model
    request 1.76–2.14 s after the write returned. None of about 2,700 whose
    request went 2.2 s or later did.
  - The request follows the prompt by at least 1.07 s (3,138 first turns that
    day), so it lands at least about 3.07 s after the write. That is 0.93 s
    past the last stall.
  - Replayed over that day's provisions with the floor written first, the
    wait adds a median 0.15 s (p90 0.45 s). A 3 s window would have added a
    median 1.15 s.
  - Each hold logs `fountain.floor.settle` with the gap and the time added.
  - The 2 s is provisional. The stall band was measured under the old order,
    and the write now overlaps other work. Revisit it against the logged
    gaps and the first-turn stall rate after the change ships.
  - A reattach holds only when it wrote the floor, or found it in force on a
    machine created in the last minute (a workspace setup's write). A wake
    of an older machine is not held.
- **A reattach does not rewrite a floor already in force.** It reads the
  policy back where the adapter can (`Sandbox.ensure_network_policy/2`;
  Sprites does) and writes only when the provider does not report exactly
  the floor. A failed, slow or raising read counts as a mismatch. The
  provider's status does not decide it: Sprites reports a sprite it has just
  created and run a command on as `cold`. A status gate therefore rewrote,
  a second later, the floor a workspace setup had just written. The skip
  trusts the provider's stored policy to be the one it enforces.
  - Measured 2026-10-19 on a test sprite with the floor written once and
    then left idle 12 minutes: its uptime showed about 100 s suspended, and
    it was restored with the same boot. After that wake, non-broker hosts
    were still refused with no rewrite.
  - A wake that boots afresh (a new boot ID) was not tested.

The floor is not a default a tenant may widen: placeholders are
worthless to an attacker only if the attacker cannot reach an arbitrary host
to try them against. `Provisioning.check_broker_support/2` refuses a provider
without `:network_policy` with `{:broker, :backend_lacks_network_policy}`.
Sprites and E2B both advertise it ([0071](0071-hosted-sandbox-providers-only.md)),
so this refusal exists for a future adapter. On reattach a policy failure
stops the wake for retry and does not retire the sandbox.

### 3. `networking_type` is enforced at the broker

The sandbox floor is identical for both values; what differs is the broker
session's unmatched-host policy (`Broker.network_for/1`):

- `unrestricted`: passthrough. The agent may reach any host, but only with
  the credentials it was granted. Unrestricted reach, brokered credentials.
- `limited`: deny. `allowed_hosts` become passthrough services, and an
  unlisted host gets 403 at the broker. A host that carries a credential
  binding keeps its credential service rather than gaining a passthrough
  twin. An IPv6 literal in `allowed_hosts` is bracketed before it becomes a
  pattern, since an unbracketed literal would match nothing. Under `limited`
  the tenant lists what provisioning and the runtime need (the package
  registry, the model host).

This changed the meaning of an existing field. It was safe only because no
tenant depended on the old `limited` behaviour. The broker is now the only
place `limited` is enforced.

### 4. The placeholder is a plausibility rule, not a lookup key

The proxy attaches a credential by matching the service for the host and
substituting, not by looking up the placeholder string. The placeholder only
has to be stable for the conversation and recognisable to the client that
validates it (`Broker.placeholder/1`, `placeholder?/2`). A placeholder that
reaches an origin unreplaced fails as a bad credential at the origin.

### 5. One broker session per conversation

A session (`Fountain.Broker.Native.Sessions`, table `broker_sessions`) stores
a token hash, the conversation and user ids, an expiry and the rules as one
ciphertext under the tenant DEK. The binding is on the token: it resolves to
its own conversation's credentials and nothing else, so no session can broker
another conversation's or another tenant's. Per conversation, not per tenant,
for two reasons found building it: two conversations with different
`GITHUB_TOKEN`s would collide on one key with last write winning, and the
request log needs a session whose identity is the conversation.

The token travels inside `HTTPS_PROXY`, which is process-only
(`Fountain.Conversations.Identity`'s `@process_only`) and never reaches
`/home/sprite/.env`. It lives six hours (`:broker_session_ttl_seconds`); the
refresh before each turn re-mints a session that is close to expiry, so a
parked and woken sandbox does not carry a live token past its TTL.

A secret may change while a conversation is open. The value the broker holds
is a snapshot; the placeholder the sandbox carries never changes. Before each
turn the conversation re-reads its environment and vault secrets and rewrites
the session's rules when a value differs, and a secret write rewrites a live
conversation's rules mid-turn (#2548). A failed refresh leaves the old value,
so the turn fails at the provider with a reason rather than silently here. A
changed value is never sent to the sandbox.

### 6. Fail closed

When the broker does not answer `/health`, `check_broker_support/2` publishes
a `broker` stage failure naming it and the conversation does not start. There
is no plaintext fallback and no sandbox without the floor. A control with a
fallback that disables it is not a control. A failed wake preserves the disk.
CA installation on reattach is best effort; a failure is logged and may fail
the next turn.

### 7. Non-HTTP credentials are out of scope, and should be labelled (not built)

An HTTP proxy brokers HTTP. A signing key used in-process, a credential for
raw TCP or a WebSocket protocol's payload stays a plaintext long-lived value
in the sandbox. Repository clones are HTTPS-only, so no deploy key is needed
for them. A credential that cannot be brokered should be labelled unbrokered
in the UI and the API rather than counted under a claim that covers it. This
is not built: neither secret schema has an `unbrokerable` field and there is
no classification control. The honest claim is "outbound HTTP credentials
with a binding, the GitHub catalog defaults and inference credentials are
brokered".

### 8. The broker is our own library

The broker is `Managoat.Broker`, a hex library pinned patch-level in
`apps/fountain/mix.exs` (pre-1.0 it breaks in minor bumps, so a minor arrives
only by editing that line). It holds no reference to the server and takes the
listen port, the session store and the CA seed as start arguments.
`Fountain.Broker` is the policy seam (catalog, placeholder rule, split,
sandbox env, session lifecycle) and `Fountain.Broker.Native` runs the
listener in-process; it runs nowhere else ([0093](0093-the-broker-runs-inside-managoat.md)).
The CA root is derived from `BROKER_CA_SEED` when it is set, 32 random bytes
generated where Managoat runs and given to nothing else, and otherwise from a
seed HKDF-derived from the master key (`"managoat-broker-ca"`). Nothing is stored.

Agent Vault was the first implementation, chosen over Infisical's Agent Proxy
because Agent Proxy fetches credentials from an Infisical project, which
would have made a second custodian's API a hard dependency of provisioning.
It was replaced by a native proxy (#1148, adopted as the library on #1340)
that had parity with it except for three deliberate deviations:

- No WebSocket frame rewriting. Substitution reaches the upgrade request;
  frames after it are piped. Rewriting them correctly needs a frame-aware
  proxy, and no binding sends a credential inside a frame.
- No request-body substitution. Bodies are streamed, not materialised, which
  is what lets large uploads through, and no binding needs it.
- The label half of the proxy credential is unchecked. The random token is
  the whole binding; the label exists because git refuses a proxy URL with a
  user and no password.

The native proxy has no auth-failure rate limiter. Agent Vault's limiter was
keyed by TCP peer address, sandboxes reach the broker through a few shared
NAT addresses, and one tenant's bad-credential burst returned 429 to
another's valid clone (#1206). A limiter keyed on something better than the
peer address is a library decision (managoat/managoat_broker#22), not one
made here.

### 9. Brokering is a property of the secret, not a setting

There is no per-tenant or per-environment toggle and no deployment off
switch. The cost of an opt-in is not the boolean: every secret-touching path
carries two shapes forever, and the safe one is the one nobody selects, which
is the table in Context. Brokerage was rolled out as an operator ratchet
(one tenant, then `BROKER_TENANTS=*`), then kept as a deployment switch;
both are gone (History). What decides delivery is the secret: its bindings,
the catalog and the inference rules.

### 10. The broker reads bodies, and does not rewrite them

TLS interception means the broker sees plaintext prompts and responses. That
is accepted deliberately, because content inspection is wanted. Rewriting
does not belong at the proxy, where model traffic is bytes (four dialects,
SSE frames, tool-call deltas, compression). For ACP-borne traffic it belongs
at the ACP seam; for everything else, a content proxy chained in front of the
broker could sit there, since the broker accepts absolute-form HTTP and the
inner hop need not be intercepted twice. Neither is built.

### 11. Topology

The broker listens on `BROKER_LISTEN_PORT` inside the server, and sandboxes
dial `BROKER_PROXY_URL`. Both are required at boot. The proxy URL carries
both userinfo fields (`http://<token>:<label>@host:port`): with the token
alone curl works but git prompts for a proxy password and aborts. Git is
pinned to `http.proxyAuthMethod basic`, because libcurl's `anyauth` cannot
send a credential before seeing a challenge. The broker CA goes into the OS
trust store with `update-ca-certificates` (through `sudo`, the trust
directory being root-owned), which satisfies curl, git and npm at once, plus
`NODE_EXTRA_CA_CERTS` for Node; per-tool variables pointing at a missing
file break the tool with no fallback.

Hosted sandboxes dial the broker from the internet, so `BROKER_PROXY_URL`
needs a TCP or TLS ingress. An HTTP-only tunnel does not carry `CONNECT`.
The maintainer's instance publishes `broker.inevitable.fyi` through a Traefik
`IngressRouteTCP` (`HostSNI`, TLS terminated at Traefik on 443, plain TCP to
the listener). The shipped compose file sets and publishes the listen port;
reachability is the operator's job, and Managoat ships no tunnel.

For HTTPS endpoints, [0094](0094-sandbox-broker-transport-relay.md) places a
loopback HTTP transport relay in the sandbox. Client proxy variables carry
the same session credential but name that local listener; the relay carries
their bytes over verified TLS to `BROKER_PROXY_URL`. The broker's policy and
the provider's broker-only network floor remain unchanged. HTTP endpoints
retain the direct connection.

One broker holding every tenant's credentials and seeing every prompt is a
large blast radius, and not a new one: the app server already holds the
master key.

### The egress trail

`GET /api/conversations/:id/egress` returns what left the sandbox, newest
first: host, matched service (and so which credential was attached), status,
total latency and refusal. A `broker_requests` row is written from the
proxy's terminal request event by a buffered writer, so a streamed reply is
recorded when it ends and `latency_ms` is total duration. The row's
credential verdict comes from the event's `scheme`, since a matched
passthrough rule also counts as a rule applied. Conversation and user ids
ride as the session's metadata, so the library never knows what a
conversation is. `Fountain.Workers.BrokerReaper` deletes rows and sessions
after `BROKER_LOG_RETENTION_HOURS` (168 by default). This is the effect half
of the audit trail ([0013](0013-audit-trail.md)); the conversation id joins
them.

## Consequences

- The broker is a hard dependency of every conversation's provisioning, and
  fails closed. Broker down means no conversation starts.
- The broker can read everything, by choice (§10). That belongs in the
  security posture docs, and constrains where it runs and who reads its logs.
- Every outbound request pays latency. Measured at gate 0 against a remote
  broker: +258 ms per request (0.356 s brokered, 0.098 s direct), about
  150 ms of it the sandbox-to-broker leg. Minting a session cost at most
  170 ms.
- Deny-by-default exposes egress nobody enumerated: opencode routed model
  traffic through `opencode.ai`, and every runtime brings its own hosts.
- `Redaction` becomes defence in depth and stays as it is.
- A self-hoster needs a TCP or TLS ingress for the broker before a first
  conversation runs, even on a laptop. Accepted: without it every credential
  enters the sandbox in plaintext.
- The whole test suite runs brokered; `config/test.exs` starts the listener.
- [0008](0008-byo-inference-credentials.md)'s economics are untouched: the
  tenant's key and bill, only custody moves. A proxy that sees model traffic
  could meter or enforce model choice; neither is decided.
- "The agent never holds your HTTP credentials" is checkable by a user in
  minutes, so an unbrokered path we failed to label is a defect.

## Alternatives considered

- **Make `limited` the default and document it.** Better than nothing, but a
  host allowlist decides per host while a credential is per credential, and
  it leaves the tenant enumerating hosts, which produced zero adoption.
- **0016 §4's base-URL override.** Covers inference only and needs every
  runtime to cooperate.
- **Build our own credential proxy.** First rejected as a product rather than
  a component. Reversed once a native proxy existed (#1148): it needs no
  separately operated service or database, and the move closed two vendor
  failures on the way, a peer-keyed rate limiter that broke one tenant's
  clones on another's bursts (#1206) and a 500 on a duplicate vault that broke
  reattach after idle (#1185).
- **Short-lived credentials instead.** Better where the upstream supports it,
  since no proxy is on the path, but per-provider; worth doing in addition.
- **Per-process network namespaces in the sandbox.** Per-provider substrate
  work, and the agent still holds the credential.
- **Wait for an ACP gateway.** Egress is what ACP cannot see.
- **Keep a deployment off switch** (the 2026-09-14 reframing of #2056).
  Rejected: an instance that loses its listener would silently hand every
  sandbox plaintext credentials, and nothing downstream could tell.

## History

- 2026-08-14 — Proposed: placeholders in the sandbox, credentials at a forward proxy, `allow: [broker]` floor.
- 2026-08-24 — Gate 0 spike passed on production Sprites with Agent Vault; vendor, opt-in, bodies and topology decided.
- 2026-08-25 — Gates 1a, 1b, 2, 3 and 4 built (#1090); session per conversation; first tenant brokered (home-cloud#131); multi-key substitution fix (#1155), opencode model id fix (#1157).
- 2026-08-25 — Brokered values may rotate mid-conversation; the broker's copy is refreshed before each turn (#1178).
- 2026-09-02 — Native proxy adopted as the `managoat_broker` library and run beside Agent Vault (#1148, #1340).
- 2026-09-03 — Production flipped to the native broker (home-cloud#153); Agent Vault client removed (#1487); stored egress log (#1486); 407 retry regression fixed (#1492, #1493); parity gaps closed but three (#1359, #1501).
- 2026-09-04 — `BROKER_TENANTS=*` brokers every account (home-cloud#163, #1553).
- 2026-09-12 — Per-tenant ratchet removed; `BROKER_TENANTS` kept only as an assertion (#1686).
- 2026-10-12 — Connections removed, so the broker no longer carries connection tokens ([0085](0085-mcp-connections.md) brought them back on 2026-10-15).
- 2026-10-14 — Self-hosted runner removed ([0071](0071-hosted-sandbox-providers-only.md)), and with it the HOME CA install; `BROKER_ALLOW_UNENFORCED` removed (#2057).
- 2026-10-15 — Brokerage unconditional: off switch, `Broker.configured?/0` and `BROKER_TENANTS` removed, boot requires the broker (#2056, #2819, #2820, #2823).
- 2026-10-16 — An optional standalone remote broker on Fly ([0091](0091-remote-broker.md), #2893); production moved to it.
- 2026-10-17 — The environment-layer fetch exception, accepted but never built,
  went with [0090](0090-portable-environment-layers.md), which was retired.
- 2026-10-17 — Remote broker removed; the broker runs inside Managoat only, with a home-generated `BROKER_CA_SEED` ([0093](0093-the-broker-runs-inside-managoat.md)).
- 2026-10-17 — Section 2 names the floor's two call sites; the "warm restore" path it also named no longer exists.
- 2026-10-19 — Section 2: a reattach to a running machine leaves a floor the provider reports in force alone instead of rewriting it, because a Sprites policy write resets the sandbox's open flows (#2964).
- 2026-10-19 — Section 2: on Sprites the floor is written first, before the CA and relay, and a provision or reattach holds the first prompt until 2 s after it. A reattach skips a floor in force whatever status the provider reports (#2964).
