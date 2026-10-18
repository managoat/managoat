defmodule Fountain.Conversations.ConversationServerRedactionTest do
  # #315: ConversationServer state holds plaintext tenant secrets, the raw
  # DEK, decrypted BYO inference credentials, the callback API key and the
  # platform Sprites token. Three leak vectors, each covered here:
  #
  #   1. A FunctionClauseError at a callback head embeds the full state in
  #      the exception message — format_status/1 cannot redact an exception
  #      message, so unknown calls/casts must not crash at the head.
  #   2. A crash inside a callback body produces a crash report whose state
  #      field feeds structured handlers (Sentry.LoggerHandler) —
  #      format_status/1 redacts it at the gen_server level.
  #   3. :sys.get_status (ops tooling, remote console) renders state through
  #      the same callback.
  #
  # #1690 covered more fields that held plaintext and were not scrubbed: the
  # brokered values, the proxy session, the env credentials, the resolved MCP
  # document, the sandbox command's adapter-owned client, and the turn's prompt
  # and reply. The field guard at the bottom of
  # this file is the part that stops the next one arriving unnoticed.
  use Fountain.ConversationServerCase

  import ExUnit.CaptureLog

  alias Fountain.Conversations.Redaction
  alias Fountain.Conversations.Turn

  @secret_env_value "sprite-env-secret-value-315"
  @dek_value "raw-tenant-dek-bytes-315"
  @inference_value "sk-ant-byo-credential-315"
  @callback_value "fnt_callback_key_315"
  @sprites_token "sprites-platform-token-315"
  @retry_detail "runtime-error-with-secret-session-detail-1913"
  @brokered_value "ghp-brokered-github-token-1690"
  @broker_token "broker-session-token-1690"
  @env_credential_value "sk-ant-env-credential-1690"
  @mcp_header_value "mcp-resolved-header-token-1690"
  @mcp_env_value "mcp-resolved-env-token-1690"
  @command_sprites_token "sprites-command-token-1690"
  @turn_prompt "turn-prompt-tenant-text-1690"
  @turn_reply "turn-reply-tenant-text-1690"

  defp start_server_with_secrets do
    stub_happy_sprite()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {pid, ref, :alive} = start_server(conv)

    # Provisioning under stubs leaves most secret fields empty, so plant
    # realistic values through the server itself — whatever the state holds
    # at crash time is exactly what must come out redacted.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | handle: %Managoat.Sandbox.Handle{
            provider: :sprites,
            name: "test-sprite",
            private: %Sprites.Sprite{
              name: "test-sprite",
              client: %Sprites.Client{token: @sprites_token}
            }
          },
          sprite_env: [{"MY_SECRET", @secret_env_value}, {"OTHER", "other-value-315"}],
          brokered: %{"GITHUB_TOKEN" => @brokered_value},
          broker: %{
            vault: "vault-1690",
            token: @broker_token,
            expires_at: DateTime.utc_now()
          },
          env_credentials: %{"ANTHROPIC_API_KEY" => @env_credential_value},
          resolved_mcp_servers: %{
            "linear" => %{
              "url" => "https://mcp.linear.app/sse",
              "headers" => %{"Authorization" => "Bearer " <> @mcp_header_value},
              "env" => %{"LINEAR_TOKEN" => @mcp_env_value}
            }
          },
          current_command: %Managoat.Sandbox.Command{
            provider: :sprites,
            ref: make_ref(),
            private: %Sprites.Sprite{
              name: "test-sprite",
              client: %Sprites.Client{token: @command_sprites_token}
            }
          },
          current_turn: %Turn{
            id: Ecto.UUID.generate(),
            turn_number: 3,
            status: "running",
            prompt: @turn_prompt,
            reply_text: @turn_reply
          },
          tenant_key: @dek_value,
          inference_credentials: %{"anthropic" => @inference_value},
          callback_token: @callback_value,
          turn_session_retry: @retry_detail
      }
    end)

    {pid, ref}
  end

  defp refute_secrets(rendered) do
    refute rendered =~ @secret_env_value
    refute rendered =~ "other-value-315"
    refute rendered =~ @dek_value
    refute rendered =~ @inference_value
    refute rendered =~ @callback_value
    refute rendered =~ @sprites_token
    refute rendered =~ @retry_detail
    # #1690.
    refute rendered =~ @brokered_value
    refute rendered =~ @broker_token
    refute rendered =~ @env_credential_value
    refute rendered =~ @mcp_header_value
    refute rendered =~ @mcp_env_value
    refute rendered =~ @command_sprites_token
    refute rendered =~ @turn_prompt
    refute rendered =~ @turn_reply
  end

  test "unknown calls and casts do not crash at the callback head" do
    {pid, _ref} = start_server_with_secrets()

    log =
      capture_log(fn ->
        assert {:error, :unknown_call} = GenServer.call(pid, :no_such_call)
        GenServer.cast(pid, :no_such_cast)
        # Synchronize so the cast has been handled before asserting.
        _ = :sys.get_state(pid)
      end)

    assert Process.alive?(pid)
    assert log =~ "unexpected call"
    assert log =~ "unexpected cast"
    refute_secrets(log)
  end

  test "a crash inside a callback body does not leak secrets into the crash report" do
    {pid, ref} = start_server_with_secrets()

    # Corrupt a lifecycle field so the next :lifecycle_check raises deep in
    # the callback body — the unhandled-crash shape the issue describes.
    # `current_turn` has to go with it: a turn in flight makes the check
    # "busy", and the busy branch never reaches the comparison that raises.
    # Remove the synthetic journal too so the bounded gate does not run first.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | sandbox_started_at: DateTime.utc_now(),
          last_activity_at: :corrupt,
          current_turn: nil
      }
    end)

    log =
      capture_log(fn ->
        send(pid, :lifecycle_check)
        assert_stopped(ref)
      end)

    assert log =~ "terminating"
    refute_secrets(log)
  end

  test "format_status redacts state for structured crash reports and :sys.get_status" do
    {pid, _ref} = start_server_with_secrets()

    rendered = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)

    refute_secrets(rendered)

    # Key names survive so reports stay debuggable.
    assert rendered =~ "MY_SECRET"
    assert rendered =~ "[REDACTED]"

    # Including the ones #1690 added: which keys are brokered and which MCP
    # servers were resolved is the whole debugging signal of those fields.
    assert rendered =~ "GITHUB_TOKEN"
    assert rendered =~ "ANTHROPIC_API_KEY"
    assert rendered =~ "linear"
    assert rendered =~ "Authorization"
    assert rendered =~ "LINEAR_TOKEN"

    # The turn still identifies itself.
    assert rendered =~ "turn_number: 3"
    assert rendered =~ ~s(status: "running")
  end

  # ── The field guard (#1690) ────────────────────────────────────────────────
  #
  # Two leaky fields arrived with the broker (#1136/#1150) and a third with
  # #1511, each in a change that had no reason to think about crash reports.
  # A name-pattern guard (`cred|token|secret|broker`) would have caught the
  # first two and missed `resolved_mcp_servers`, so this guard works the other
  # way round: every state field is sentinel-filled unless it is named below as
  # legitimately plaintext, and the sentinel must not survive
  # `Redaction.server_state/1`.
  #
  # A new state field is therefore a failing test until its author either
  # redacts it or adds it here with a reason. That is the intended cost.

  @sentinel "SENTINEL-1690-MUST-NOT-ESCAPE"

  # Fields that are legitimately plaintext in a crash report. Each one is a
  # claim that it cannot hold a credential.
  @plaintext_fields [
    # Identifiers, configuration and bookkeeping. No tenant data at all.
    :conversation_id,
    :sandbox_id,
    :user_id,
    :runtime_module,
    :runtime_session_id,
    :callback_api_key_id,
    :sandbox_started_at,
    :last_activity_at,
    :output_bytes,
    :output_capped,
    :broker_network,
    :inference_source,
    :inference_model,
    # A directory path, `/home/sprite/.managoat/c/<id>` or a legacy one.
    :config_home,
    # Names and provenance, never values: the tenant's own brokered key names, the row ids
    # the secrets came from, and the bindings — key, host, auth type and
    # `{{KEY}}` templates, which is all a binding holds (ADR 0019 gate 1b).
    :tenant_keys,
    :secret_sources,
    :broker_bindings,
    # Connections the agent names (ADR 0085): ids, reserved key names, hosts,
    # and when each token expires. The tokens are in `brokered`.
    :connections,
    :connection_expiries,
    :connection_timer,
    # Process plumbing: pids, refs, timers and spans.
    :current_command_ref,
    :acp_peer,
    :acp_peer_mon,
    # Env pairs that select a model (`ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5`):
    # model ids, never a credential.
    :acp_model_env,
    # Tool names and verdicts (`%{"execute" => "ask"}`), never a value.
    :acp_permission_policy,
    # An `api_keys` row id, as `callback_api_key_id` is: never the key.
    :acp_callback_key_id,
    # `{api_keys row id, turn id}` (#2835): never the key.
    :handover_callback_key,
    :permission_timer,
    :autonomous_quiet,
    :current_turn_span,
    :stream_tracer,
    # Byte counts per stream, taken from rows already written. No content.
    # Parked caller-tool arguments (#1202) and the ACP lines already persisted
    # for the in-flight turn. Tenant content rather than credential material,
    # and what is in `replay_dedup` was read back from `log_events`, so it has
    # been through `Redaction.redact/2`.
    :replay_dedup
  ]

  # Fields the redaction covers. The value is a sentinel wearing the shape the
  # field really has, because `server_state/1` reads some of those shapes.
  defp sentinel_shapes do
    %{
      handle: %Managoat.Sandbox.Handle{
        provider: :sprites,
        name: "sentinel-sprite",
        private: %Sprites.Sprite{
          name: "sentinel-sprite",
          client: %Sprites.Client{token: @sentinel}
        }
      },
      sprite_env: [{"SENTINEL_KEY", @sentinel}],
      brokered: %{"SENTINEL_KEY" => @sentinel},
      broker: %{vault: @sentinel, token: @sentinel, expires_at: @sentinel},
      env_credentials: %{"SENTINEL_KEY" => @sentinel},
      resolved_mcp_servers: %{
        "sentinel" => %{
          "headers" => %{"Authorization" => @sentinel},
          "env" => %{"SENTINEL_KEY" => @sentinel},
          "args" => [@sentinel]
        }
      },
      current_command: %Managoat.Sandbox.Command{
        provider: :sprites,
        ref: make_ref(),
        private: %Sprites.Sprite{
          name: "sentinel-sprite",
          client: %Sprites.Client{token: @sentinel}
        }
      },
      current_turn: %Turn{
        id: Ecto.UUID.generate(),
        turn_number: 1,
        status: "running",
        prompt: @sentinel,
        reply_text: @sentinel,
        pending_permission: %{"tool" => @sentinel}
      },
      output_carry: %{ctx: %{}, held: %{raw: %{"stdout" => @sentinel}, lines: nil}},
      tenant_key: @sentinel,
      inference_credentials: %{"sentinel" => @sentinel},
      callback_token: @sentinel,
      # `{api_keys row id, plaintext}` (#2934): the id may show, the key not.
      conversation_key: {Ecto.UUID.generate(), @sentinel},
      turn_session_retry: @sentinel,
      turn_provider_failure: %{system_error?: true, detail: @sentinel},
      # Timing is plaintext; the relaunch context (#2402) holds the prompt.
      turn_metrics: %{
        started_mono: 1,
        runtime: "claude",
        provider: "sprites",
        first_output?: false,
        launch: %{
          conv: %{title: @sentinel},
          agent: %{system_prompt: @sentinel},
          prompt: @sentinel,
          images: [%{media_type: "image/png", data: @sentinel}],
          relaunched?: false
        }
      }
    }
  end

  # `structs: false` renders a struct as a plain map, so a field protected only
  # by its own `@derive {Inspect, …}` is still seen here. That is deliberately
  # stricter than the crash report: `@derive` on someone else's struct is not a
  # guarantee this server gets to make, and a consumer that walks the state map
  # (a Sentry serializer, `:sys.get_status` tooling) never consults it.
  defp render(state),
    do: inspect(state, structs: false, limit: :infinity, printable_limit: :infinity)

  test "every ConversationServer state field is classified" do
    {pid, _ref} = start_server_with_secrets()

    fields = pid |> :sys.get_state() |> Map.keys() |> Enum.sort()
    classified = Enum.sort(@plaintext_fields ++ Map.keys(sentinel_shapes()))

    assert fields -- classified == [],
           """
           New ConversationServer state field(s): #{inspect(fields -- classified)}.

           Either redact them in Fountain.Conversations.Redaction.server_state/1
           and give each a sentinel shape here, or add them to
           @plaintext_fields with a comment saying why their value is safe to
           print in a crash report.
           """

    assert classified -- fields == [],
           "stale entries for state fields that no longer exist: " <>
             inspect(classified -- fields)
  end

  test "no secret-bearing state field survives server_state/1 with its value" do
    {pid, _ref} = start_server_with_secrets()
    state = :sys.get_state(pid)
    shapes = sentinel_shapes()

    leaking =
      for field <- Map.keys(state), field not in @plaintext_fields do
        value = Map.get(shapes, field, @sentinel)

        rendered =
          try do
            state |> Map.put(field, value) |> Redaction.server_state() |> render()
          rescue
            error ->
              flunk("""
              server_state/1 raised on #{inspect(field)}: #{Exception.message(error)}

              A raise here is itself a leak — OTP reports the unredacted state
              when format_status/1 fails. Give the field a sentinel shape in
              sentinel_shapes/0 that matches what it really holds.
              """)
          end

        if rendered =~ @sentinel, do: field
      end
      |> Enum.reject(&is_nil/1)

    assert leaking == [],
           """
           These state fields keep their value through
           Fountain.Conversations.Redaction.server_state/1: #{inspect(leaking)}.

           A crash in any callback prints them (#315, #1690). Scrub them there,
           keeping key names so reports stay debuggable.
           """
  end
end
