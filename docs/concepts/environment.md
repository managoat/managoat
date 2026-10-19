# About environments

This page explains what an Environment is, and why it is separate from the
other three primitives. For each field, read the
[API reference](../api.md). To bootstrap one, read the
[guided tour](../tour.md).

## What an environment is

An Environment is the machine an agent wakes on, described as data.

It holds four kinds of thing.

- **Encrypted secrets.** Pairs of key and value, encrypted for each tenant
  with AES-256-GCM. They are write-only. Once you store a value, the API never
  returns it. A list gives you keys and timestamps.
- **Plain environment variables.** A non-secret `env_vars` map, for values
  that are not sensitive. Feature flags and endpoints go here. The API returns
  these as you wrote them, so a sensitive value belongs in secrets instead.
- **Runtime config.** The packages to install, the repos to clone, and the
  setup script to run.
- **A network policy.** `networking_type` is `unrestricted` or `limited`.

## Why it exists

What a machine holds changes on a different schedule from everything else
about an agent.

A team decides Python 3.12, a checkout of your service repo and a
`mise install` step one time, then leaves them alone for months. Which
credentials one run uses can change each hour. Which model an agent runs is a
question you revisit every few weeks.

Put those in one object, and a token rotation edits the machine image. Each
agent that shares the image then needs a new one. Divide them, and many agents
can share one Environment. A single run can still deviate from it, and nobody
edits the shared thing.

## How it works

You attach an Environment to an Agent when you create the Agent. That
Environment is the Agent's default.

It is not the only choice. A Conversation can name a different
`environment_id` at launch, within the Agent's `allowed_environment_ids`. So
the same Agent can start from a heavy image for one task and a small one for
another.

At spawn, Managoat merges the Environment's secrets with the secrets of any
attached Vault. The result becomes the process environment in the sandbox. The
Vault wins on a key collision. Read [About vaults](vault.md).

```yaml
apiVersion: managoat/v1
kind: Environment
metadata:
  name: python-data-env
spec:
  packages:
    apt:
      - jq
  networking_type: limited
  secrets:
    OPENAI_API_KEY: sk-...
```

`secrets` must be a map of `KEY: value`. The server keeps only the map form
and drops any other shape without an error. The map form is also what the
CLI's `${VAR}` substitution and secret-manager references resolve against.
`packages` has two keys that install software, `apt` and `npm`. Other
language toolchains go in `setup_script`. When every `apt` package named is
already in the sandbox image, such as `jq`, `git` or `curl`, the step skips
`apt-get update` and the install and keeps the image's version. If any of
them is missing, or a name carries a version or a release (`jq=1.7`), the
lists are updated and the install runs as usual.

`setup_timeout_seconds` sets the setup exec timeout (1–900 seconds, default
120). Use the API or an environment spec to give cold dependency/toolchain
installation more time.
The overall 30-minute provisioning deadline still applies; a failed or timed-out
setup does not start the agent. This controls setup, not inference time or spend.

A setup script cannot configure the runtime by writing into the image's
`~/.claude`, `~/.codex` or `~/.gemini`: each conversation reads a config home
of its own, and a workspace's setup runs before any exists. Write runtime configuration into
the **runtime template** instead. The script runs with
`MANAGOAT_RUNTIME_TEMPLATE` set to `/home/sprite/.managoat/template`, whose
`claude/`, `codex/` and `gemini/` directories hold what `~/.claude`,
`~/.codex` and `~/.gemini` would. Each conversation's config home starts as a
copy of its runtime's directory, with Managoat's own files written on top.
That works the same for a [workspace](workspaces.md)'s setup, which runs
before any conversation exists, and for a conversation's own:

```bash
t="$MANAGOAT_RUNTIME_TEMPLATE"
cat > "$t/claude/settings.json" <<'EOF'
{ "includeCoAuthoredBy": false }
EOF
printf 'project_doc_max_bytes = 65536\n' > "$t/codex/config.toml"
```

