---
name: managoat
description: Spawn and stream Managoat conversations from inside a sprite — use whenever the user asks you to "spin up an agent on Managoat" (or on Fountain, its former name), "delegate to another agent", "fan out", or any task large enough to parallelise across coding agents. Managoat provisions an isolated Sprite per conversation, runs the configured runtime in it, and streams output back over SSE. Reads `MANAGOAT_BASE_URL`, `MANAGOAT_TOKEN`, and `MANAGOAT_CONVERSATION_ID` from the environment.
---

# Managoat — spawning conversations from inside a sprite

You are running inside a Sprite that Managoat provisioned. The Managoat API is
reachable at `$MANAGOAT_BASE_URL` (under **`/api`**) with bearer
`$MANAGOAT_TOKEN`. From here you can spawn *more* Managoat conversations —
each runs in its own fresh Sprite.

> **Use the API path**: `$MANAGOAT_BASE_URL/api/conversations`. The retired
> browser path `$MANAGOAT_BASE_URL/conversations` returns 404.

## Finding cloned repositories

If the environment was configured with repositories, they are cloned into the
sprite **before** the setup script runs. **Look for cloned repos under
`/workspace/`** — for example, a repo cloned with `mount_path:
"/workspace/my-repo"` will be at `/workspace/my-repo` inside the sprite.

```bash
# List all cloned repos:
ls /workspace/

# Navigate to a specific repo:
cd /workspace/my-repo
```

When writing prompts for spawned agents that need to work with source code,
tell them to look in `/workspace/<repo-name>` — that is the conventional
location. If you are unsure of the repo name, `ls /workspace/` will show
what is available.

## The two patterns you'll use

### A. Fan out N agents and collect their answers

```bash
# 1. Pick the agent (by name).
AGENT_ID=$(curl -s "$MANAGOAT_BASE_URL/api/agents" \
  -H "Authorization: Bearer $MANAGOAT_TOKEN" \
  | jq -r '.data[] | select(.name == "echo-bot") | .id')

# 2. Spawn N conversations IN PARALLEL with xargs. Output is conv ids on stdout.
prompts=("First task" "Second task" "Third task")
ids=$(printf '%s\n' "${prompts[@]}" | xargs -n1 -P8 -I{} sh -c '
  curl -s -X POST "$1/api/conversations" \
    -H "Authorization: Bearer $2" \
    -H "Content-Type: application/json" \
    -H "X-Managoat-Parent-Conversation-Id: $MANAGOAT_CONVERSATION_ID" \
    -d "$(jq -n --arg a "$3" --arg p "$4" "{agent_id:\$a, prompt:\$p}")" \
  | jq -r .data.id
' _ "$MANAGOAT_BASE_URL" "$MANAGOAT_TOKEN" "$AGENT_ID" {})

echo "$ids"   # one conv id per line

# 3. Wait for all of them in parallel.
echo "$ids" | xargs -n1 -P10 -I{} sh -c '
  while :; do
    s=$(curl -s "$1/api/conversations/$3" -H "Authorization: Bearer $2" | jq -r .data.status)
    case "$s" in running|pending) sleep 2 ;; *) break ;; esac
  done
' _ "$MANAGOAT_BASE_URL" "$MANAGOAT_TOKEN" {}

# 4. Gather the final text from each (claude runtime).
while IFS= read -r conv; do
  echo "=== $conv ==="
  curl -sN --max-time 5 \
    "$MANAGOAT_BASE_URL/api/conversations/$conv/stream?streams=stdout&wait=false" \
    -H "Authorization: Bearer $MANAGOAT_TOKEN" \
  | awk '/^data: /{sub(/^data: /,""); print}' \
  | jq -r '.data | fromjson? | select(.type=="result") | .result' \
  | tail -n1
done <<<"$ids"

# 5. Terminate all spawned conversations now that you have what you need.
echo "$ids" | xargs -n1 -P10 -I{} \
  curl -s -X POST "$MANAGOAT_BASE_URL/api/conversations/{}/terminate" \
    -H "Authorization: Bearer $MANAGOAT_TOKEN"
```

### B. Spawn one and block until it answers

