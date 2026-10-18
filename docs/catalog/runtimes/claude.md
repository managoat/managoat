# Run Claude Code as an API

> Anthropic's Claude Code CLI, headless in the sandbox.

Run Claude Code on a sandbox with your repositories, packages and credentials.
Send a prompt over HTTP, follow the transcript, and send the next prompt to
the same conversation. Managoat manages the machine between turns.

To use a chat interface, [open Conversations](https://fountain-conversations.demo.managoat.com/).
To call it from your own code, follow the [quickstart](../../quickstart.md),
then use the agent definition below.

## Summary

| | |
|---|---|
| Provider | `anthropic` |
| Multi-provider | No |
| Transport | ACP, through the pinned `claude-agent-acp` adapter |
| Skills root | `$CLAUDE_CONFIG_DIR/skills`, in the conversation's [config home](index.md#where-skills-and-prompts-land) |
| System prompt | `$CLAUDE_CONFIG_DIR/CLAUDE.md` |
| Credential | An OAuth token or an API key. Read [which one it uses](#which-credential-it-uses). |

## Why you would choose this one

It is the default, and it is the most exercised path. Editor integration, the
permission flow and the block format all grew against it first.

## Set it up

```yaml
apiVersion: managoat/v1
kind: Agent
metadata:
  name: researcher
spec:
  runtime: claude
  model: anthropic/claude-sonnet-5
```

The model must carry the `anthropic/` prefix. Managoat rejects any other
prefix when you save the agent.

Add your credential at `/account/inference-credentials` in the app. An
operator cannot set one for you. Read
[Services Managoat uses](../../integrations/index.md).

## Which credential it uses

Two kinds work. If you hold both, **the OAuth token wins**.

| Credential | Bills |
|---|---|
| Claude Code OAuth token | Your Claude.ai subscription, Pro or Team. |
| Anthropic API key | Metered API usage. |

That preference matters to you and not to Managoat. A subscription you already
pay for is usually the one you want spent.

**Managoat exports exactly one into the sandbox, and never both.** Claude Code
prefers the OAuth path when it sees both, but the variable it picks has
changed between CLI versions. So Managoat chooses one, and it does not let the
CLI decide.

### When an organization disallows the subscription

An Anthropic organization can disable Claude subscription access for Claude
Code. After that, a turn that uses the OAuth token fails with
`oauth_org_not_allowed`.

Managoat recovers. It does not leave you to work it out.

- **With an API key on file**, the conversation moves to that key, and the
  turn fails with a message that says so. Send the prompt again and it runs.
- **Without one**, the turn fails with a message that tells you to add one.

Two details about the recovery matter.

**The turn still fails.** The switch is not a silent retry. The failure and the
fix both sit in the transcript, and not only in a log nobody reads.

**The switch lasts for that conversation, and not forever.** A new
conversation tries the OAuth token again. So an organization policy that
somebody later reverts heals on its own. It does not stay pinned to the
fallback.

## Call it over HTTP

After you apply the agent definition, set `MANAGOAT_AGENT_ID` to the returned
agent id, `MANAGOAT_BASE_URL` to your instance URL, and `MANAGOAT_API_KEY` to
your Managoat account key. The account key is separate from the model credential.

```sh
--8<-- "apps/fountain/priv/first_request/first-request.sh"
```

Use the returned conversation id to [follow events and send another prompt](../../guides/http-api.md).
A self-hosted instance uses the same request at its own base URL.

## When Claude asks a question

Claude Code has a tool named `AskUserQuestion`. With it, the agent asks you
to choose, and it does not guess. Each question waits for a person, so the
turn waits too.

**Managoat offers the tool only when a person answers the conversation.** That
is when its [permission policy](../../concepts/permissions.md) has an `ask`
verdict for some key. Under any other policy, the default `auto_allow`
included, Claude does not get the tool, and a conversation that nobody
watches never waits on a question.

```json
{ "default": "auto_allow", "execute": "ask" }
```

Under this policy Claude can ask you questions. It also asks before each
command it runs.

A question reaches the conversation stream as an `elicitation_request` block.
The block carries the agent's message in `body`, and the form in `schema`.
One block holds every question of one call, up to four. Each question is two
fields.

| Field | What it is |
|---|---|
| `question_0` | The choice. A string with `oneOf` for one answer, or an array with `items.anyOf` for several. Send the `const` of each choice. |
| `question_0_custom` | Free text, for an answer the choices do not hold. |

The next question is `question_1`, and so on. The question text is the
`description` of the field, or `body` when there is only one question.

Answer with `POST /api/conversations/{id}/requests/{request_id}`:

```json
{ "action": "accept", "content": { "question_0": "Postgres" } }
```

| `action` | What Claude does |
|---|---|
| `accept` | It reads the answers in `content`. A field you leave out is a question you skipped. |
| `decline` | It reads that you skipped every question, and it continues. |
| `cancel` | It stops that tool call. |

Managoat checks the answer against the form. A field the form does not have,
a value of the wrong type, or a choice it did not offer gets
`422 invalid_content`, and nothing reaches the agent.

The rules of a [permission request](../../concepts/permissions.md#when-a-human-answers)
hold here too. The first answer wins, and a later one gets `409`. The sandbox
cannot answer its own question. A question nobody answers in 5 minutes is
declined, and so is a question still open when its turn ends. Claude then
continues as if you skipped it.

The same block also carries two other forms, when they happen. An MCP server
can ask for input. And when a model refuses a request, Claude can ask whether
to retry it on another model. Answer each from its `schema`, the same way.

## Verify

Run a conversation, then ask it what model it is. A turn that reaches output
at all proves the credential, the runtime and the sandbox.

## Limits

**Managoat provisions the MCP servers. It does not pass them for each
session.** An upstream defect in `claude-agent-acp` breaks session-scoped MCP
delivery. So Managoat writes them as user-scope servers, the `mcpServers` of
`$CLAUDE_CONFIG_DIR/.claude.json` in the conversation's config home, and the
CLI starts them from there. The effect is the same and the mechanism is
different. A repository's own `.mcp.json` is the CLI's to decide about, as it
would be on your machine. That matters when you debug why a raw ACP probe behaves one way and
Managoat behaves another.

## Related

- [About agents](../../concepts/agent.md)
- [`managoat acp`](../../integrations/acp.md)
- [Runtimes](index.md)
