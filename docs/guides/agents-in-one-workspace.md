# Run several agents on one machine

This guide sets up one machine from an environment and runs three agents on
it at once, a claude, a codex and a gemini, each in a folder of its own. They
share the checkout, the installed packages and the disk, the way three
terminals on one laptop do. The machine is a [workspace](../concepts/workspaces.md).

!!! warning "The three agents can read and change each other's work"

    Conversations in one workspace run as one user on one disk. Each can read
    the others' files, configuration and tokens, and can leave instructions or
    hooks that the others then follow. Put agents in one workspace only when
    you would let them share a laptop. For isolation, launch without
    `--workspace`, and each conversation gets a sandbox of its own.

## Before you start

- The CLI, signed in with `managoat auth login`. A workspace needs a
  full-scope key, so the `MANAGOAT_TOKEN` inside a sandbox will not do.
- An inference credential for each provider you use, added under
  **Account → Inference keys**: Anthropic for claude, OpenAI for codex, Google
  for gemini.
- A repository to work on. A private one needs a token in a vault, as the
  [guided tour](../tour.md#1-the-machine) shows.

## 1. Describe the machine and the agents

Write one manifest with the environment and the three agents. A
conversation's working directory must lie under `/home/sprite` or under one of
the environment's repository mounts, so the checkout can live at either. This
guide clones it to `/home/sprite/app`.

```yaml
---
apiVersion: managoat/v1
kind: Environment
metadata:
  name: app
spec:
  repositories:
    - url: https://github.com/you/your-app
      mount_path: /home/sprite/app
      secret_key: GITHUB_TOKEN
  setup_script: cd /home/sprite/app && npm ci
---
apiVersion: managoat/v1
kind: Agent
metadata:
  name: web-dev
spec:
  runtime: claude
  model: anthropic/claude-sonnet-5
---
apiVersion: managoat/v1
kind: Agent
metadata:
  name: api-dev
spec:
  runtime: codex
  model: openai/gpt-6-astra
---
apiVersion: managoat/v1
kind: Agent
metadata:
  name: writer
spec:
  runtime: gemini
  model: google/gemini-3.1-pro-preview
```

Apply it, and put the token the clone reads in a vault:

```bash
managoat apply -f app.yml
managoat vault create github
managoat vault set-secret github GITHUB_TOKEN "$GITHUB_TOKEN"
```

The agents name no environment: in a workspace the environment comes from
the workspace. An agent with `allowed_environment_ids` or `allowed_vault_ids`
must allow the workspace's.

## 2. Create the workspace

```bash
managoat workspace create app-box --environment app --vault github --wait
```

```text
workspace  +  app-box (0198c9a2-…)  provisioning
▸ workspace 0198c9a2-…: provisioning
▸ workspace 0198c9a2-…: ready
```

Managoat builds the machine now, before any agent arrives: it clones the
repository, installs the packages and runs the setup script once. `--wait`
follows the setup and exits non-zero if it fails, with the failing step and
the end of what it printed. Without `--wait`, the command returns at once and
`managoat workspace wait app-box` waits later.

The workspace always uses this environment, vault and provider; to use
others, create another workspace. Editing the environment does reach it, at
its next setup: a retry after a failure, or a rebuild after a loss.

## 3. Start the three agents, each in its own folder

`--workspace` puts the conversation on the workspace's machine, and `--cwd`
picks the folder its agent works in. A missing folder is created.

```bash
managoat run web-dev --workspace app-box --cwd /home/sprite/app/web \
  -p "Add a dark mode toggle to the settings page" > web.log 2>&1 &
managoat run api-dev --workspace app-box --cwd /home/sprite/app/api \
  -p "Add an endpoint that returns the user's theme preference" > api.log 2>&1 &
managoat run writer --workspace app-box --cwd /home/sprite/notes \
  -p "Draft release notes for a dark mode feature in this folder" > notes.log 2>&1 &
wait
```

Each `run` streams its own turn into its log and exits when that turn ends.
The first line of each log names its conversation. The three run at the same
time, in three conversations, on one machine. Each has its own
config home, so their skills, MCP servers and sessions do not collide, and two
of them could even share one folder.

Leave out `--environment` and `--vault`: the workspace supplies both. Naming
a different one is refused with `workspace_fixes_environment`.

## 4. Keep talking to them

Send a follow-up to any of them by its conversation id, the usual way:

```bash
managoat conv list
managoat conv prompt <conversation-id> -p "Now add tests for it"
```

When nobody prompts any of them for the idle timeout (60 minutes by default),
the machine parks. The next prompt to any of the three wakes it, with the disk
as it was and that agent's session intact.

## 5. Look at the shared disk

The workspace's disk reads see everything under `/home/sprite`, every live
conversation's working directory, and the environment's repository mounts:

```bash
WORKSPACE_ID=$(managoat workspace show app-box --json | jq -r .id)

curl --fail-with-body -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  "$MANAGOAT_URL/api/workspaces/$WORKSPACE_ID/git-status?path=/home/sprite/app"
```

That is one repository's status, with the changes all three agents made in
it. A parked machine answers `409 sandbox_not_ready`: a read never wakes it.

## The same thing from the TypeScript SDK

```ts
import { Managoat } from "@managoat/sdk";

const managoat = new Managoat();
const env = await managoat.environments.get("app");
const vault = await managoat.vaults.get("github");

const ws = await managoat.workspaces.create({
  name: "app-box",
  environment_id: env.id,
  vault_id: vault.id,
});
await managoat.workspaces.waitForReady(ws.id);   // throws WorkspaceFailedError on a failed setup

const results = await Promise.all([
  managoat.run("Add a dark mode toggle", { agent: "web-dev", workspace: ws.id, cwd: "/home/sprite/app/web" }),
  managoat.run("Add a theme endpoint", { agent: "api-dev", workspace: ws.id, cwd: "/home/sprite/app/api" }),
  managoat.run("Draft release notes", { agent: "writer", workspace: ws.id, cwd: "/home/sprite/notes" }),
]);

const status = await managoat.workspaces.gitStatus(ws.id, { path: "/home/sprite/app" });
```

## From an editor

`managoat acp` takes the same two flags, so one editor entry per agent can
open every session in one workspace, each in its own folder:

```bash
managoat acp --agent web-dev --workspace app-box --cwd /home/sprite/app/web
```

Read [Connect an editor](../integrations/editors.md).

## 6. Clean up

A workspace's machine has no lifetime limit. It parks when idle, and even
the operator's `SANDBOX_MAX_LIFETIME_HOURS` ceiling parks it rather than
destroying it, so a parked machine stays at the provider until you delete the
workspace. Delete it when you are done:

```bash
managoat workspace delete app-box
```

That terminates the three conversations, keeping their transcripts, and
destroys the machine with its disk. Push the work first.

## When it goes wrong

| You see | Why | Do this |
|---|---|---|
| `workspace setup failed: …` | The setup script, a package or a clone failed. The message names the step. | Fix the environment, then prompt a conversation in the workspace: that runs the setup again with the environment as it is now. |
| `422 workspace_fixes_environment` | The launch named an environment or vault other than the workspace's. | Drop `--environment` and `--vault`. |
| `422 environment_not_allowed` or `vault_not_allowed` | The agent's allowlist does not include the workspace's environment or vault. | Add them to the agent's `allowed_environment_ids` or `allowed_vault_ids`. |
| `403` with `required_scope: "full"` | A sandbox's own key, such as `MANAGOAT_TOKEN` inside a sandbox, cannot use workspaces. | Use a key from `managoat auth login`. |
| `503 fleet_full` on create | Every sandbox slot on the provider is in use. | Try again in a minute. |
| `422 validation_failed` on `cwd` | The folder is not under `/home/sprite` (or `/tmp` for gemini) or a repository mount of the workspace's environment, or is inside `/home/sprite/.managoat`. | Choose a folder under `/home/sprite` or under a repository's `mount_path`. |
| `409 source_in_use_by_workspace` deleting the environment or vault | A workspace was created from it. | Delete the workspace first. |
| A turn ends `interrupted`, `machine_parked` | The operator's lifetime ceiling parked the machine. | Prompt again; the machine wakes with its disk. |

## Where to go next

- [About workspaces](../concepts/workspaces.md): the lifecycle, the trust
  boundary, and what a lost machine costs.
- The [Workspaces section](../api.md#workspaces) of the API reference.
- [Use the CLI](../cli.md#workspaces) for every `managoat workspace` command.
