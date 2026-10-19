# The four primitives

This page explains what Managoat's four objects are, and why there are four of
them. For the fields on each one, read the [API reference](api.md). To build
something with them, start with the [guided tour](tour.md).

## The problem the four primitives divide up

To run a coding agent on a machine that is not yours, you must decide four
things. Each of the four changes on its own schedule.

What the machine holds changes rarely. Python 3.12, a checkout of your repo, a
setup script. You decide it once for a team, then leave it alone for months.

Which credentials the agent runs with changes constantly. A staging database
URL today, a customer's API key tomorrow, a rotated token an hour from now.

How the agent behaves changes sometimes. Which model, which runtime,
which skills, which MCP servers, and what its system prompt says.

What it does right now changes every few seconds.

Put all four in one object, and each credential rotation edits the machine
image. Each prompt edits the credentials. Managoat divides them into four
objects on purpose, and that division is the product.

| Primitive | Answers | Changes |
|---|---|---|
| [Environment](concepts/environment.md) | what the machine holds | rarely |
| [Vault](concepts/vault.md) | which credentials the run uses | constantly |
| [Agent](concepts/agent.md) | how the agent behaves | sometimes |
| [Conversation](concepts/conversation.md) | what it does now | continuously |

## How they compose

An Agent names an Environment. A Conversation runs an Agent. That Conversation
can name a different Environment, and it can attach a Vault for that one run.

Three of the four are templates. They are rows that you write once and use
many times. The fourth, the Conversation, is a run on a machine. The machine
is the heavy work, and Managoat does it for you.