```bash
AGENT_ID=...
PROMPT=...

CONV=$(curl -s -X POST "$MANAGOAT_BASE_URL/api/conversations" \
  -H "Authorization: Bearer $MANAGOAT_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Managoat-Parent-Conversation-Id: $MANAGOAT_CONVERSATION_ID" \
  -d "$(jq -n --arg a "$AGENT_ID" --arg p "$PROMPT" '{agent_id:$a, prompt:$p}')" \
  | jq -r .data.id)

while :; do
  s=$(curl -s "$MANAGOAT_BASE_URL/api/conversations/$CONV" \
    -H "Authorization: Bearer $MANAGOAT_TOKEN" | jq -r .data.status)
  case "$s" in running|pending) sleep 2 ;; *) break ;; esac
done

curl -sN --max-time 5 \
  "$MANAGOAT_BASE_URL/api/conversations/$CONV/stream?streams=stdout&wait=false" \
  -H "Authorization: Bearer $MANAGOAT_TOKEN" \
| awk '/^data: /{sub(/^data: /,""); print}' \
| jq -r '.data | fromjson? | select(.type=="result") | .result' \
| tail -n1

# Terminate once you have the result — don't leave the sprite running.
curl -s -X POST "$MANAGOAT_BASE_URL/api/conversations/$CONV/terminate" \
  -H "Authorization: Bearer $MANAGOAT_TOKEN"
```

## SSE wire format (so you don't have to discover it)

A `curl -N` against `/api/conversations/:id/stream` produces lines like:

```
id: 2694
event: output
data: {"data":"{\"type\":\"result\",...}","stream":"stdout","stage":"turn",...}

id: 2695
event: output
data: {"data":"{\"type\":\"assistant\",...}","stream":"stdout",...}
```

Two layers of JSON. The `awk` strips the `data: ` prefix; jq's default parses
the **outer** object; **only the inner `.data` field is a JSON-encoded
string** that needs `fromjson` to peel. Do NOT call `fromjson` on the awk
output itself — jq already parsed it.

## The `wait=false` flag matters

The stream endpoint normally holds open for up to 60s waiting for new
events. **When the conversation is already done and you only want the
replay, pass `wait=false`.** Without it, your `curl --max-time 5` will sit
idle for the full 5 seconds. With it, the stream closes the moment the
replay drains — milliseconds.

Drop `wait=false` only when you actually want to live-tail.

## Per-runtime: where the final text lives

The conversation's `runtime` (`claude` / `codex` / `gemini`)
controls the shape of the inner JSON. Pull the runtime once, then pick the
right filter:

```bash
RT=$(curl -s "$MANAGOAT_BASE_URL/api/conversations/$CONV" \
  -H "Authorization: Bearer $MANAGOAT_TOKEN" | jq -r .data.runtime)
```

| runtime  | filter (the part **after** `.data \| fromjson?`)                       | text path        |
| -------- | ---------------------------------------------------------------------- | ---------------- |
| claude   | `select(.type=="result")`                                              | `.result`        |
| codex    | `select(.type=="item.completed" and .item.type=="agent_message")`      | `.item.text`     |
| gemini   | `select(.type=="message" and .role=="assistant")`                      | `.content` *(use the last one)*  |

## Vaults — running as a different identity

If you need a spawned conversation to run with credentials other than what the
agent's environment provides (e.g. contribute to GitHub as a specific user), pass
an optional `vault_id` when creating it. List vaults to find the one you want:

```bash
curl -s "$MANAGOAT_BASE_URL/api/vaults" -H "Authorization: Bearer $MANAGOAT_TOKEN" \
  | jq -r '.data[] | "\(.name)\t\(.id)"'

# Spawn with a specific vault layered on top of the env's secrets:
curl -s -X POST "$MANAGOAT_BASE_URL/api/conversations" \
  -H "Authorization: Bearer $MANAGOAT_TOKEN" -H "Content-Type: application/json" \
  -H "X-Managoat-Parent-Conversation-Id: $MANAGOAT_CONVERSATION_ID" \
  -d "$(jq -n --arg a "$AGENT_ID" --arg v "$VAULT_ID" --arg p "$PROMPT" \
        '{agent_id:$a, vault_id:$v, prompt:$p}')"
```

Vault values override the environment's baseline on key collision. Most fan-outs
don't need this — only reach for it when you specifically want different
credentials per spawned conversation.

## Each child gets its own machine

Every conversation runs on a sandbox of its own, so a child never shares your
disk. Hand it what it needs in the prompt (a repository URL, a branch, a
path to clone), not a path on this machine. Do not send `sandbox_id` (refused
with `422 sandbox_attach_unsupported`) or `sandbox_mode: "persistent"`
(refused with `422 persistent_sandbox_removed`).

## Multi-turn

Send a follow-up prompt to an existing conversation:

```bash
curl -s -X POST "$MANAGOAT_BASE_URL/api/conversations/$CONV/prompts" \
  -H "Authorization: Bearer $MANAGOAT_TOKEN" -H "Content-Type: application/json" \
  -d '{"prompt":"Now compare that to the worker service."}'
```

Then poll status / read the stream the same way. The runtime session
resumes — the agent remembers turn 1.

## Terminate agents when you're done

Every spawned conversation holds a live Sprite (a real compute sandbox) until
explicitly terminated or until Managoat's idle timeout fires. **Terminate as
soon as you have what you need** — don't leave agents idling.

```bash
# Terminate a single conversation:
curl -s -X POST "$MANAGOAT_BASE_URL/api/conversations/$CONV/terminate" \
  -H "Authorization: Bearer $MANAGOAT_TOKEN"

# Terminate a batch (e.g. after a fan-out gather):
echo "$ids" | xargs -n1 -P10 -I{} \
  curl -s -X POST "$MANAGOAT_BASE_URL/api/conversations/{}/terminate" \
    -H "Authorization: Bearer $MANAGOAT_TOKEN"
```

Terminate is idempotent — calling it on an already-terminated conversation is
harmless. It is **not** the same as deleting: the conversation record and its
stream history are preserved so you (or the operator) can audit what happened.
The Sprite is simply stopped and its resources released.

When to terminate:
- **After Pattern A gather** — terminate all N conversations once you have
  collected all results (see step 5 in Pattern A above).
- **After Pattern B** — terminate immediately after reading the stream.
- **On early exit / error** — if your script errors out before completing,
  terminate whatever you already spawned. A `trap` works well:

```bash
# Set up cleanup at the top of your script, before spawning anything.
spawned_ids=()
trap 'echo "${spawned_ids[@]}" | tr " " "\n" | xargs -n1 -P10 -I{} \
  curl -s -X POST "$MANAGOAT_BASE_URL/api/conversations/{}/terminate" \
    -H "Authorization: Bearer $MANAGOAT_TOKEN"' EXIT

# Register each id as you spawn it.
spawned_ids+=("$CONV")
```

## Important

- **Always terminate when done.** Sprites are real compute. Orphaned conversations run until Managoat's idle timeout — wasteful and expensive.
- **Always `wait=false` for gather.** Otherwise you'll burn N × `--max-time` seconds for no reason.
- **Parallelize spawn / poll / gather / terminate** with `xargs -P` — one provisioning takes ~5–15s, and there's no reason to do them sequentially.
- **Don't recurse forever.** Spawned agents have the same skill. Cap depth with a `MAX_DEPTH` you check before spawning.
- **Costs add up.** Every conversation provisions a real sandbox. Terminate promptly.
- **Re-read `$MANAGOAT_TOKEN` from env on each call.** It's a per-conversation key confined to this conversation's tree, not a long-lived admin token. Managoat rotates it on every fresh provision and every reattach (e.g. after a deploy or BEAM restart), revoking the previous value. If a request returns 401 with `"reason": "api_key_revoked"`, your cached copy is stale — re-source `$MANAGOAT_TOKEN` from the environment before retrying. Don't leak it outside the sprite.
- **API path is `/api/...`.** The retired browser `/conversations` path returns 404.
- **The token reaches your own tree, and spawns, but does not configure.** `$MANAGOAT_TOKEN` reads agents, environments, vaults and the names of their secrets, and starts conversations, which are always children of this one. It can show, stream, prompt, interrupt, terminate and delete this conversation and every conversation it (or its children) started. Any other conversation, including the one that started you and its other children, answers `404`. Listing or searching the account's conversations, `/api/events/stream`, `/api/apply`, and creating or changing an agent, environment, vault or secret answer `403` with `"error": "insufficient_scope"`. Keep the ids of the conversations you start, since you cannot list them. Ask the user for anything outside this; do not retry.
- **Provenance is automatic.** `MANAGOAT_CONVERSATION_ID` is always present in your sprite's environment. Every `POST /api/conversations` made with `$MANAGOAT_TOKEN` records this conversation as the parent, letting the operator reconstruct the full spawn chain. Sending `X-Managoat-Parent-Conversation-Id: $MANAGOAT_CONVERSATION_ID` is harmless; a header naming any other conversation is refused with `404 parent_conversation_not_found`.
- **Cloned repos are under `/workspace/`.** When an environment is configured with repositories, they are cloned to their configured `mount_path` (e.g. `/workspace/my-repo`) before the setup script runs. Always look in `/workspace/` first when you need to find source code.
