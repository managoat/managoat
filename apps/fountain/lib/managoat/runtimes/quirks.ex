defmodule Managoat.Runtimes.Quirks do
  @moduledoc """
  Every workaround Fountain carries on a runtime's behalf, the defect that
  justifies it, and the condition under which it is deleted.

  ## Why a registry rather than comments

  The comments already exist, and they are good ones — `Managoat.Runtimes.Claude`
  explains exactly why MCP servers go in as files, and ends with some version
  of "delete this when upstream lands."

  Nothing checks that. A workaround outliving its defect is invisible: it
  keeps working, so no test fails and no user complains, and the cost shows up
  only as the next person reasoning about a system that is stranger than it
  needs to be. Worse is the version where the upstream fix lands and the
  workaround now *conflicts* with it — the case
  `Managoat.Runtimes.Claude`'s moduledoc already anticipates, where a fixed
  session-scoped channel plus our file-based provisioning would register every
  MCP server twice.

  So each entry names the code that implements it as an MFA, and
  `quirks_test.exs` asserts that function still exists. Delete the workaround
  without the entry and the test fails; leave an entry pointing at code that
  is gone and the test fails. The registry cannot silently rot, which is the
  only property that makes it worth more than the comments.

  ## What is not a quirk

  A runtime doing something *unusual* is not a quirk. codex delivering its
  credential through `~/.codex/auth.json` (the file `codex login
  --with-api-key` writes) rather than `OPENAI_API_KEY` looks like one and is
  not: that is codex's documented auth mechanism, no upstream fix would remove it, and there is no condition under
  which we stop doing it. It belongs to the irreducible tier described in
  `Managoat.Runtimes`. The test for a quirk is whether you can state what
  would have to change for the code to be deleted. If you cannot, it is not a
  workaround — it is just how that runtime works.

  A registry that also carries facts loses the property that makes it worth
  more than comments: that everything in it has a deletion condition.

  ## Re-probing

  `reprobe` says how to find out whether the defect is still there. It is the
  checklist for a version bump: when the claude adapter pin moves, the
  question "does `session/new`'s `mcpServers` launch stdio servers yet?" has
  a known answer procedure, and if the answer changed the entry says what to
  delete.
  """

  @typedoc """
  `upstream` is a URL, or `{:none, reason}` for a workaround with no upstream
  to track — one we carry because of a decision on our own side, usually the
  sprite base image.
  """
  @type quirk :: %{
          id: atom(),
          runtimes: [String.t()],
          summary: String.t(),
          why: String.t(),
          upstream: String.t() | {:none, String.t()},
          measured_against: String.t(),
          implemented_by: {module(), atom(), arity()},
          reprobe: String.t(),
          delete_when: String.t()
        }

  @quirks [
    %{
      id: :claude_mcp_via_files,
      runtimes: ["claude"],
      summary: "claude's MCP servers are provisioned as files, not sent over ACP",
      why: """
      ACP defines a session-scoped channel for MCP servers (`session/new`'s
      `mcpServers`) and `Managoat.ACP.Peer` sends the agent's servers
      there correctly. claude-agent-acp never launches stdio servers passed
      that way, so the session-scoped path delivers nothing. We write them as
      user-scope servers instead, the `mcpServers` of
      `$CLAUDE_CONFIG_DIR/.claude.json` in the conversation's config home,
      which the CLI picks up through its `settingSources` (a project
      `.mcp.json` until ADR 0097).
      """,
      upstream: "https://github.com/agentclientprotocol/claude-agent-acp/issues/883",
      measured_against: """
      claude-agent-acp 0.66–0.70, reproduced standalone: broken. Re-probed on
      the 0.75.1 pin (2026-09-07), standalone with a stdio server passed only
      over `session/new`: the model lists and calls its `mcp__<server>__*`
      tools, so the session-scoped path works for stdio servers there. With
      both paths on for the same server name, the CLI registered it once —
      the double-registration this entry warned about did not occur. Not
      yet re-probed: an `http`/`sse` entry over the session-scoped path,
      which is how a host delivers a hosted connector with headers.
      """,
      implemented_by: {Managoat.Runtimes.Claude, :write_config, 3},
      reprobe: """
      Run a conversation with an MCP server declared on the agent, with
      `write_config/3` stubbed out, and check the model can call an
      `mcp__<server>__*` tool. If it can, the session-scoped path works.
      Repeat with an `http` entry carrying a header before deleting anything:
      the file path is the only one measured for that shape.
      """,
      delete_when: """
      `session/new`'s `mcpServers` launches stdio servers *and* connects
      `http`/`sse` entries. The first half is measured true on 0.75.1; the
      second is not measured. Then drop `Claude.write_config/3`. The 0.75.1
      re-probe found both paths on to be harmless for a same-named server, so
      the deletion is a clean-up rather than an urgency — but it stays a
      deletion, not a permanent second path.
      """
    },
    %{
      id: :gemini_usage_in_meta_quota,
      runtimes: ["gemini"],
      summary: "gemini's end-of-turn tokens are read from its own `_meta.quota`",
      why: """
      ACP defines `PromptResponse.usage` and gemini leaves it empty, reporting
      the turn's tokens under a vendor extension instead —
      `_meta.quota.token_count.{input_tokens, output_tokens}`, snake-cased,
      with no cache split. `Managoat.ACP.Usage` read the protocol field and
      the older flat `_meta.inputTokens`, so every gemini turn normalised to
      `nil`: a host that bills from that figure billed nothing, and a spend
      ceiling measured from those bills could not see gemini at all
      (managoat/fountain#1459). `Usage.from_meta_quota/1` reads the
      vendor shape; the protocol's own field still wins where both are
      present.
      """,
      upstream: "https://github.com/google-gemini/gemini-cli/issues/24280",
      measured_against: """
      gemini-cli 0.53.0, 0.56.0 and 0.59 — byte-identical returns in
      `packages/cli/src/acp/acpSession.ts` at all three, on every
      `session/prompt` outcome but `cancelled`.
      The empty figure was observed live on 2026-09-03, the populated one
      after this landed. Upstream closed the request for the standard fields
      with no plans.
      """,
      implemented_by: {Managoat.ACP.Usage, :from_meta_quota, 1},
      reprobe: """
      One gemini turn, reading the `session/prompt` result off the wire: does
      it carry a `usage` object beside its `_meta.quota`? The counts are the
      same either way, so the transcript cannot answer this — only the raw
      response can.
      """,
      delete_when: """
      gemini populates `PromptResponse.usage`. Then drop
      `Usage.from_meta_quota/1` and its clause in `from_prompt_result/1`.
      Order matters on the way out as it does now: `usage` is tried first, so
      an adapter that starts filling it is already preferred and the removal
      changes no figure. Confirm against a live turn before deleting — a
      version that fills `usage` with zeroes while the real counts stay in
      `_meta.quota` would silently start billing nothing again, which is the
      failure this entry exists for.
      """
    },
    %{
      id: :claude_opus_alias,
      runtimes: ["claude"],
      summary: "claude-opus-5 is selectable only with the opus alias pointed at it",
      why: """
      `session/set_config_option` accepts only the rows the bundled CLI lists,
      resolving a full model id onto the alias row that serves it. CLI 2.1.280
      (adapter 0.81.2) moved `opus` to Opus 5.5 and lists no Opus 5 row, so
      `claude-opus-5` is refused with "Invalid value for config option model".
      `ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5` points the alias back, and
      then `claude-opus-5-5` is the one refused: one Opus per process.
      `Claude.model_env/1` names the pair per turn, and the host spawns with it.
      """,
      upstream:
        {:none,
         "the CLI tracking the newest Opus under its alias is its design; " <>
           "the model is still served by the API"},
      measured_against:
        "claude-agent-acp 0.81.2 (CLI 2.1.280), 2026-09-25: plain, claude-opus-5 refused " <>
          "and claude-opus-5-5 served; with the env pair, claude-opus-5 served and " <>
          "claude-opus-5-5 refused (usage_update _meta._claude/model)",
      implemented_by: {Managoat.Runtimes.Claude, :model_env, 1},
      reprobe: """
      With the pinned adapter and no `ANTHROPIC_DEFAULT_OPUS_MODEL`, send
      `session/set_config_option` with `claude-opus-5`. If it is accepted, the
      CLI lists Opus 5 again and the pair is unnecessary.
      """,
      delete_when: """
      No host offers `claude-opus-5` any more (it is retired from the catalog
      and its agents moved), or a re-probe finds it accepted without the pair.
      Then drop `Claude.model_env/1` and this entry together.
      """
    },
    %{
      id: :claude_nonessential_traffic,
      runtimes: ["claude"],
      summary: "claude runs with CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1",
      why: """
      The first session on a fresh sandbox spent ~1.9 s in the SDK's
      `sdk-initialize` (the CLI starting), where every later session took
      ~0.4 s. It was not the disk (running the binary from tmpfs changed
      nothing), not a cache (nothing is written outside the config dir), and
      not DNS or connection setup (pre-warming them changed nothing). With the
      CLI's non-essential traffic off, the first session took 0.33–0.76 s.
      The flag also stops the CLI's auto-updater, telemetry, error reporting
      and `/bug`; the model list, Fable and the Opus alias are unchanged on an
      API key and on an OAuth token. `Claude.default_env/2` sets it.
      """,
      upstream:
        {:none,
         "the CLI waiting on its own non-essential calls at first start; file one " <>
           "if a first start should not block on them"},
      measured_against:
        "claude-agent-acp 0.81.2 (CLI 2.1.280) on fresh sprites, 2026-09-26: first " <>
          "sdk-initialize 1.88/1.93/0.39 s without the flag, 0.76/0.33/0.63 s with it",
      implemented_by: {Managoat.Runtimes.Claude, :default_env, 2},
      reprobe: """
      On a fresh sandbox, time the adapter's first `session/new` (its
      `[session/create] phase=sdk-initialize` log line) with and without the
      flag, three times each.
      """,
      delete_when: """
      A first start without the flag is as fast as with it, or a host needs the
      CLI's telemetry or auto-update. Then drop the pair from
      `Claude.default_env/2`.
      """
    },
    %{
      id: :claude_thinking_summaries,
      runtimes: ["claude"],
      summary: "claude streams thinking only with showThinkingSummaries set",
      why: """
      CLI 2.1.280 (adapter 0.81.2) defaults `showThinkingSummaries` to false,
      and the API then returns thinking with its display omitted. The adapter
      has no text to forward, so no `agent_thought_chunk` reaches the host
      where 0.75.1 streamed dozens per turn. `Claude.write_config/3` writes the
      setting into `$CLAUDE_CONFIG_DIR/settings.json` on every provision and wake.
      """,
      upstream:
        {:none,
         "a CLI default, not a defect; the adapter forwards whatever thinking text arrives"},
      measured_against:
        "claude-agent-acp 0.81.2 (CLI 2.1.280), 2026-09-25, claude-haiku-4-5: " <>
          "0 thought chunks without the setting, 41 with it",
      implemented_by: {Managoat.Runtimes.Claude, :write_config, 3},
      reprobe: """
      Run a turn that thinks (a haiku turn asked to reason briefly) with an
      empty `settings.json`, and count `agent_thought_chunk` updates.
      """,
      delete_when: """
      The CLI streams thinking text to the adapter by default again, or no host
      shows thinking. Then drop the setting from `Claude.write_config/3`.
      """
    },
    %{
      id: :sprite_node_shim,
      runtimes: ["claude", "codex"],
      summary: "npm-packaged adapters start on the recorded Node, not PATH's nvm shim",
      why: """
      A sprite's `node` on PATH is `/.sprite/bin/node`, a bash script that sets
      up nvm and then runs the real binary. It took ~0.8 s to start where the
      binary took 0.04 s, and the adapter's `#!/usr/bin/env node` paid that on
      every start: cold, reattach and wake. `ACP.install/3` records the real
      binary (`node -p process.execPath`, run while the packages download) and
      points the PATH link at a launcher that execs it, falling back to `node`
      on PATH when the record is missing or stale.
      """,
      upstream: {:none, "the sprite base image's nvm shim; report it to Sprites"},
      measured_against:
        "claude-agent-acp 0.81.2 on fresh sprites, node v24.18.0, 2026-09-26: " <>
          "bootstrap wrapper to `initialize` 0.93-1.61 s through the shim, " <>
          "0.38-0.55 s through the launcher",
      implemented_by: {Managoat.Runtimes.ACP, :install, 3},
      reprobe: """
      On a fresh sandbox, time `node -e 0` against `$(node -p
      process.execPath) -e 0`, three times each.
      """,
      delete_when: """
      `node` on the sprite's PATH starts within ~50 ms of the binary it runs.
      Then the launcher can go and the link can point at the entry again.
      """
    }
  ]

  @doc "Every recorded quirk, in declaration order."
  @spec all() :: [quirk()]
  def all, do: @quirks

  @doc "The quirks Fountain carries for one runtime."
  @spec for_runtime(String.t()) :: [quirk()]
  def for_runtime(runtime) when is_binary(runtime),
    do: Enum.filter(@quirks, &(runtime in &1.runtimes))

  @doc "One quirk by id, or nil."
  @spec get(atom()) :: quirk() | nil
  def get(id) when is_atom(id), do: Enum.find(@quirks, &(&1.id == id))

  @doc """
  Quirks with an upstream issue to watch, as `{id, url}` pairs — the ones
  whose deletion depends on somebody else. The rest are ours to remove
  whenever we decide to.
  """
  @spec upstream_tracked() :: [{atom(), String.t()}]
  def upstream_tracked do
    for %{id: id, upstream: url} <- @quirks, is_binary(url), do: {id, url}
  end
end