<figure>
<svg viewBox="0 0 960 552" role="img" aria-label="Three templates, one machine, in three stages. Stage one, write once: Agent, Environment and Vault are rows an account writes and reuses. Stage two, at launch: Managoat builds the machine, merges the Environment's secrets with the Vault's and the Vault wins, and starts the agent's runtime. Stage three, the machine: a sandbox receives its environment and runs exactly one Conversation, with its own transcript. The next turn lands on the same machine, and an idle machine parks until that turn wakes it. A bound secret's real value goes to the egress broker instead, the sandbox gets a placeholder, and the sandbox reaches the internet only through the broker." style="max-width:100%;height:auto">
  <rect width="960" height="552" rx="16" fill="#1e2129"/>
  <defs>
    <marker id="pr-a" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0 L8 4 L0 8" fill="none" stroke="#5796f4" stroke-width="1.5"/></marker>
    <marker id="pr-b" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0 L8 4 L0 8" fill="none" stroke="#d98d2b" stroke-width="1.5"/></marker>
  </defs>
  <path d="M32 36 H60" fill="none" stroke="#d98d2b" stroke-width="1.6"/>
  <text x="72" y="41" font-family="ui-monospace, SFMono-Regular, Consolas, monospace" font-size="12" font-weight="600" fill="#d98d2b">MANAGOAT / HOW A RUN WORKS</text>
  <text x="32" y="82" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="30" font-weight="600" fill="#f5f5f7">Three templates. One machine.</text>
  <text x="32" y="109" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="15" font-weight="400" fill="#a6a6b2">Configure once. Start a conversation. Come back to the same files.</text>
  <text x="32" y="153" font-family="ui-monospace, SFMono-Regular, Consolas, monospace" font-size="12" font-weight="600" fill="#d98d2b">1 · WRITE ONCE</text>
  <text x="32" y="176" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="14" font-weight="400" fill="#a6a6b2">Reusable configuration</text>
  <text x="336" y="153" font-family="ui-monospace, SFMono-Regular, Consolas, monospace" font-size="12" font-weight="600" fill="#d98d2b">2 · AT LAUNCH</text>
  <text x="336" y="176" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="14" font-weight="400" fill="#a6a6b2">One API call</text>
  <text x="640" y="153" font-family="ui-monospace, SFMono-Regular, Consolas, monospace" font-size="12" font-weight="600" fill="#d98d2b">3 · THE MACHINE</text>
  <text x="640" y="176" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="14" font-weight="400" fill="#a6a6b2">One sandbox per conversation</text>
  <rect x="32" y="198" width="246" height="61" rx="10" fill="#2a2e38" stroke="#363b47"/>
  <text x="50" y="224" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="17" font-weight="600" fill="#f5f5f7">Agent</text>
  <text x="50" y="245" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="13" font-weight="400" fill="#a6a6b2">Model, runtime, skills</text>
  <rect x="32" y="273" width="246" height="61" rx="10" fill="#2a2e38" stroke="#363b47"/>
  <text x="50" y="299" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="17" font-weight="600" fill="#f5f5f7">Environment</text>
  <text x="50" y="320" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="13" font-weight="400" fill="#a6a6b2">Packages, repos, secrets</text>
  <rect x="32" y="348" width="246" height="61" rx="10" fill="#2a2e38" stroke="#363b47"/>
  <text x="50" y="374" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="17" font-weight="600" fill="#f5f5f7">Vault</text>
  <text x="50" y="395" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="13" font-weight="400" fill="#a6a6b2">Secret overrides, per run</text>
  <rect x="336" y="235" width="246" height="174" rx="10" fill="#151820" stroke="#5796f4"/>
  <text x="356" y="268" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="21" font-weight="600" fill="#f5f5f7">Managoat</text>
  <path d="M356 284 H562" fill="none" stroke="#363b47" stroke-width="1.6"/>
  <text x="356" y="311" font-family="ui-monospace, SFMono-Regular, Consolas, monospace" font-size="11" font-weight="500" fill="#5796f4">01</text>
  <text x="382" y="311" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="13" font-weight="400" fill="#f5f5f7">Build the machine</text>
  <text x="356" y="339" font-family="ui-monospace, SFMono-Regular, Consolas, monospace" font-size="11" font-weight="500" fill="#5796f4">02</text>
  <text x="382" y="339" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="13" font-weight="400" fill="#f5f5f7">Merge secrets; vault wins</text>
  <text x="356" y="367" font-family="ui-monospace, SFMono-Regular, Consolas, monospace" font-size="11" font-weight="500" fill="#5796f4">03</text>
  <text x="382" y="367" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="13" font-weight="400" fill="#f5f5f7">Start the agent’s runtime</text>
  <text x="356" y="392" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="12" font-weight="400" fill="#a6a6b2">Ready for the first prompt</text>
  <rect x="640" y="198" width="288" height="211" rx="10" fill="#151820" stroke="#5796f4"/>
  <text x="658" y="226" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="17" font-weight="600" fill="#f5f5f7">Sandbox</text>
  <text x="658" y="253" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="14" font-weight="400" fill="#a6a6b2">Config + credentials</text>
  <text x="658" y="274" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="12" font-weight="400" fill="#a6a6b2">Placeholders for bound secrets</text>
  <rect x="656" y="289" width="256" height="58" rx="10" fill="#2a2e38" stroke="#363b47"/>
  <text x="672" y="313" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="16" font-weight="600" fill="#f5f5f7">Conversation</text>
  <text x="672" y="334" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="12" font-weight="400" fill="#a6a6b2">One run, its own transcript</text>
  <circle cx="664" cy="372" r="3" fill="#d98d2b"/>
  <text x="675" y="377" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="14" font-weight="400" fill="#f5f5f7">Work → park → wake</text>
  <text x="658" y="397" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="12" font-weight="400" fill="#a6a6b2">Next turn. Same machine. Same files.</text>
  <path d="M278 228 H296 Q306 228 306 238 V300 Q306 310 316 310 H332" fill="none" stroke="#5796f4" stroke-width="1.6" marker-end="url(#pr-a)"/>
  <path d="M278 303 H292 V324 H332" fill="none" stroke="#5796f4" stroke-width="1.6" marker-end="url(#pr-a)"/>
  <path d="M278 378 H296 Q306 378 306 368 V348 Q306 338 316 338 H332" fill="none" stroke="#5796f4" stroke-width="1.6" marker-end="url(#pr-a)"/>
  <path d="M582 318 H636" fill="none" stroke="#5796f4" stroke-width="1.6" marker-end="url(#pr-a)"/>
  <text x="590" y="305" font-family="ui-monospace, SFMono-Regular, Consolas, monospace" font-size="11" font-weight="400" fill="#5796f4">spawn</text>
  <rect x="640" y="458" width="288" height="62" rx="10" fill="#2a241c" stroke="#7a4a09"/>
  <text x="658" y="483" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="16" font-weight="600" fill="#f0c684">Egress broker</text>
  <text x="658" y="505" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="12" font-weight="400" fill="#f0c684">Only exit → GitHub, model APIs, yours</text>
  <path d="M550 409 V489 H636" fill="none" stroke="#d98d2b" stroke-width="1.6" marker-end="url(#pr-b)" stroke-dasharray="5 5"/>
  <text x="336" y="446" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="13" font-weight="600" fill="#f0c684">Bound secrets</text>
  <text x="336" y="466" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="12" font-weight="400" fill="#a6a6b2">Real values go to the broker</text>
  <path d="M784 409 V454" fill="none" stroke="#d98d2b" stroke-width="1.6" marker-end="url(#pr-b)"/>
  <text x="796" y="438" font-family="ui-monospace, SFMono-Regular, Consolas, monospace" font-size="11" font-weight="400" fill="#f0c684">HTTPS_PROXY</text>
  <text x="32" y="485" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="13" font-weight="500" fill="#f5f5f7">Your setup is reusable.</text>
  <text x="32" y="507" font-family="system-ui, -apple-system, Segoe UI, sans-serif" font-size="12" font-weight="400" fill="#a6a6b2">Each run gets its own workspace.</text>