The template is copied once per conversation, when its config home is made,
so a later change reaches only new conversations. It is not a place for
secrets. [Configure the runtimes from the setup](workspaces.md#configure-the-runtimes-from-the-setup)
has the rules: which files Managoat's win over, which are merged, and what is
not copied.

The setup step ends when the script exits. A process the script starts in the
background, such as a dev server, keeps running, but what it prints after the
script exits is not in the setup log. Redirect its output to a file if you
want to read it later.

The script's output reaches the conversation's stream while the script runs.
It arrives as `output` events with `stage: "setup"`, between the `setup`
stage's `started` event and its `done` or `failed` event. stdout and stderr
are merged, and the events are on the `stdout` stream. Managoat sends what the
script printed about once a second, in whole lines: a line without its newline
waits for the rest of it, or for the script to exit. So a script that prints
`[12:00:05] installing toolchain` before each step lets a client show each
step as it starts. Join the events in order to get the whole log. The
`packages` stage writes its `apt` and `npm` output the same way, as `output`
events with `stage: "packages"`.

This output counts toward the conversation's 50 MB log limit, like everything
else the sandbox prints. Past that limit, Managoat keeps the start of the
output, writes one notice on the `stderr` stream and drops the rest.

### The network policy is not symmetric

`unrestricted` does nothing. A Sprites sandbox is open by default, so the
value changes nothing.

It is also not the last word on what the agent can reach. A runtime can hold a
sandbox of its own inside the machine, and Managoat's policy does not open it.
By default codex blocks its own network access until it asks for access and
gets an approval, whatever this field says. Read
[the sandbox codex builds for itself](../catalog/runtimes/codex.md#the-sandbox-codex-builds-for-itself).

`limited` holds egress to the domains in `networking_config.allowed_hosts`.
That is the only `networking_config` key Managoat reads today.

Under `limited` with no `allowed_hosts`, the allowlist is empty. Nothing gets
out. That is deliberate, and it is not a defect. An empty allowlist that
quietly meant "allow everything" would be the worst default for a policy whose
whole purpose is restriction.

Every conversation runs behind the egress credential broker. Read the
[configuration reference](../configuration.md#sandboxes).

The sandbox can reach only the broker. The broker then applies your policy. With
`unrestricted`, a request goes through to any host, with only the credentials
you bound. With `limited`, the broker refuses a request to a host that is not
in `allowed_hosts`. The refusal is a 403 that names the host. The broker's
request log, `GET /api/conversations/:id/egress`, shows each decision. List what the setup of the sandbox needs. The agent's adapter needs no
entry: Managoat writes it into the sandbox. A host with a bound credential,
such as the model's API, needs no entry.

The policy is applied before the environment's packages install, so the
package mirrors belong in the allowlist too: `archive.ubuntu.com` and
`security.ubuntu.com` for `apt`, `registry.npmjs.org` for `npm`. A `limited`
environment that lists packages without its mirrors fails at the `packages`
stage, with the mirror's name in the output, rather than installing them on
an open network.

An Agent's GitHub skills install the same way, so they need `github.com` in
the allowlist too. A skill that can't
install is logged and skipped. See [Skills](../catalog/skills/index.md).

Put an IPv6 address in square brackets, such as `[2001:db8::1]`. Without them
there is no way to tell the port apart from the address.

Not every backend can hold egress. Sprites and E2B can. The agent selects the
backend, and the environment sets the policy. Managoat therefore compares the
two at launch. It refuses a `limited` environment on a backend that cannot
enforce one. The conversation fails with a `network` / `failed` event. The
reason is `backend_lacks_network_policy`, and Managoat creates no sandbox.

## What an environment is not

**Not a deployment tier.** "Environment" in Managoat never means dev, staging
or production. You might build those out of Environments and Vaults. Managoat
does not model them.

**Not a container image.** Managoat builds no image and stores no image. An
Environment is a recipe that the sandbox provider applies at provision time.
Two conversations from the same Environment install their packages
one by one, on their own machines.

**Not a secret store you can read.** Values go in and never come out. To learn
what a secret is, go back to the source you got it from. Managoat will not
tell you.

## When to use something else

Use a [Vault](vault.md) when the value changes for each run, for each customer
or at each credential rotation.

Use `env_vars` and not `secrets` when the value is not sensitive. The API
returns `env_vars` as you wrote them. File a non-secret as a secret, and you
get a value that nobody can ever read back to check.

Use [inference credentials](../integrations/index.md) for model API keys.
Those belong to one user. An operator never sets them, and an Environment
never stores them. You set them in the console or over the
[inference credentials API](../api.md#inference-credentials).

## Where to go next

- [About vaults](vault.md), the other half of the merge.
- [About agents](agent.md), which names an Environment.
- [The guided tour](../tour.md), which builds one in its first step.
- [Configuration reference](../configuration.md), for the sandbox settings
  that belong to the instance.
