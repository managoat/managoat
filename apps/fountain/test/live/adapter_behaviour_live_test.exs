defmodule Fountain.LiveAdapter do
  @moduledoc false
  # The pinned ACP adapters (managoat_runtimes' table) driven by the pinned
  # peer (managoat_acp) in a real sandbox, the way a Fountain turn drives
  # them. A pin bump of either library, or of an adapter in the runtimes
  # table, can change what an adapter does with a permission answer, its modes
  # and its session config options without failing any stubbed test (#2670).
  # This suite is that gate; `contributing/component-libraries.md` says when
  # it must pass. From apps/fountain, with the test database migrated (the
  # application boots, though the suite writes no rows):
  #
  #     E2B_API_KEY=... E2B_BASE_URL=... ANTHROPIC_API_KEY=... OPENAI_API_KEY=... \
  #       mix test --only live_adapter test/live/adapter_behaviour_live_test.exs
  #
  # Each runtime can run on a gateway that speaks its vendor's API instead:
  # `OPENAI_BASE_URL` (with `/v1`) and `OPENAI_MODEL` for codex,
  # `ANTHROPIC_BASE_URL` (without) and `ANTHROPIC_MODEL` for claude,
  # `GOOGLE_GEMINI_BASE_URL` (without) and `GEMINI_MODEL` for gemini, the
  # model being the one the gateway serves.
  # It then serves every check, the cheap ones too (`gateway_env/1`). The
  # vendor key variables carry the gateway's key.
  #
  # `--only runtime:claude`, `--only runtime:codex` or `--only runtime:gemini`
  # runs one runtime (gemini also needs GEMINI_API_KEY). It creates one billed
  # E2B sandbox per runtime (production's `fountain` template unless
  # E2B_TEMPLATE says otherwise), destroyed when the module finishes, and
  # spends a few model turns on each key. Gemini runs only the
  # `"auth": "conversation"` check (`check_conversation_auth/2`).
  #
  # Each runtime's expectations are its `expect/0` map, at the bottom, written
  # from what the pinned adapter was measured to do. A bump that changes one
  # fails here. Update the map in the same PR as the bump, along with what
  # cites the behaviour: ADR 0014's 2026-10-15 addenda, ADR 0062's, and
  # docs/concepts/permissions.md.
  #
  # ## On Sprites (opt-in, by hand)
  #
  # `LIVE_ADAPTER_SANDBOX=sprites` runs the same suite on Sprites instead of
  # E2B, with `SPRITES_TOKEN` (and `SPRITES_BASE_URL`, default
  # api.sprites.dev) in place of the E2B variables. E2B stays the default, and
  # `live-adapters.yml`, which runs at release, never sets it. Sprites is where
  # `Managoat.Runtimes.ACP` reuses the image's own CLI (`@image_reuse`), so
  # only this mode exercises that path. It adds three checks per runtime
  # (`check_image_reuse/2`, `check_fresh_resume/2`, and for codex
  # `check_load/3`) and skips the E2B-only suspend/wake check:
  #
  #     LIVE_ADAPTER_SANDBOX=sprites SPRITES_TOKEN=... \
  #       ANTHROPIC_API_KEY=... OPENAI_API_KEY=... \
  #       mix test --only runtime:codex --only runtime:claude \
  #         test/live/adapter_behaviour_live_test.exs
  #
  # The gateway variables above work the same way. A Sprites token reaches
  # every sprite in its organization, so the suite names each sprite
  # `fountain-live-adapter-sprites-<run id>-<runtime>`, prints the name, and
  # destroys only that name when the module finishes
  # (`Fountain.LiveAdapterSandbox`). The run id is new each run.
  #
  # The adapter is spawned the way `TurnLaunch` spawns it, policy included: a
  # policy that asks puts codex in its asking mode (`CodexApproval`, #2708).
  # So the permission checks run under a policy that asks, and the
  # "allowing policy" check under one that allows everything.

  import ExUnit.Assertions

  alias Fountain.Agents.{Agent, SessionConfig}
  alias Fountain.Conversations.{CodexApproval, Connection, McpServers, Provisioning, TurnMachine}
  alias Fountain.LiveAdapterSandbox
  alias Managoat.ACP.Protocol

  @turn_timeout 240_000

  def env!(name) do
    case System.get_env(name) do
      blank when blank in [nil, ""] -> raise "#{name} is not set; the live adapter suite needs it"
      value -> value
    end
  end

  def env(name, default) do
    case System.get_env(name) do
      blank when blank in [nil, ""] -> default
      value -> value
    end
  end

  def configure_e2b! do
    Application.put_env(:fountain, Managoat.Sandbox.E2B,
      api_key: env!("E2B_API_KEY"),
      base_url: env("E2B_BASE_URL", "https://api.e2b.app"),
      template: env("E2B_TEMPLATE", "fountain"),
      user: env("E2B_USER", "sprite"),
      timeout_ms: 60_000
    )
  end

  def configure_sprites! do
    Application.put_env(
      :fountain,
      Managoat.Sandbox.Sprites,
      LiveAdapterSandbox.sprites_config(
        env!("SPRITES_TOKEN"),
        env("SPRITES_BASE_URL", "https://api.sprites.dev")
      )
    )
  end

  def configure!(:e2b), do: configure_e2b!()
  def configure!(:sprites), do: configure_sprites!()

  # One run id for the whole run: this file is compiled each time the suite
  # runs, so every module of a run shares it and no other run has it.
  @sprites_prefix LiveAdapterSandbox.run_prefix({:sprites, LiveAdapterSandbox.run_id()})

  defp prefix(:e2b), do: LiveAdapterSandbox.run_prefix(:e2b)
  defp prefix(:sprites), do: @sprites_prefix

  @doc """
  A sandbox for `runtime` on `mode`'s provider, as provisioning leaves it: the
  runtime's config, its credentials and the pinned adapter. `credentials`
  maps an inference credential to the env var holding it; the values are read
  here and never pass through a call that could print them in a failure.
  """
  def provision!(mode, runtime, credentials) do
    {:ok, mod} = Managoat.Runtimes.for_runtime(runtime)
    name = LiveAdapterSandbox.name(mode, prefix(mode), runtime)
    handle = create!(mode, name)

    # A conversation's own config home, as every launch gets one (ADR 0097).
    conv = %{
      id: Ecto.UUID.generate(),
      user_id: nil,
      runtime: runtime,
      cwd: nil,
      config_home: nil
    }

    conv = %{conv | config_home: Managoat.Runtimes.Layout.config_home(conv.id)}

    sprite_env =
      Managoat.Runtimes.default_env(mod, nil, Map.new(credentials, fn {k, v} -> {k, env!(v)} end)) ++
        Managoat.Runtimes.config_env(mod, conv.config_home) ++
        gateway_env(runtime)

    # The real pinned bundles, as a release carries them: `mix acp.bundles`
    # fetches and verifies them into the umbrella's _build/acp-bundles/ (the
    # workflow runs it first), where the test config would read a stub's.
    Application.put_env(:fountain, :acp_bundle_dir, bundle_dir!())
    :ok = Provisioning.write_runtime_config(handle, mod, nil, conv.config_home)

    :ok =
      Provisioning.prepare_runtime_sprite(handle, conv, runtime, mod, nil, sprite_env, nil)

    :ok = gateway_config!(handle, runtime, conv.config_home)

    %{handle: handle, runtime: runtime, module: mod, sprite_env: sprite_env, broker: nil}
  end

  defp bundle_dir! do
    dir = Path.expand("../../../../_build/acp-bundles", __DIR__)

    for {_runtime, %{file: file}} <- Managoat.Runtimes.ACP.bundles(),
        not File.regular?(Path.join(dir, file)) do
      raise "#{file} is not in #{dir}: run `mix acp.bundles` from the umbrella root first"
    end

    dir
  end

  defp create!(:e2b, name) do
    {:ok, handle} = Managoat.Sandbox.create(:e2b, name)
    ExUnit.Callbacks.on_exit(fn -> Managoat.Sandbox.destroy(handle) end)
    handle
  end

  # As `Fountain.Machines.Provision` creates one: retried, since a create
  # whose response was lost is adopted by name on the next attempt, then held
  # until it answers an exec, since a fresh sprite refuses work for its first
  # seconds (#2491). The destroy is registered by name before the create, so a
  # create that raised after the sprite came into being is still cleaned up,
  # and it names only this run's sprite.
  defp create!(:sprites, name) do
    IO.puts("live adapter sprite: #{name} (destroyed when this module finishes)")
    ExUnit.Callbacks.on_exit(fn -> destroy_sprite(name) end)

    {:ok, handle} =
      Managoat.Sandbox.Retry.with_backoff(fn -> Managoat.Sandbox.create(:sprites, name) end,
        label: "live sprite create #{name}"
      )

    {:ok, _, 0} =
      Managoat.Sandbox.Retry.with_backoff(
        fn -> Managoat.Sandbox.exec(handle, "true", [], timeout: 30_000) end,
        attempts: 8,
        base_ms: 1_000
      )

    handle
  end

  defp destroy_sprite(name) do
    case Managoat.Sandbox.destroy(Managoat.Sandbox.build_handle(:sprites, name)) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts("live adapter sprite #{name}: destroy returned #{inspect(reason)}")
    end
  end

  @doc """
  The env that points a runtime at an OpenAI- or Anthropic-compatible
  gateway rather than the vendor, from the runner's env, or `[]`.

  codex: `OPENAI_BASE_URL` (with `/v1`) and `OPENAI_MODEL`, the model the
  gateway serves. `gateway_config!/3` writes codex's side; here,
  `MODEL_PROVIDER` holds a resumed thread on the gateway's provider, as it
  does for `CodexTransport`'s in production.

  claude: `ANTHROPIC_BASE_URL` (without `/v1`) and `ANTHROPIC_MODEL`.
  claude-agent-acp accepts only its catalog's rows, so every alias, the
  small model and the subagents' model are pointed at the gateway's model:
  the suite still selects a row (`model/1`), and the CLI's background calls,
  which a key limited to one model would refuse, go to the same model.

  gemini: `GOOGLE_GEMINI_BASE_URL` (without `/v1beta`) and `GEMINI_MODEL`;
  `gateway_config!/3` points its helper models at the same one.
  """
  @gateway_provider "live_gateway"

  def gateway_env("codex") do
    if gateway("codex"), do: [{"MODEL_PROVIDER", @gateway_provider}], else: []
  end

  def gateway_env("claude") do
    case gateway("claude") do
      nil ->
        []

      {base, model} ->
        [{"ANTHROPIC_BASE_URL", base}] ++
          for name <-
                ~w(ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
                   ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL
                   CLAUDE_CODE_SUBAGENT_MODEL),
              do: {name, model}
    end
  end

  def gateway_env("gemini") do
    case gateway("gemini") do
      nil -> []
      {base, model} -> [{"GOOGLE_GEMINI_BASE_URL", base}, {"GEMINI_MODEL", model}]
    end
  end

  def gateway_env(_runtime), do: []

  @doc """
  codex on a gateway, in `~/.codex/config.toml`, which the app server reads
  at start (`CODEX_CONFIG` reaches only the thread):

    * **A provider of its own** with the WebSocket transport off, as
      `CodexTransport` declares in production. On the built-in provider,
      with only `OPENAI_BASE_URL` pointing at the gateway, every turn ended
      on "Authentication required" (measured 2026-10-16).
    * **A model catalog of one model**, the gateway's. codex-acp sets only a
      model of the catalog or the one codex started on, and codex's fallback
      metadata for a model it does not know offers no `reasoning_effort`.
      The entry also names itself as the automatic reviewer's model
      (`auto_review_model_override`), which is otherwise a GPT model the
      gateway's key may not call.
  """
  def gateway_config!(handle, "codex", home) do
    with {base, model} <- gateway("codex") do
      root = Managoat.Runtimes.Layout.config_dir("codex", home)
      catalog = Path.join(root, "live-gateway-models.json")

      :ok =
        Managoat.Sandbox.write_file(
          handle,
          catalog,
          Jason.encode!(%{models: [catalog_entry(model)]})
        )

      :ok =
        Managoat.Sandbox.write_file(handle, Path.join(root, "config.toml"), """
        model = #{Jason.encode!(model)}
        model_provider = "#{@gateway_provider}"
        model_catalog_json = #{Jason.encode!(catalog)}

        [model_providers.#{@gateway_provider}]
        name = "gateway"
        base_url = #{Jason.encode!(base)}
        wire_api = "responses"
        env_key = "OPENAI_API_KEY"
        supports_websockets = false
        """)
    end

    :ok
  end

  # gemini-cli runs its helpers (the router's classifier, summaries, edit
  # correction, loop detection, the next-speaker check, chat compression,
  # web fetch and search) on models of their own, named by the aliases of
  # its `DEFAULT_MODEL_CONFIGS` (checked against 0.64.0). Each is pointed at
  # the gateway's model; nothing else writes this settings file in the suite.
  @gemini_helper_aliases ~w(
    classifier prompt-completion fast-ack-helper edit-corrector
    summarizer-default summarizer-shell web-search web-fetch web-fetch-fallback
    loop-detection loop-detection-double-check llm-edit-fixer
    next-speaker-checker context-snapshotter agent-history-provider-summarizer
    gemini-2.5-flash-base gemini-3-flash-base gemini-3.5-flash-base
    chat-compression-default chat-compression-3-pro chat-compression-3-flash
    chat-compression-3.1-flash-lite chat-compression-2.5-pro
    chat-compression-2.5-flash chat-compression-2.5-flash-lite
  )

  def gateway_config!(handle, "gemini", home) do
    with {_base, model} <- gateway("gemini") do
      aliases = Map.new(@gemini_helper_aliases, &{&1, %{modelConfig: %{model: model}}})
      settings = %{model: %{name: model}, modelConfigs: %{customAliases: aliases}}
      path = Managoat.Runtimes.Gemini.settings_path(home)
      :ok = Managoat.Sandbox.write_file(handle, path, Jason.encode!(settings))
    end

    :ok
  end

  def gateway_config!(_handle, _runtime, _home), do: :ok

  # The fields codex 0.160's catalog entries carry, for a text-only model
  # with a 32K window. Checked against the catalog that binary embeds.
  # `apply_patch_tool_type` is the catalog's `freeform`, which every entry
  # there sets: without it codex offers no file editing tool, and a model
  # asked to use one (`edit_prompt/1`) refuses (gpt-5.6-luna, 2026-10-16).
  # It is a custom tool, which the gateway's model must support.
  defp catalog_entry(model) do
    %{
      slug: model,
      display_name: model,
      description: "The gateway's model.",
      base_instructions:
        "You are Codex, a coding agent running in a terminal. Do what the user asks " <>
          "with the tools you have, then reply briefly.",
      model_messages: nil,
      prefer_websockets: false,
      support_verbosity: false,
      default_verbosity: nil,
      apply_patch_tool_type: "freeform",
      web_search_tool_type: "text",
      input_modalities: ["text"],
      supports_image_detail_original: false,
      truncation_policy: %{mode: "bytes", limit: 10_000},
      supports_parallel_tool_calls: false,
      tool_mode: nil,
      multi_agent_version: nil,
      multi_agent_reasoning_effort: nil,
      use_responses_lite: false,
      supports_reasoning_effort_updates: false,
      include_skills_usage_instructions: false,
      include_apps_usage_instructions: false,
      include_plugin_usage_instructions: false,
      guardian: nil,
      node_repl_auto_review_required: false,
      node_repl_disabled: false,
      requires_sandboxed_review: false,
      auto_review_model_override: model,
      model_specialty: nil,
      context_window: 32_768,
      max_context_window: 32_768,
      auto_compact_token_limit: nil,
      comp_hash: "0",
      default_reasoning_summary: "none",
      default_reasoning_level: "low",
      supported_reasoning_levels:
        for(effort <- ~w(low medium high), do: %{effort: effort, description: effort}),
      shell_type: "unified_exec",
      visibility: "list",
      minimal_client_version: "0.124.0",
      supported_in_api: true,
      availability_nux: nil,
      upgrade: nil,
      priority: 1,
      experimental_supported_tools: [],
      available_in_plans: [],
      supports_search_tool: false,
      supports_experimental_context: false,
      default_service_tier: nil,
      service_tiers: [],
      additional_speed_tiers: [],
      supports_reasoning_summary_parameter: false,
      supports_reasoning_summaries: false
    }
  end

  # `{base_url, model}` when the runtime runs on a gateway, else nil. Both
  # are needed: a gateway without its model would be sent the vendor's.
  defp gateway(runtime) do
    {url, model} =
      case runtime do
        "codex" -> {"OPENAI_BASE_URL", "OPENAI_MODEL"}
        "claude" -> {"ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL"}
        "gemini" -> {"GOOGLE_GEMINI_BASE_URL", "GEMINI_MODEL"}
      end

    case {env(url, nil), env(model, nil)} do
      {nil, nil} -> nil
      {base, id} when is_binary(base) and is_binary(id) -> {base, id}
      _ -> raise "#{url} and #{model} name a gateway together; set both or neither"
    end
  end

  @doc """
  Spawn the adapter and start a peer on it, as `TurnLaunch` does, with the
  approval mode the policy chooses. `opts`: `:mode` (`:run` | `:continue`),
  `:session_id`, `:config`, `:policy`, `:model` (a canonical model string,
  default `model/1`'s), `:conversation_id` (the process ownership tag),
  and `:mcp_servers` (the `session/new` list, as
  `McpServers.for_session/2` builds it). Returns the connection; the first
  turn is already sent.
  """
  def open(sandbox, prompt, opts) do
    %{command: command, cwd: cwd, model: model, policy: policy} = spawn_adapter(sandbox, opts)

    {peer, _mon} =
      TurnMachine.start_acp_peer(
        command,
        prompt,
        Keyword.get(opts, :mode, :run),
        Keyword.get(opts, :session_id) || Ecto.UUID.generate(),
        cwd: cwd,
        model: model,
        mcp_servers: Keyword.get(opts, :mcp_servers, []),
        config: Keyword.get(opts, :config, %{}),
        permission_policy: policy
      )

    %{command: command, peer: peer, ref: command.ref, model: model}
  end

  # The adapter process alone, spawned as `open/3` spawns it, for a check that
  # speaks ACP to it without a peer (`check_load/3`).
  defp spawn_adapter(sandbox, opts) do
    %{handle: handle, runtime: runtime} = sandbox
    {cmd, args} = Fountain.RuntimeDispatch.command(runtime, nil)

    {cmd, args} =
      case Keyword.get(opts, :conversation_id) do
        nil -> {cmd, args}
        id -> Fountain.Conversations.Identity.tag_command(id, cmd, args)
      end

    cwd = Managoat.Sandbox.host_path(handle, Fountain.RuntimeDispatch.cwd(runtime))

    model =
      case Keyword.fetch(opts, :model) do
        {:ok, canonical} -> Fountain.RuntimeDispatch.acp_model(runtime, canonical)
        :error -> model(runtime)
      end

    policy = Managoat.ACP.Permissions.effective(Keyword.get(opts, :policy), nil)
    env = CodexApproval.put_env(sandbox.sprite_env, CodexApproval.env(runtime, policy))

    {:ok, command} =
      Connection.spawn_command(sandbox, runtime, cmd, args,
        env: env ++ Managoat.Runtimes.model_env(sandbox.module, model),
        owner: self(),
        stdin: true,
        tty: false,
        dir: cwd,
        detachable: true
      )

    %{command: command, cwd: cwd, model: model, policy: policy}
  end

  def close(%{command: command, peer: peer}) do
    Managoat.Sandbox.close_stdin(command)
    Managoat.ACP.Peer.close(peer)
    Managoat.Sandbox.stop_command(command)
  end

  @doc "The next turn on an open connection, as `Connection.resume/7` sends it."
  def prompt(conn, prompt, config) do
    :ok = Managoat.ACP.Peer.prompt(conn.peer, prompt, [], model: conn.model, config: config)
  end

  @doc """
  Collect one turn's reports until `{:done, …}` or `{:failed, …}`. Each
  permission request is handed to `on_ask.(request_id, tool, options)`, which
  answers it. Returns `%{stop:, reports:, asks:, text:}`.
  """
  def await_turn(conn, on_ask \\ fn _id, _tool, _options -> :deny end) do
    await_turn(conn, on_ask, %{stop: nil, reports: [], asks: [], text: "", stderr: ""})
  end

  defp await_turn(%{ref: ref} = conn, on_ask, acc) do
    receive do
      {:stdout, %{ref: ^ref}, data} ->
        Managoat.ACP.Peer.stdout(conn.peer, data)
        await_turn(conn, on_ask, acc)

      {:stderr, %{ref: ^ref}, data} ->
        await_turn(conn, on_ask, %{acc | stderr: acc.stderr <> data})

      {:exit, %{ref: ^ref}, code} ->
        flunk(
          "adapter exited #{code} mid-turn; stderr:\n#{String.slice(acc.stderr, -4000, 4000)}"
        )

      {:acp, ^ref, {:done, stop, _usage}} ->
        %{acc | stop: stop, reports: Enum.reverse(acc.reports)}

      {:acp, ^ref, {:failed, reason}} ->
        flunk(
          "turn failed: #{inspect(reason)}; stderr:\n#{String.slice(acc.stderr, -4000, 4000)}"
        )

      {:acp, ^ref, {:permission_ask, id, tool, options} = ask} ->
        answer(conn, id, options, on_ask.(id, tool, options))
        await_turn(conn, on_ask, %{acc | asks: [ask | acc.asks], reports: [ask | acc.reports]})

      {:acp, ^ref, {:lines, "acp", data} = report} ->
        acc = %{acc | text: acc.text <> agent_text(data), reports: [report | acc.reports]}
        await_turn(conn, on_ask, acc)

      {:acp, ^ref, report} ->
        await_turn(conn, on_ask, %{acc | reports: [report | acc.reports]})
    after
      @turn_timeout -> flunk("no end of turn in #{@turn_timeout} ms: #{inspect(acc)}")
    end
  end

  defp answer(conn, id, _options, :deny), do: Managoat.ACP.Peer.deny_permission(conn.peer, id)

  defp answer(conn, id, options, :allow_once) do
    option = Enum.find(options, &(&1["kind"] == "allow_once")) || flunk("no allow_once offered")
    :ok = Managoat.ACP.Peer.answer_permission(conn.peer, id, option["optionId"])
  end

  # The assistant's text out of a run of session/update lines.
  defp agent_text(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.map_join(fn line ->
      case Jason.decode(line) do
        {:ok,
         %{
           "params" => %{
             "update" => %{
               "sessionUpdate" => "agent_message_chunk",
               "content" => %{"text" => text}
             }
           }
         }} ->
          text

        _ ->
          ""
      end
    end)
  end

  @doc """
  What a turn did, for a failure message: how it ended, its tool calls, the
  assistant's text and the tail of the adapter's stderr. A turn that ends
  without a tool call is as often the model or its API refusing (a quota, a
  rate limit, an unknown model) as an adapter change; the text and stderr
  say which.
  """
  def describe(turn) do
    "stop: #{inspect(turn.stop)}\ntools:\n#{tools(turn)}\ntext: " <>
      inspect(String.slice(turn.text, 0, 2000)) <>
      "\nstderr:\n#{String.slice(turn.stderr, -4000, 4000)}"
  end

  @doc "The turn's tool calls and their updates, one line each, for a failure message."
  def tools(turn) do
    for {:lines, "acp", data} <- turn.reports,
        line <- String.split(data, "\n", trim: true),
        {:ok, %{"params" => %{"update" => %{"sessionUpdate" => kind} = update}}} <-
          [Jason.decode(line)],
        kind in ["tool_call", "tool_call_update"] do
      Map.take(update, ["title", "kind", "status", "rawInput", "rawOutput", "content"])
      |> inspect(printable_limit: 600, limit: 30)
    end
    |> Enum.join("\n")
  end

  def model(runtime) do
    model =
      case runtime do
        "claude" -> env("LIVE_ADAPTER_CLAUDE_MODEL", default_model("claude", "claude-sonnet-5"))
        "codex" -> env("LIVE_ADAPTER_CODEX_MODEL", default_model("codex", "gpt-6-astra"))
        "gemini" -> env("LIVE_ADAPTER_GEMINI_MODEL", default_model("gemini", "gemini-3.5-flash"))
      end

    Fountain.RuntimeDispatch.acp_model(runtime, model)
  end

  @doc """
  The cheapest model each runtime's catalog suggests, for a check that needs
  one tool call and no judgement. Codex's catalog has the one. On a gateway
  it is the gateway's one model.
  """
  def cheap_model("claude"), do: default_model("claude", "claude-haiku-4-5")
  def cheap_model("codex"), do: default_model("codex", "gpt-6-astra")
  def cheap_model("gemini"), do: default_model("gemini", "gemini-3.5-flash")

  # The vendor's model, or on a gateway the one it serves: codex selects it
  # by its own name, claude by the `sonnet` row, which `gateway_env/1`
  # points at it.
  defp default_model(runtime, vendor) do
    case {runtime, gateway(runtime)} do
      {"codex", nil} -> "openai/" <> vendor
      {"codex", {_, id}} -> "openai/" <> id
      {"claude", nil} -> "anthropic/" <> vendor
      {"claude", _} -> "anthropic/sonnet"
      {"gemini", nil} -> "google/" <> vendor
      {"gemini", {_, id}} -> "google/" <> id
    end
  end

  def session_id(turn) do
    Enum.find_value(turn.reports, fn
      {:session, id} -> id
      _ -> nil
    end)
  end

  @doc "The last option list the peer reported before the turn's prompt."
  def options(turn) do
    turn.reports
    |> Enum.filter(&match?({:config_options, _}, &1))
    |> List.last()
    |> case do
      {:config_options, options} -> options
      nil -> flunk("the peer reported no config options: #{inspect(turn.reports)}")
    end
  end

  def option(options, id),
    do: Enum.find(options, &(&1["id"] == id)) || flunk("no #{id} option in #{inspect(options)}")

  def values(%{"options" => options}), do: Enum.flat_map(options, &values/1)
  def values(%{"value" => value}), do: [value]
  def values(_), do: []

  def file?(sandbox, path) do
    {:ok, out, 0} =
      Managoat.Sandbox.exec(sandbox.handle, "bash", [
        "-c",
        "test -e #{path} && echo yes || echo no"
      ])

    String.trim(out) == "yes"
  end

  # ── the checks: one per test, `e` is the runtime's expect/0 map ──────────

  @doc """
  ADR 0062, addendum of 2026-10-15 (agent only): every turn of a
  conversation sends the same request, its agent's options from launch. The
  option is set on the first turn and holds on the next, where the peer finds
  it already in force. Nothing is put back between turns.
  """
  def check_held(sandbox, e) do
    id = e.effort_option
    conn = open(sandbox, "Reply with the single word ready.", config: %{})
    ExUnit.Callbacks.on_exit(fn -> close(conn) end)

    first = await_turn(conn)
    assert first.stop == "end_turn"
    baseline = option(options(first), id)["currentValue"]
    assert baseline in values(option(options(first), id))
    raised = Enum.find(values(option(options(first), id)), &(&1 != baseline))

    prompt(conn, "Reply with the single word set.", %{id => raised})
    set = await_turn(conn)
    assert set.stop == "end_turn"
    assert {:config_selected, ^id, ^raised, ^raised} = find(set, :config_selected)
    assert option(options(set), id)["currentValue"] == raised

    prompt(conn, "Reply with the single word again.", %{id => raised})
    again = await_turn(conn)
    assert again.stop == "end_turn"
    assert {:config_selected, ^id, ^raised, _} = find(again, :config_selected)
    assert option(options(again), id)["currentValue"] == raised

    IO.puts("#{e.runtime} #{id}: baseline #{inspect(baseline)}, held #{inspect(raised)}")
  end

  @doc """
  A session resumed on a new connection comes back at the adapter's default.
  Every park, wake and idle close resumes on a new one, which is why each turn
  sends its whole request rather than relying on what the session last held.
  """
  def check_resume(sandbox, e) do
    id = e.effort_option
    conn = open(sandbox, "Reply with the single word ready.", config: %{})
    first = await_turn(conn)
    baseline = option(options(first), id)["currentValue"]
    raised = Enum.find(values(option(options(first), id)), &(&1 != baseline))

    prompt(conn, "Reply with the single word set.", %{id => raised})
    set = await_turn(conn)
    assert option(options(set), id)["currentValue"] == raised
    close(conn)

    resumed =
      open(sandbox, "Reply with the single word resumed.",
        mode: :continue,
        session_id: session_id(first),
        config: %{}
      )

    ExUnit.Callbacks.on_exit(fn -> close(resumed) end)
    turn = await_turn(resumed)
    assert turn.stop == "end_turn"
    assert option(options(turn), id)["currentValue"] == baseline
  end

  @doc "A detached E2B writer is identified on wake and its thread resumes with history."
  def check_writer_wake(sandbox) do
    alias Fountain.Conversations.Identity

    conversation_id = Ecto.UUID.generate()
    marker = "remember-#{Ecto.UUID.generate()}"

    conn =
      open(sandbox, "Remember this exact marker: #{marker}. Reply ready. Do not use tools.",
        conversation_id: conversation_id
      )

    ExUnit.Callbacks.on_exit(fn -> close(conn) end)
    first = await_turn(conn)
    assert first.stop == "end_turn"
    assert is_binary(session_id(first))
    prompt(conn, "Keep that marker in memory. Reply ready again. Do not use tools.", %{})
    assert await_turn(conn).stop == "end_turn"

    # Model server replacement: stop only the local peer/transport, leaving
    # the detachable adapter and its writer alive inside the sandbox.
    Managoat.ACP.Peer.close(conn.peer)
    :ok = Managoat.Sandbox.stop_command(conn.command)
    assert :ok = Managoat.Sandbox.suspend(sandbox.handle)
    assert {:ok, handle} = Managoat.Sandbox.resume(sandbox.handle)
    sandbox = %{sandbox | handle: handle}

    assert {:ok, sessions} = Managoat.Sandbox.list_sessions(sandbox.handle)
    assert [owner] = Identity.owned_sessions(sandbox.handle, sessions, conversation_id)

    # The matcher before #2870 cannot see this quoted tag, so wake skips
    # cleanup. Reproduce that decision against the same live process list.
    old_tag = ~r/(?:^|\s)(?:MANAGOAT|FOUNTAIN)_CONVERSATION_ID=([0-9a-fA-F-]{36})(?:\s|$)/
    refute Regex.match?(old_tag, owner.command)

    contender =
      open(sandbox, "This prompt must never reach the model.",
        mode: :continue,
        session_id: session_id(first),
        conversation_id: conversation_id
      )

    ExUnit.Callbacks.on_exit(fn -> close(contender) end)
    thread_id = session_id(first)

    assert {:acp_error, :resume_session,
            %{
              "code" => -32_600,
              "data" => %{"reason" => "thread_active_writer", "threadId" => ^thread_id}
            }} = await_resume_conflict(contender)

    close(contender)
    assert :ok = Connection.reap_session(sandbox.handle, owner.id)

    resumed =
      open(sandbox, "Reply with only the exact marker I asked you to remember. Do not use tools.",
        mode: :continue,
        session_id: session_id(first),
        conversation_id: conversation_id
      )

    ExUnit.Callbacks.on_exit(fn -> close(resumed) end)
    third = await_turn(resumed)
    assert third.stop == "end_turn", describe(third)
    assert third.text =~ marker, describe(third)

    assert Enum.count(third.reports, &match?({:prompt_sent, _}, &1)) == 1

    IO.puts(
      "codex writer wake: old matcher skipped owner; thread_active_writer before prompt; " <>
        "verified-owner cleanup resumed the same thread with history and one prompt"
    )
  end

  # Forward the failed handshake as a server does. Any prompt delivery is a
  # regression: the rejected attempt must not execute the user's work twice.
  defp await_resume_conflict(%{ref: ref} = conn) do
    receive do
      {:stdout, %{ref: ^ref}, data} ->
        Managoat.ACP.Peer.stdout(conn.peer, data)
        await_resume_conflict(conn)

      {:stderr, %{ref: ^ref}, _data} ->
        await_resume_conflict(conn)

      {:acp, ^ref, {:failed, reason}} ->
        reason

      {:acp, ^ref, {:prompt_sent, _}} ->
        flunk("competing resume sent a prompt while the original writer was still attached")

      {:acp, ^ref, {:done, _, _}} ->
        flunk("competing resume unexpectedly completed")

      {:acp, ^ref, _report} ->
        await_resume_conflict(conn)

      {:exit, %{ref: ^ref}, code} ->
        flunk("competing adapter exited #{code} before reporting a writer conflict")
    after
      @turn_timeout -> flunk("competing resume did not report a writer conflict")
    end
  end

  @doc """
  #2675 and #2691: the harness's permission mode is not a session option.
  Fountain refuses and hides the ids in `harness_mode_ids/0`; an adapter that
  renamed its mode option would put it back in front of users. Under a
  policy that allows everything Fountain sets no mode, so the adapter's
  default is the one the turn runs in.
  """
  def check_modes(sandbox, e) do
    conn = open(sandbox, "Reply with the single word ready.", config: %{})
    ExUnit.Callbacks.on_exit(fn -> close(conn) end)
    options = options(await_turn(conn))
    harness = SessionConfig.harness_mode_ids()

    for o <- options do
      IO.puts("#{e.runtime} option #{o["id"]} (#{o["category"]}): #{inspect(o["currentValue"])}")
    end

    # Every option the adapter files under "mode" is one Fountain refuses.
    for o <- options, o["category"] == "mode", do: assert(o["id"] in harness)

    present = for o <- options, o["id"] in harness, do: o["id"]
    assert Enum.sort(present) == Enum.sort(e.mode_options)
    refute Enum.any?(SessionConfig.offered(options), &(&1["id"] in harness))
    assert option(options, "mode")["currentValue"] == e.default_mode
  end

  @doc """
  #2708: under a policy that asks, the adapter runs in `e.asking_mode`. On
  codex that is the mode whose reviewer is the client. An adapter that
  renamed it would fall back to its default without an error, so the mode it
  reports is the check.
  """
  def check_asking_mode(sandbox, e) do
    conn = open(sandbox, "Reply with the single word ready.", policy: %{"default" => "ask"})
    ExUnit.Callbacks.on_exit(fn -> close(conn) end)
    turn = await_turn(conn)
    assert turn.stop == "end_turn"
    assert option(options(turn), "mode")["currentValue"] == e.asking_mode
  end

  @doc """
  What a client's answer does, on a request that reaches the client, under a
  policy that asks. `e.asks[tool]` is where a write sends one: claude asks
  for a file edit or a shell write in the workspace, codex for either one
  outside it (in the workspace codex asks nothing). `e.reject_stop[tool]` is
  how a rejected turn ends. The same connection then takes another turn, so
  a rejection that ends a turn does not end the conversation.
  """
  def check_answer(sandbox, e, tool, answer) do
    dir = Map.fetch!(e.asks, tool)
    path = "#{dir}/live-#{tool}-#{answer}-#{System.unique_integer([:positive])}"
    prompt = %{edit: &edit_prompt/1, shell: &write_prompt/1}[tool].(path)
    conn = open(sandbox, prompt, policy: %{"default" => "ask"})
    ExUnit.Callbacks.on_exit(fn -> close(conn) end)

    turn = await_turn(conn, fn _id, _tool, _options -> answer end)
    assert turn.asks != [], "no permission request; #{describe(turn)}"

    for {:permission_ask, _id, _tool, options} <- turn.asks do
      IO.puts(
        "#{e.runtime} #{tool} #{answer}: offered " <>
          Enum.map_join(options, ", ", &"#{&1["optionId"]} (#{&1["kind"]})") <>
          "; turn #{turn.stop}"
      )
    end

    case answer do
      :deny ->
        refute file?(sandbox, path), describe(turn)
        assert turn.stop == Map.fetch!(e.reject_stop, tool), describe(turn)

      :allow_once ->
        assert file?(sandbox, path), describe(turn)
        assert turn.stop == "end_turn", describe(turn)
    end

    prompt(conn, "Reply with the single word next.", %{})
    assert await_turn(conn).stop == "end_turn"
  end

  @doc """
  ADR 0014's 2026-10-15 addenda (#2670, #2708): not every tool call asks.
  Whether a shell write in `dir` does under `policy` is the adapter's
  measured answer, `asks`, and an unasked write happens. Under a policy that
  asks, codex's sandbox refuses a write outside the workspace and codex puts
  the escalation to the client. Under one that allows everything codex keeps
  its `agent` mode, whose automatic reviewer decides without the client.
  """
  def check_write(sandbox, dir, asks, policy \\ %{"default" => "ask"}) do
    path = "#{dir}/live-write-#{System.unique_integer([:positive])}"
    conn = open(sandbox, write_prompt(path), policy: policy)
    ExUnit.Callbacks.on_exit(fn -> close(conn) end)

    turn = await_turn(conn, fn _id, _tool, _options -> :deny end)
    asked = turn.asks != []
    assert asked == asks, describe(turn)
    assert file?(sandbox, path) != asked, describe(turn)
  end

  @doc "Whether a read-only command inside the workspace asks; unasked, it runs."
  def check_read_only(sandbox, e) do
    marker = "live-marker-#{System.unique_integer([:positive])}"
    {:ok, _, 0} = Managoat.Sandbox.exec(sandbox.handle, "touch", ["/home/sprite/#{marker}"])

    conn =
      open(
        sandbox,
        "Use your shell tool to run exactly this command and nothing else: " <>
          "ls -a. Then reply with its output.",
        policy: %{"default" => "ask"}
      )

    ExUnit.Callbacks.on_exit(fn -> close(conn) end)
    turn = await_turn(conn, fn _id, _tool, _options -> :deny end)
    assert turn.stop == "end_turn", describe(turn)
    asked = turn.asks != []
    assert asked == e.read_only_asks, describe(turn)
    # Unasked, it ran: its output is in the answer.
    assert asked or turn.text =~ marker, describe(turn)
  end

  # A streamable-HTTP MCP server in one file, for node, with no dependencies:
  # JSON responses only, no SSE stream (a GET is 405, which the transport
  # allows). Its one tool, `whoami`, answers with the word it was started
  # with. Every request it receives is appended to the log as one JSON line:
  # its JSON-RPC method and the two headers the check is about.
  @probe_server ~S"""
  const http = require("http");
  const fs = require("fs");
  const [port, log, word, ready] = process.argv.slice(2);
  const record = (req, method) =>
    fs.appendFileSync(log, JSON.stringify({
      method,
      authorization: req.headers["authorization"] || null,
      conversation_id: req.headers["x-managoat-conversation-id"] || null,
    }) + "\n");
  const handle = (msg) => {
    switch (msg.method) {
      case "initialize":
        return {result: {
          protocolVersion: (msg.params && msg.params.protocolVersion) || "2025-06-18",
          capabilities: {tools: {}},
          serverInfo: {name: "probe", version: "1.0.0"},
        }};
      case "ping":
        return {result: {}};
      case "tools/list":
        return {result: {tools: [{
          name: "whoami",
          description: "Says which conversation is calling. Takes no arguments.",
          inputSchema: {type: "object", properties: {}},
        }]}};
      case "tools/call":
        return {result: {content: [{type: "text", text: "The word is " + word + "."}]}};
      default:
        return {error: {code: -32601, message: "method not found"}};
    }
  };
  http.createServer((req, res) => {
    if (req.method !== "POST") { res.writeHead(405); return res.end(); }
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      let msg;
      try { msg = JSON.parse(body); } catch (_) { res.writeHead(400); return res.end(); }
      record(req, msg.method);
      if (msg.id === undefined) { res.writeHead(202); return res.end(); }
      res.writeHead(200, {"content-type": "application/json"});
      res.end(JSON.stringify(Object.assign({jsonrpc: "2.0", id: msg.id}, handle(msg))));
    });
  }).listen(Number(port), "127.0.0.1", () => fs.writeFileSync(ready, "ready"));
  """

  @doc """
  ADR 0086 (#1405): an HTTP MCP server marked `"auth": "conversation"` is
  called as the conversation. One turn calls the probe server's tool, and
  every request the server received carried `Authorization: Bearer <the
  callback key>` and `X-Managoat-Conversation-Id: <the conversation id>`.

  The `session/new` list comes from `McpServers.for_session/2`, as
  `TurnLaunch` builds it, out of an agent document the changeset accepts and
  `substitute_agent/3` resolves. The server runs in the sandbox, on
  loopback, so the adapter reaches it with no network rule. The key and the
  id are made up: the check is that the runtime sends the headers it was
  given, not that the key is valid, which a server checks against
  `GET /api/auth/me`.
  """
  def check_conversation_auth(sandbox, e) do
    n = System.unique_integer([:positive])
    port = 20_000 + rem(n, 20_000)
    [script, log, ready, out] = for ext <- ~w(js log ready out), do: "/tmp/live-mcp-#{n}.#{ext}"
    word = "kumquat#{n}"
    conversation = %{id: Ecto.UUID.generate(), token: "ftn_live_#{Ecto.UUID.generate()}"}

    :ok = Managoat.Sandbox.write_file(sandbox.handle, script, @probe_server)

    {:ok, _, 0} =
      Managoat.Sandbox.exec(sandbox.handle, "bash", [
        "-lc",
        "nohup node #{script} #{port} #{log} #{word} #{ready} >#{out} 2>&1 </dev/null & " <>
          "for _ in $(seq 1 100); do test -e #{ready} && exit 0; sleep 0.1; done; " <>
          "cat #{out}; exit 1"
      ])

    ExUnit.Callbacks.on_exit(fn ->
      Managoat.Sandbox.exec(sandbox.handle, "pkill", ["-f", script])
    end)

    servers = %{
      "probe" => %{
        "type" => "http",
        "url" => "http://127.0.0.1:#{port}/mcp",
        "auth" => "conversation"
      }
    }

    changeset =
      Agent.changeset(%Agent{}, %{
        name: "live-probe",
        runtime: e.runtime,
        model: cheap_model(e.runtime),
        mcp_servers: servers
      })

    assert changeset.errors[:mcp_servers] == nil, inspect(changeset.errors)
    agent = Ecto.Changeset.apply_changes(changeset)
    {:ok, resolved} = McpServers.substitute_agent(agent, nil, %{})

    mcp_servers =
      McpServers.for_session(agent, resolved: resolved.mcp_servers, conversation: conversation)

    conn =
      open(
        sandbox,
        "Call the whoami tool of the probe MCP server, with no arguments. " <>
          "Use no other tool. Then reply with the word it gives you.",
        policy: %{},
        model: cheap_model(e.runtime),
        mcp_servers: mcp_servers
      )

    ExUnit.Callbacks.on_exit(fn -> close(conn) end)
    turn = await_turn(conn, fn _id, _tool, _options -> :allow_once end)
    assert turn.stop == "end_turn", describe(turn)

    {:ok, seen, 0} =
      Managoat.Sandbox.exec(sandbox.handle, "bash", ["-c", "cat #{log} 2>/dev/null || true"])

    requests = for line <- String.split(seen, "\n", trim: true), do: Jason.decode!(line)
    methods = Enum.map(requests, & &1["method"])
    IO.puts("#{e.runtime} probe MCP server saw: #{Enum.join(methods, ", ")}")

    assert "tools/call" in methods, "whoami was not called; #{describe(turn)}"
    assert turn.text =~ word, describe(turn)

    for request <- requests do
      assert request["authorization"] == "Bearer " <> conversation.token,
             "#{request["method"]} came without the conversation's bearer"

      assert request["conversation_id"] == conversation.id,
             "#{request["method"]} came without the conversation id"
    end
  end

  # ── The image's CLI serves real turns ────────────────────────────────────
  #
  # `e.image` names what `@image_reuse` records for the runtime: the marker
  # file in the install directory, the bundled CLI's package prefix there, and
  # what the image CLI's `--version` prints.

  @doc """
  The install selected the image's CLI and an authenticated turn ran on it.
  The install recorded an executable outside its own tree that runs and
  reports the expected version, and installed no bundled copy. While the
  turn's connection is open, the recorded executable is running (as the
  program, or as the script node runs) and nothing under the bundled prefix
  is.
  """
  def check_image_reuse(sandbox, e) do
    report = image_install!(sandbox, e)

    conn = open(sandbox, "Reply with the single word ready. Do not use tools.", config: %{})
    ExUnit.Callbacks.on_exit(fn -> close(conn) end)
    turn = await_turn(conn)
    assert turn.stop == "end_turn", describe(turn)

    procs = processes!(sandbox)
    image = LiveAdapterSandbox.running(procs, report.executable)
    bundled = LiveAdapterSandbox.running_under(procs, Path.join(report.dir, e.image.bundled))

    assert image != [],
           "nothing runs #{report.executable} during the turn; #{describe(turn)}\n" <>
             "processes: #{inspect(procs, limit: :infinity)}"

    assert bundled == [], "the bundled CLI is running: #{inspect(bundled)}"

    IO.puts(
      "#{e.runtime}: #{report.version} at #{report.executable} " <>
        "served an authenticated turn (pids #{inspect(Enum.map(image, & &1.pid))})"
    )
  end

  @doc """
  A session resumed in a new adapter process keeps its history, on the image
  CLI. One turn asks the model to remember a word, then that connection is
  closed and every process that served it has exited (or is killed and the
  kill reported). A new adapter process resumes the session with
  `session/resume`, and the model answers with the word. The processes that
  serve the resumed turn are new and run the recorded executable.
  """
  def check_fresh_resume(sandbox, e) do
    s = remembered_session!(sandbox, e)
    before = pids(processes!(sandbox))

    resumed =
      open(sandbox, "Reply with only the exact word I asked you to remember. Do not use tools.",
        mode: :continue,
        session_id: s.session,
        config: %{}
      )

    ExUnit.Callbacks.on_exit(fn -> close(resumed) end)
    turn = await_turn(resumed)
    assert turn.stop == "end_turn", describe(turn)
    assert {:handshake_ms, _, "session/resume"} = find(turn, :handshake_ms)
    assert turn.text =~ s.marker, describe(turn)

    serving = new_image_processes(sandbox, s.executable, before)
    assert serving != [], "the resumed turn did not run on #{s.executable}"
    assert MapSet.disjoint?(pids(serving), s.pids)

    IO.puts(
      "#{e.runtime} on Sprites: resumed #{s.session} in a new process " <>
        "(pids #{inspect(s.pids |> MapSet.to_list())} -> " <>
        "#{inspect(Enum.map(serving, & &1.pid))}), history kept"
    )
  end

  @doc """
  The same, through `session/load`, which the peer does not choose when the
  adapter offers `session/resume`. It is spoken directly: `initialize`,
  `authenticate` with the adapter's api-key method when it offers one, then
  `session/load` on a fresh adapter process. The history it replays must
  include the remembered word.
  """
  def check_load(sandbox, e, quiet_ms \\ 1_000) do
    s = remembered_session!(sandbox, e)
    before = pids(processes!(sandbox))

    %{command: command, cwd: cwd} = spawn_adapter(sandbox, [])
    ExUnit.Callbacks.on_exit(fn -> Managoat.Sandbox.stop_command(command) end)
    acc = %{buffer: "", updates: [], stderr: ""}

    rpc(
      command,
      1,
      "initialize",
      Protocol.initialize_params(Protocol.default_client_capabilities())
    )

    {init, acc} = await_rpc(command, 1, acc)
    assert get_in(init, ["agentCapabilities", "loadSession"]) == true, inspect(init)

    acc =
      case Enum.find(init["authMethods"] || [], &match?(%{"_meta" => %{"api-key" => _}}, &1)) do
        %{"id" => id} ->
          rpc(command, 2, "authenticate", %{methodId: id})
          {_, acc} = await_rpc(command, 2, acc)
          acc

        nil ->
          acc
      end

    rpc(command, 3, "session/load", %{sessionId: s.session, cwd: cwd, mcpServers: []})
    {_loaded, acc} = await_rpc(command, 3, acc)
    # ACP replays before answering; an adapter that answers first (gemini,
    # #657) would still be replaying, so the stream is read until quiet.
    acc = drain(command, acc, quiet_ms)
    replay = Enum.map_join(Enum.reverse(acc.updates), &update_text/1)

    assert replay =~ s.marker,
           "session/load replayed no remembered word: #{inspect(String.slice(replay, 0, 2000))}\n" <>
             "stderr:\n#{String.slice(acc.stderr, -4000, 4000)}"

    serving = new_image_processes(sandbox, s.executable, before)
    assert serving != [], "the loaded session did not run on #{s.executable}"
    assert MapSet.disjoint?(pids(serving), s.pids)

    IO.puts(
      "#{e.runtime} on Sprites: loaded #{s.session} in a new process " <>
        "(pids #{inspect(Enum.map(serving, & &1.pid))}), #{length(acc.updates)} updates replayed"
    )
  end

  defp image_install!(sandbox, e) do
    {bin, _args} = Fountain.RuntimeDispatch.command(e.runtime, nil)
    script = LiveAdapterSandbox.install_report(bin, e.image.marker, e.image.bundled)
    {:ok, out, 0} = Managoat.Sandbox.exec(sandbox.handle, "bash", ["-c", script])
    report = LiveAdapterSandbox.parse_install_report(out)

    assert is_binary(report.dir), "no PATH link for #{bin}: #{inspect(out)}"

    assert is_binary(report.executable),
           "#{report.dir} has no #{e.image.marker}: the install did not select the image " <>
             "CLI (#{inspect(report)})"

    assert report.executable_ok?, "#{report.executable} is not executable"
    refute String.starts_with?(report.executable, report.dir <> "/"), inspect(report)
    assert report.version =~ e.image.version, inspect(report)
    assert report.bundled == [], "the bundled CLI was installed too: #{inspect(report.bundled)}"
    report
  end

  # A session whose first turn asked the model to remember a word, its
  # connection closed and every process that served it gone, so whatever
  # opens it next is a new process.
  defp remembered_session!(sandbox, e) do
    report = image_install!(sandbox, e)
    marker = "kumquat#{System.unique_integer([:positive])}"
    before = pids(processes!(sandbox))

    conn =
      open(
        sandbox,
        "Remember this exact word: #{marker}. Reply with the single word ready. " <>
          "Do not use tools.",
        config: %{}
      )

    first = await_turn(conn)
    assert first.stop == "end_turn", describe(first)
    session = session_id(first) || flunk("no session id: #{describe(first)}")

    fresh = Enum.reject(processes!(sandbox), &(&1.pid in before))
    image = LiveAdapterSandbox.running(fresh, report.executable)
    adapter = LiveAdapterSandbox.running_under(fresh, report.dir <> "/")
    assert image != [], "the first turn did not run on #{report.executable}"

    close(conn)
    served = pids(image ++ adapter)
    await_exit!(sandbox, served, e.runtime)
    %{session: session, marker: marker, pids: served, executable: report.executable}
  end

  defp new_image_processes(sandbox, executable, before) do
    sandbox
    |> processes!()
    |> Enum.reject(&(&1.pid in before))
    |> LiveAdapterSandbox.running(executable)
  end

  defp processes!(sandbox) do
    {:ok, out, 0} =
      Managoat.Sandbox.exec(sandbox.handle, "bash", ["-c", LiveAdapterSandbox.process_listing()])

    LiveAdapterSandbox.parse_processes(out)
  end

  defp pids(processes), do: MapSet.new(processes, & &1.pid)

  # A closed connection's adapter should exit with its stdin; one that has not
  # after 10 s is killed, and the kill is reported rather than hidden, so the
  # next open is a new process either way.
  defp await_exit!(sandbox, served, runtime, tries \\ 20) do
    alive = MapSet.intersection(served, pids(processes!(sandbox)))

    cond do
      MapSet.size(alive) == 0 ->
        :ok

      tries > 0 ->
        Process.sleep(500)
        await_exit!(sandbox, served, runtime, tries - 1)

      true ->
        IO.puts(
          "#{runtime}: #{inspect(MapSet.to_list(alive))} outlived their connection; killing"
        )

        list = Enum.map_join(alive, " ", &Integer.to_string/1)
        Managoat.Sandbox.exec(sandbox.handle, "bash", ["-c", "kill -9 #{list} 2>/dev/null; true"])
        Process.sleep(500)
        assert MapSet.disjoint?(served, pids(processes!(sandbox)))
    end
  end

  defp rpc(command, id, method, params) do
    :ok =
      Managoat.Sandbox.write_stdin(
        command,
        IO.iodata_to_binary(Protocol.request(id, method, params))
      )
  end

  # The response to request `id`, collecting `session/update`s on the way and
  # refusing any request from the agent as the peer does.
  defp await_rpc(%{ref: ref} = command, id, acc) do
    receive do
      {:stdout, %{ref: ^ref}, data} ->
        {messages, buffer} = Protocol.feed(acc.buffer, data)
        acc = %{acc | buffer: buffer}

        Enum.reduce_while(messages, {:cont, acc}, fn message, {:cont, acc} ->
          case message do
            {:response, ^id, result} ->
              {:halt, {:done, result, acc}}

            {:error_response, ^id, error} ->
              flunk("request #{id} refused: #{inspect(error)}\nstderr:\n#{acc.stderr}")

            {:request, rid, _method, _params} ->
              :ok =
                Managoat.Sandbox.write_stdin(
                  command,
                  IO.iodata_to_binary(
                    Protocol.error(rid, Protocol.method_not_found(), "not supported")
                  )
                )

              {:cont, {:cont, acc}}

            {:notification, "session/update", params} ->
              {:cont, {:cont, %{acc | updates: [params | acc.updates]}}}

            _other ->
              {:cont, {:cont, acc}}
          end
        end)
        |> case do
          {:done, result, acc} -> {result, acc}
          {:cont, acc} -> await_rpc(command, id, acc)
        end

      {:stderr, %{ref: ^ref}, data} ->
        await_rpc(command, id, %{acc | stderr: acc.stderr <> data})

      {:exit, %{ref: ^ref}, code} ->
        flunk(
          "adapter exited #{code} awaiting request #{id}; stderr:\n#{String.slice(acc.stderr, -4000, 4000)}"
        )
    after
      @turn_timeout -> flunk("no response to request #{id} in #{@turn_timeout} ms")
    end
  end

  defp drain(%{ref: ref} = command, acc, quiet_ms) do
    receive do
      {:stdout, %{ref: ^ref}, data} ->
        {messages, buffer} = Protocol.feed(acc.buffer, data)

        updates =
          for {:notification, "session/update", params} <- messages, reduce: acc.updates do
            updates -> [params | updates]
          end

        drain(command, %{acc | buffer: buffer, updates: updates}, quiet_ms)

      {:stderr, %{ref: ^ref}, data} ->
        drain(command, %{acc | stderr: acc.stderr <> data}, quiet_ms)
    after
      quiet_ms -> acc
    end
  end

  # The text of a replayed message chunk, the user's or the agent's.
  defp update_text(%{"update" => %{"sessionUpdate" => kind, "content" => %{"text" => text}}})
       when kind in ["user_message_chunk", "agent_message_chunk"] and is_binary(text),
       do: text

  defp update_text(_update), do: ""

  defp edit_prompt(path) do
    "Create the file #{path} containing the single word hello. Use your file editing " <>
      "tool, not the shell, and no other tool. If the edit is refused, reply with the " <>
      "word refused."
  end

  defp write_prompt(path) do
    "Use your shell tool to run exactly this command and nothing else: touch #{path}. " <>
      "Do not use any other tool. If a sandbox blocks it, request approval to run it " <>
      "outside the sandbox. If that is refused, reply with the word refused."
  end

  defp find(turn, tag), do: Enum.find(turn.reports, &(is_tuple(&1) and elem(&1, 0) == tag))
end

defmodule Fountain.LiveAdapter.Case do
  @moduledoc false
  use ExUnit.CaseTemplate

  # The using module names its runtime (`--only runtime:codex` runs one) and
  # defines `expect/0`: the credential env vars it needs and what its pinned
  # adapter was measured to do. Each test is one check in Fountain.LiveAdapter.
  # `checks: :conversation_auth` runs that check alone, for a runtime whose
  # session options and permission behaviour the suite does not pin.
  using opts do
    all? = Keyword.get(opts, :checks, :all) == :all

    quote do
      import Fountain.LiveAdapter

      @moduletag :live_adapter
      @moduletag runtime: unquote(Keyword.fetch!(opts, :runtime))
      @moduletag timeout: 900_000

      setup_all do
        mode = Fountain.LiveAdapterSandbox.mode()
        configure!(mode)
        %{sandbox: provision!(mode, expect().runtime, expect().credentials)}
      end

      test(
        ~s(an "auth": "conversation" MCP server is called with the conversation's headers),
        %{sandbox: s},
        do: check_conversation_auth(s, expect())
      )

      if unquote(all?) do
        test(
          "the agent's session option is set once and holds on the next turn",
          %{sandbox: s},
          do: check_held(s, expect())
        )

        test("a resumed session does not carry the last turn's option", %{sandbox: s},
          do: check_resume(s, expect())
        )

        test("permission modes are named by harness_mode_ids and not offered", %{sandbox: s},
          do: check_modes(s, expect())
        )

        test("a policy that asks runs the adapter in its asking mode", %{sandbox: s},
          do: check_asking_mode(s, expect())
        )

        test("a rejected shell request does not run the command", %{sandbox: s},
          do: check_answer(s, expect(), :shell, :deny)
        )

        test("an approved shell request runs the command", %{sandbox: s},
          do: check_answer(s, expect(), :shell, :allow_once)
        )

        test("a rejected file edit request does not write the file", %{sandbox: s},
          do: check_answer(s, expect(), :edit, :deny)
        )

        test("a write inside the workspace", %{sandbox: s},
          do: check_write(s, "/home/sprite", expect().workspace_write_asks)
        )

        test("a write outside the workspace", %{sandbox: s},
          do: check_write(s, "/var/tmp", expect().outside_write_asks)
        )

        test("an allowing policy: a write outside the workspace", %{sandbox: s},
          do: check_write(s, "/var/tmp", expect().allowing_outside_write_asks, %{})
        )

        test("a read-only command inside the workspace", %{sandbox: s},
          do: check_read_only(s, expect())
        )
      end

      # Every provider runs the image's CLI: the adapter bundle carries none
      # (ADR 0092).
      if unquote(all?) do
        test("an authenticated turn runs on the image's CLI", %{sandbox: s},
          do: check_image_reuse(s, expect())
        )
      end

      # Decided when the suite compiles, which is each time it runs: on E2B
      # this test does not exist.
      if unquote(all?) and Fountain.LiveAdapterSandbox.mode() == :sprites do
        test(
          "on Sprites, a session resumed in a new adapter process keeps its history",
          %{sandbox: s},
          do: check_fresh_resume(s, expect())
        )
      end
    end
  end
end

defmodule Fountain.LiveAdapter.ClaudeTest do
  # claude-agent-acp, the version managoat_runtimes pins.
  use Fountain.LiveAdapter.Case, async: true, runtime: "claude"

  def expect,
    do: %{
      runtime: "claude",
      credentials: [anthropic_api_key: "ANTHROPIC_API_KEY"],
      # `@image_reuse`'s claude row.
      image: %{
        marker: ".claude-executable",
        bundled: "node_modules/@anthropic-ai/claude-agent-sdk-",
        version: ~r/\A\d+\.\d+\.\d+ \(Claude Code\)\z/
      },
      effort_option: "effort",
      mode_options: ["mode"],
      default_mode: "default",
      asking_mode: "default",
      asks: %{shell: "/home/sprite", edit: "/home/sprite"},
      reject_stop: %{shell: "end_turn", edit: "end_turn"},
      workspace_write_asks: true,
      outside_write_asks: true,
      allowing_outside_write_asks: false,
      read_only_asks: false
    }
end

defmodule Fountain.LiveAdapter.CodexTest do
  # codex-acp, the version `Managoat.Runtimes.ACP` pins.
  use Fountain.LiveAdapter.Case, async: true, runtime: "codex"

  # Sprites parks on its own (`suspend/1` is a no-op there), so the
  # suspend-and-wake this reproduces is E2B's.
  if Fountain.LiveAdapterSandbox.mode() == :sprites do
    @tag skip: "E2B suspend and wake only"
  end

  test "a detached writer is recovered after E2B suspend and wake", %{sandbox: sandbox} do
    check_writer_wake(sandbox)
  end

  if Fountain.LiveAdapterSandbox.mode() == :sprites do
    test "on Sprites, a session loaded in a new adapter process replays its history",
         %{sandbox: sandbox} do
      check_load(sandbox, expect())
    end
  end

  def expect,
    do: %{
      runtime: "codex",
      credentials: [openai_api_key: "OPENAI_API_KEY"],
      # `@image_reuse`'s codex row.
      image: %{
        marker: ".codex-executable",
        bundled: "node_modules/@openai/codex-",
        version: ~r/\Acodex-cli \d+\.\d+\.\d+\z/
      },
      effort_option: "reasoning_effort",
      mode_options: ["mode", "collaboration_mode"],
      default_mode: "agent",
      asking_mode: "workspace-write",
      asks: %{shell: "/var/tmp", edit: "/var/tmp"},
      reject_stop: %{shell: "cancelled", edit: "cancelled"},
      workspace_write_asks: false,
      outside_write_asks: true,
      allowing_outside_write_asks: false,
      read_only_asks: false
    }
end

defmodule Fountain.LiveAdapter.GeminiTest do
  # gemini-cli's own ACP mode, the version `Managoat.Runtimes.Gemini` pins or
  # the newer one the image ships. Only the `"auth": "conversation"` check:
  # the suite does not pin gemini's session options or permission answers.
  use Fountain.LiveAdapter.Case, async: true, runtime: "gemini", checks: :conversation_auth

  def expect,
    do: %{runtime: "gemini", credentials: [gemini_api_key: "GEMINI_API_KEY"]}
end