</svg>
<figcaption><b>Three templates, one machine.</b> Agent, Environment and Vault are rows you write once. At launch Managoat builds the sandbox from the Environment, merges the secrets with the Vault winning, and starts the Agent's runtime. Each Conversation has a machine of its own, and its next turn lands on the machine the last one left. An idle machine parks, and the next turn wakes it. The fleet ceiling only refuses a new machine; it reclaims none. A bound secret's real value goes to the egress broker and the sandbox gets a placeholder, such as <code>__github_token__</code>; the sandbox reaches the internet only through the broker, which attaches the value. A secret with no binding enters the sandbox as an environment variable.</figcaption>
</figure>

A Conversation starts. At that moment Managoat merges the Environment's
secrets with the Vault's secrets. **The Vault wins on a key collision.** That
one rule is what makes the division into four usable and not merely tidy.
[About vaults](concepts/vault.md) sets it out.

What happens next depends on the secret. Every sandbox reaches the internet
through the egress broker. A bound secret does not enter the sandbox: the
sandbox gets a placeholder, such as `__github_token__`, and the broker puts the
real value on each request to the bound host. A secret with no binding enters
the sandbox as an environment variable.
[Where a secret comes from](concepts/secrets.md) follows one secret through
both paths.

Why an API for this, when you can run an agent in a sandbox by hand? Because
the templates outlive the run. The machine, the secrets and the agent are
rows you can list, diff, share and launch from code. Because the identity and
the machine are separate, so one Environment can run as you, as a bot user,
or as a customer. And because a run is a thing with an id, a status, a
transcript and an event stream. A webhook, a cron job or another agent can
start one and follow it.

## Substitution

Each string value in an Agent config takes a `${VAR}` reference. Managoat
resolves it from the merged environment and vault secrets at spawn time.

| Syntax | Result |
|---|---|
| `${VAR}` | The value of `VAR` from the merged map |
| `$$` | A literal `$` |

Substitution is recursive, so it works inside maps and lists. It is also
fail-complete. Managoat reports each absent variable at once, and not one for
each attempt.

## What Managoat does not have

There is no fifth primitive. Three things look like one and are not.

A **long-lived agent** is not an object. It is a Conversation that you keep,
by its id or by a `channel_id` of your own.

A **sandbox** is not an object you create. Managoat gives you one when a
Conversation starts, one for each Conversation, and it ends with that
Conversation. You can list sandboxes and read one.
Read [About sandboxes](concepts/sandboxes.md) and the
[Sandboxes section](api.md#sandboxes) of the API reference.

A **workspace** is a machine you keep. You create it from an Environment and
a Vault, and then launch any number of Conversations into it, each in its own
folder. It is something you create and delete, but it configures nothing: its
Environment and Vault are two of the four, and the Agents that run there are
a third. It changes only where a run happens. Every Conversation launched
without one gets a workspace of its own, which is the sandbox above.
Conversations in one workspace can read and influence each other, so it is
also a choice to give up isolation. Read
[About workspaces](concepts/workspaces.md).

## Where to go next

- **Learn as you build.** The [guided tour](tour.md) uses all four to open a
  pull request, in about forty lines.
- **Understand one primitive.**
  [Environment](concepts/environment.md),
  [Vault](concepts/vault.md),
  [Agent](concepts/agent.md),
  [Conversation](concepts/conversation.md).
- **Understand the machinery.**
  [Where a secret comes from](concepts/secrets.md) follows a value from the
  master key to the process. [About sandboxes](concepts/sandboxes.md) covers
  the machine a run happens on. [Architecture](architecture.md) follows a
  prompt from the API call to the first token.
- **Look something up.** The [API reference](api.md) has each field.
  [Conversation states](reference/conversation-states.md) has the state table.
  The [glossary](reference/glossary.md) has the overloaded words.
