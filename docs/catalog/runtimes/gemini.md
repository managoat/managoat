# Run Gemini CLI as an API

> Google's Gemini CLI. The last runtime to reach ACP, and it reached it on
> 2026-08-22.

Run Gemini CLI on a sandbox with your repositories, packages and credentials.
Send a prompt over HTTP, follow the transcript, and send the next prompt to
the same conversation. Managoat manages the machine between turns.

To use a chat interface, [open Conversations](https://fountain-conversations.demo.managoat.com/).
To call it from your own code, follow the [quickstart](../../quickstart.md),
then use the agent definition below.

## Summary

| | |
|---|---|
| Provider | `google` |
| Multi-provider | No |
| Transport | ACP, through the CLI's own `--acp` flag |
| Skills root | `$GEMINI_CLI_HOME/.gemini/skills`, in the conversation's [config home](index.md#where-skills-and-prompts-land) |
| System prompt | `$GEMINI_CLI_HOME/.gemini/GEMINI.md` |
| Credential | A Gemini API key, exported as `GEMINI_API_KEY` |

## Why you would choose this one

You want a Gemini model in particular. That is the whole case.

Every runtime speaks ACP, so the transport no longer decides this.

## Set it up

```yaml
apiVersion: managoat/v1
kind: Agent
metadata:
  name: gemini-agent
spec:
  runtime: gemini
  model: google/gemini-3.1-pro-preview
```

Add your Gemini key at `/account/inference-credentials`.

## Call it over HTTP

After you apply the agent definition, set `MANAGOAT_AGENT_ID` to the returned
agent id, `MANAGOAT_BASE_URL` to your instance URL, and `MANAGOAT_API_KEY` to
your Managoat account key. The account key is separate from the model credential.

```sh
--8<-- "apps/fountain/priv/first_request/first-request.sh"
```

Use the returned conversation id to [follow events and send another prompt](../../guides/http-api.md).
A self-hosted instance uses the same request at its own base URL.

## Verify

Run a conversation, then ask it what model it is. A turn that reaches output
at all proves the credential, the runtime and the sandbox.

## Limits

**Every turn after the first replays the whole transcript.** Gemini advertises
`loadSession` and no resume capability, so a turn loads the session again from
the start. Managoat discards that replay. The cost is time at the head of a
turn, and it grows with the transcript. The other two runtimes reattach.

**Managoat repairs gemini's session store after every turn.** The store
deletes a session while it loads it, an upstream defect
([gemini-cli#28775](https://github.com/google-gemini/gemini-cli/issues/28775)).
Managoat consolidates the store at the end of each turn, so a load cannot
collide with what it loads. That workaround goes away when upstream lands a
fix.

## Related

- [About agents](../../concepts/agent.md)
- [`managoat acp`](../../integrations/acp.md)
- [Runtimes](index.md)
