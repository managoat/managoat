defmodule Fountain.Conversations.TurnMachineTest do
  @moduledoc """
  The turn state machine (#1374), driven without a server, a sandbox or a
  peer: every peer payload through `handle/3`, the effects it hands back,
  the row and stage writes it makes itself, and the bookkeeping around a
  turn's start and end.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.TurnMachine

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    conv = insert_conversation(user_id: user.id, agent: agent)
    row = insert_turn(conv, status: "running", started_at: DateTime.utc_now())

    machine = %TurnMachine{
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      row: row,
      metrics: TurnMachine.start_metrics("claude", :e2b, System.monotonic_time(:millisecond))
    }

    {:ok, user: user, agent: agent, conv: conv, row: row, machine: machine}
  end

  defp idle(machine), do: %{machine | row: nil, metrics: nil}

  defp stages(conv_id, stage) do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
    |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
  end

  defp attach_telemetry(events) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      events,
      fn event, measurements, metadata, _ ->
        send(test, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp codex_line(codex) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "s",
        "update" => %{"sessionUpdate" => "session_info_update", "_meta" => %{"codex" => codex}}
      }
    })
  end

  defp feed(machine, lines) do
    Enum.reduce(lines, machine, fn line, machine ->
      assert {machine, [{:persist_lines, "acp", ^line}]} =
               TurnMachine.handle(machine, {:lines, "acp", line})

      machine
    end)
  end

  # codex-acp's lines for a model call that failed outright (#2545), the same
  # on 1.10.0 and 2.2.2:
  # five retried stream errors, the thread in systemError, then the error as
  # reply text. The prompt is still answered `end_turn`.
  @codex_out_of_credits (for attempt <- 1..5 do
                           Jason.encode!(%{
                             "jsonrpc" => "2.0",
                             "method" => "session/update",
                             "params" => %{
                               "sessionId" => "s",
                               "update" => %{
                                 "sessionUpdate" => "session_info_update",
                                 "_meta" => %{
                                   "codex" => %{
                                     "error" => %{
                                       "message" => "Reconnecting... #{attempt}/5",
                                       "additionalDetails" =>
                                         "stream disconnected before completion: " <>
                                           "You have no credits remaining.",
                                       "codexErrorInfo" => %{
                                         "responseStreamDisconnected" => %{
                                           "httpStatusCode" => nil
                                         }
                                       },
                                       "turnId" => "t",
                                       "willRetry" => true
                                     }
                                   }
                                 }
                               }
                             }
                           })
                         end) ++
                          [
                            ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"session_info_update","_meta":{"codex":{"threadStatus":{"type":"systemError"}}}}}}),
                            ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"stream disconnected before completion: You have no credits remaining."}}}})
                          ]

  @metadata_line ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"session_info_update","title":"t"}}})
  @update_line ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}})

  describe "from_state/1 and into_state/2" do
    test "round-trip the server's turn fields and nothing else", %{row: row} do
      state = %{
        conversation_id: "c",
        sandbox_id: "s",
        current_turn: row,
        current_turn_span: :span,
        turn_metrics: %{a: 1},
        stream_tracer: :tracer,
        replay_dedup: MapSet.new(["x"]),
        turn_session_retry: "gone once",
        turn_provider_failure: nil,
        other: :untouched
      }

      machine = TurnMachine.from_state(state)

      assert %TurnMachine{
               sandbox_id: "s",
               row: ^row,
               span: :span,
               metrics: %{a: 1},
               tracer: :tracer,
               session_retry: "gone once"
             } = machine

      assert MapSet.member?(machine.replay_dedup, "x")

      assert TurnMachine.into_state(state, %{machine | row: nil, span: nil}) ==
               %{state | current_turn: nil, current_turn_span: nil}
    end
  end

  describe "handle/3 with lines" do
    test "a replayed line is consumed from the dedup set and persisted nowhere", %{machine: m} do
      m = %{m | replay_dedup: MapSet.new([@update_line])}

      assert {%{replay_dedup: dedup}, []} = TurnMachine.handle(m, {:lines, "acp", @update_line})
      assert MapSet.size(dedup) == 0
    end

    test "session metadata updates the title with or without a running turn", %{machine: m} do
      assert {^m, [{:persist_lines, "acp", @metadata_line}]} =
               TurnMachine.handle(m, {:lines, "acp", @metadata_line})

      idle = idle(m)
      assert {^idle, []} = TurnMachine.handle(idle, {:lines, "acp", @metadata_line})
      assert Conversations._unsafe_get_conversation!(m.conversation_id).title == "t"
    end

    test "a deduplicated metadata replay cannot overwrite a newer title", %{machine: m} do
      m = %{m | replay_dedup: MapSet.new([@metadata_line])}
      Conversations._unsafe_update_harness_title(m.conversation_id, "New title")

      assert {%{replay_dedup: dedup}, []} = TurnMachine.handle(m, {:lines, "acp", @metadata_line})
      assert MapSet.size(dedup) == 0
      assert Conversations._unsafe_get_conversation!(m.conversation_id).title == "New title"
    end

    test "an update with no turn opens an autonomous one before persisting", %{machine: m} do
      idle = idle(m)

      assert {^idle, [:open_autonomous_turn, {:persist_lines, "acp", @update_line}]} =
               TurnMachine.handle(idle, {:lines, "acp", @update_line})
    end

    test "an update on an autonomous turn re-arms the quiet timer", %{machine: m} do
      assert {^m, [:arm_autonomous_quiet, {:persist_lines, "acp", @update_line}]} =
               TurnMachine.handle(m, {:lines, "acp", @update_line}, %{autonomous?: true})

      # On a prompted turn the first agent update also marks the metric (#2564).
      assert {next, [{:persist_lines, "acp", @update_line}]} =
               TurnMachine.handle(m, {:lines, "acp", @update_line}, %{autonomous?: false})

      assert next == %{
               m
               | metrics: Map.merge(m.metrics, %{first_update?: true, first_text?: true})
             }
    end

    test "a stderr line is only persisted", %{machine: m} do
      assert {^m, [{:persist_lines, "stderr", "oops"}]} =
               TurnMachine.handle(m, {:lines, "stderr", "oops"})
    end
  end

  describe "handle/3 with the cycle and the session" do
    test "cycle_end closes an autonomous turn as completed and nothing else", %{machine: m} do
      assert {^m,
              [
                {:finish, "completed", %{"origin" => "task"},
                 %{origin: "autonomous", cycle: "task"}}
              ]} = TurnMachine.handle(m, {:cycle_end, "task"}, %{autonomous?: true})

      assert {^m, []} = TurnMachine.handle(m, {:cycle_end, "task"}, %{autonomous?: false})
    end

    test "the session id is the server's to persist", %{machine: m} do
      assert {^m, [{:session_id, "sess-1"}]} = TurnMachine.handle(m, {:session, "sess-1"})
    end

    test "the prompt's JSON-RPC id is written on the row at once", %{machine: m, row: row} do
      assert {%{row: %{acp_prompt_id: 7}}, []} = TurnMachine.handle(m, {:prompt_sent, 7})
      assert Fountain.Repo.get!(Conversations.Turn, row.id).acp_prompt_id == 7
    end

    test "the handshake cost is a telemetry event and a span stamp", %{machine: m, row: row} do
      attach_telemetry([[:fountain, :acp, :handshake]])

      assert {^m, []} = TurnMachine.handle(m, {:handshake_ms, 42, "session/new"})

      assert_receive {:telemetry, [:fountain, :acp, :handshake], %{duration_ms: 42},
                      %{turn_id: turn_id, method: "session/new"}}

      assert turn_id == row.id
    end
  end

  describe "handle/3 with a refused model" do
    test "model selection failure persists evidence without an inference stamp", %{
      machine: m,
      conv: conv
    } do
      assert {updated, [{:finish, "failed", _, _}, {:drop_connection, "failed"}]} =
               TurnMachine.handle(
                 m,
                 {:failed, {:model_selection_failed, "gpt-9", "no such model"}}
               )

      assert updated.row.model_selection[:requested_model] == "gpt-9"

      assert [{"failed", %{"requested_model" => "gpt-9", "effective_model" => nil}}] =
               stages(conv.id, "model")

      saved = Fountain.Repo.get!(Conversations.Turn, m.row.id)
      assert saved.model_selection["status"] == "failed"
      assert saved.acp_prompt_id == nil
      refute Map.has_key?(saved.usage || %{}, "inference")
    end

    test "selected model evidence comes from the peer", %{machine: m, conv: conv} do
      assert {updated, []} = TurnMachine.handle(m, {:model_selected, "astra", "astra", "runtime"})
      assert updated.row.model_selection[:effective_model] == "astra"

      assert [{"done", %{"effective_model" => "astra", "source" => "runtime"}}] =
               stages(conv.id, "model")
    end

    test "model_unavailable fails the turn with the provider's sentence and drops the peer",
         %{machine: m, conv: conv} do
      assert {^m,
              [
                {:finish, "failed", %{"error" => message, "acp.model_unavailable" => true},
                 %{reason: message}},
                {:drop_connection, "failed"}
              ]} = TurnMachine.handle(m, {:failed, {:model_unavailable, "gpt-9", "Not found."}})

      assert message =~ "(gpt-9): Not found."
      assert message =~ "Change the agent's model"

      assert [{"failed", %{"requested" => "gpt-9", "using" => "none, the turn failed"}}] =
               stages(conv.id, "model")
    end
  end

  describe "handle/3 with permissions" do
    test "an ask is the server's, on an autonomous turn if none is open", %{machine: m} do
      assert {^m, [{:ask_permission, 3, "bash", ["allow"]}]} =
               TurnMachine.handle(m, {:permission_ask, 3, "bash", ["allow"]})

      idle = idle(m)

      assert {^idle, [:open_autonomous_turn, {:ask_permission, 3, "bash", ["allow"]}]} =
               TurnMachine.handle(idle, {:permission_ask, 3, "bash", ["allow"]})
    end

    test "a denial is audited with the tool and the verdict, never the input", %{
      machine: m,
      conv: conv
    } do
      assert {^m, []} = TurnMachine.handle(m, {:permission_denied, "rm", "auto_deny"})

      assert [%{metadata: %{"tool" => "rm", "verdict" => "auto_deny"}}] =
               Fountain.Repo.all(
                 from(a in Fountain.Audit.Event,
                   where:
                     a.resource_id == ^conv.id and a.action == "conversation.permission_denied"
                 )
               )
    end
  end

  describe "handle/3 with the turn's end" do
    test "done records usage and finishes; a refusal or cancel is a failed turn", %{
      machine: m,
      row: row
    } do
      assert {^m,
              [{:finish, "completed", %{"stop_reason" => "end_turn"}, %{stop_reason: "end_turn"}}]} =
               TurnMachine.handle(m, {:done, "end_turn", %{"input" => 3, "output" => 5}})

      assert Fountain.Repo.get!(Conversations.Turn, row.id).usage == %{
               "input" => 3,
               "output" => 5
             }

      assert {^m, [{:finish, "failed", _, %{stop_reason: "refusal"}}]} =
               TurnMachine.handle(m, {:done, "refusal", nil})

      assert {^m, [{:finish, "failed", _, %{stop_reason: "cancelled"}}]} =
               TurnMachine.handle(m, {:done, "cancelled", nil})
    end

    test "a codex thread in systemError fails an end_turn with the provider's words", %{
      machine: m,
      row: row
    } do
      # The sequence #2545 recorded against a key with no credits left.
      m = feed(m, @codex_out_of_credits)

      assert {_m,
              [
                {:finish, "failed", %{"acp.system_error" => true, "stop_reason" => "end_turn"},
                 %{stop_reason: "end_turn", reason: reason}}
              ]} = TurnMachine.handle(m, {:done, "end_turn", %{"input" => 3, "output" => 0}})

      assert reason ==
               "The runtime ended this turn on a system error: " <>
                 "stream disconnected before completion: You have no credits remaining."

      # The usage is still the turn's.
      assert Fountain.Repo.get!(Conversations.Turn, row.id).usage == %{
               "input" => 3,
               "output" => 0
             }
    end

    test "systemError with no error before it fails the turn without a detail", %{machine: m} do
      m = feed(m, [codex_line(%{"threadStatus" => %{"type" => "systemError"}})])

      assert {_m, [{:finish, "failed", _, %{reason: reason}}]} =
               TurnMachine.handle(m, {:done, "end_turn", nil})

      assert reason == "The runtime ended this turn on a system error and gave no detail."
    end

    test "retries that recovered do not fail the turn", %{machine: m} do
      # Errors Codex retried past, and no systemError: the call came back.
      m = feed(m, Enum.take(@codex_out_of_credits, 2))

      assert {_m, [{:finish, "completed", _, %{stop_reason: "end_turn"}}]} =
               TurnMachine.handle(m, {:done, "end_turn", nil})

      # A thread that went back to work after a systemError is not failed either.
      m =
        feed(m, [
          codex_line(%{"threadStatus" => %{"type" => "systemError"}}),
          codex_line(%{"threadStatus" => %{"type" => "active", "activeFlags" => []}})
        ])

      assert {_m, [{:finish, "completed", _, _}]} =
               TurnMachine.handle(m, {:done, "end_turn", nil})
    end

    test "the verdict belongs to the turn that heard it", %{machine: m} do
      # Out of turn there is nothing to fail, and nothing is kept for the next.
      idle = idle(m)
      status = codex_line(%{"threadStatus" => %{"type" => "systemError"}})
      assert {^idle, []} = TurnMachine.handle(idle, {:lines, "acp", status})

      # Within a turn, finishing it clears what it heard.
      m = feed(m, [status])
      assert %{system_error?: true} = m.provider_failure
      assert %TurnMachine{provider_failure: nil} = TurnMachine.finish(m, "failed", %{}, %{})
    end

    test "adapter accounting survives termination and storage without invented counts", %{
      machine: machine,
      row: row,
      conv: conv
    } do
      accounting = %{
        "version" => 1,
        "source" => "codex/thread-token-usage-delta",
        "scope" => "root_thread_prompt",
        "completeness" => "partial"
      }

      usage =
        Managoat.ACP.Usage.from_prompt_result(%{
          "stopReason" => "cancelled",
          "usage" => nil,
          "_meta" => %{"usageAccounting" => accounting}
        })

      assert {^machine, [{:finish, "failed", _, _}]} =
               TurnMachine.handle(machine, {:done, "cancelled", usage})

      stored = Fountain.Repo.get!(Conversations.Turn, row.id) |> Fountain.Repo.preload(:images)
      assert stored.usage == %{"accounting" => accounting}

      assert %{data: [%{usage: %{accounting: ^accounting}}]} =
               FountainWeb.ConversationJSON.turns(%{turns: [stored]})

      assert %{usage_input_tokens: 0, usage_output_tokens: 0} =
               Conversations._unsafe_get_conversation!(conv.id)

      assert {:error, :already_recorded} = Conversations._unsafe_record_turn_usage(stored, usage)
    end

    test "a failed peer ends the turn it drove and drops the connection", %{machine: m} do
      assert {^m,
              [
                {:finish, "failed", %{"error" => ":boom"}, %{reason: "acp: :boom"}},
                {:drop_connection, "failed"}
              ]} = TurnMachine.handle(m, {:failed, :boom})

      idle = idle(m)
      assert {^idle, [{:drop_connection, "failed"}]} = TurnMachine.handle(idle, {:failed, :boom})
    end

    test "an org-refused OAuth token on Claude says whether a key was swapped in", %{machine: m} do
      ctx = %{runtime_module: Managoat.Runtimes.Claude, oauth_switched?: true}

      assert {^m,
              [
                {:finish, "failed", %{"error" => switched, "acp.oauth_org_not_allowed" => true},
                 %{reason: switched}},
                {:drop_connection, "failed"}
              ]} = TurnMachine.handle(m, {:failed, {:oauth_org_not_allowed, "policy"}}, ctx)

      assert switched =~ "Switched to the Anthropic API key"

      {_, [{:finish, "failed", %{"error" => no_key}, _} | _]} =
        TurnMachine.handle(m, {:failed, {:oauth_org_not_allowed, "policy"}}, %{
          ctx
          | oauth_switched?: false
        })

      assert no_key =~ "no Anthropic API key is on file"
    end

    # The failure that read as a quiet conversation, and #1667's answer to it.
    # A first turn whose ACP `initialize` fails leaves `runtime_session_id`
    # set — `session_plan/2` persisted it before the turn ran — and no rollout
    # under it, so every later prompt resumed a session that was never opened.
    # Nothing was asked of the model, so the turn is restarted rather than
    # failed: the id is cleared and the same peer opens a fresh session before
    # sending the original input.
    test "a resume against a session that is not there restarts the turn", %{machine: m} do
      error = %{
        "code" => -32_603,
        "message" => "Internal error",
        "data" => %{"details" => "no rollout found for thread id be412434-0b99"}
      }

      detail = "no rollout found for thread id be412434-0b99"

      assert {restarted,
              [
                {:restart_session, ^detail}
              ]} = TurnMachine.handle(m, {:failed, {:acp_error, :resume_session, error}})

      # No `finish`: the turn has not ended, and the row it will run again on
      # is the one it started with.
      assert restarted.row == m.row
      assert restarted.session_retry == detail
    end

    test "a second session_gone on the fresh session fails the turn", %{machine: m} do
      {restarted, _} =
        TurnMachine.handle(
          m,
          {:failed, {:acp_error, :resume_session, %{"code" => -32_002, "message" => "gone"}}}
        )

      assert {^restarted,
              [
                {:forget_runtime_session, "session_gone", _},
                {:finish, "failed", %{"error" => message, "acp.session_gone" => true},
                 %{reason: message}},
                {:drop_connection, "failed"}
              ]} =
               TurnMachine.handle(
                 restarted,
                 {:failed,
                  {:acp_error, :resume_session, %{"code" => -32_002, "message" => "gone again"}}}
               )

      assert message =~ "gone again"
      assert message =~ "Send your prompt again"
      assert message =~ "will not remember"
    end

    test "the -32002 a replaced disk answers with is the same restart", %{machine: m} do
      assert {%{session_retry: "Resource not found"},
              [
                {:restart_session, _}
              ]} =
               TurnMachine.handle(
                 m,
                 {:failed,
                  {:acp_error, :load_session,
                   %{"code" => -32_002, "message" => "Resource not found"}}}
               )
    end

    test "a resume that failed for any other reason keeps the session", %{machine: m} do
      assert {^m, [{:finish, "failed", %{"error" => error}, _}, {:drop_connection, "failed"}]} =
               TurnMachine.handle(
                 m,
                 {:failed,
                  {:acp_error, :resume_session, %{"code" => -32_603, "message" => "peer died"}}}
               )

      # The catch-all's inspected tuple, and no clearing: a session that may
      # still be good is not thrown away over a transient failure.
      assert error =~ "acp_error"
    end

    test "a failure on any other call is never read as a missing session", %{machine: m} do
      assert {^m, [{:finish, "failed", _, _}, {:drop_connection, "failed"}]} =
               TurnMachine.handle(
                 m,
                 {:failed, {:acp_error, :prompt, %{"message" => "resource not found"}}}
               )
    end

    # Nothing to replay, so nothing to restart: the id is cleared and the
    # connection dropped, exactly as before #1667.
    test "the same failure with no turn open still clears the session", %{machine: m} do
      idle = idle(m)

      assert {^idle, [{:forget_runtime_session, "session_gone", _}, {:drop_connection, "failed"}]} =
               TurnMachine.handle(
                 idle,
                 {:failed, {:acp_error, :resume_session, %{"code" => -32_002}}}
               )
    end

    test "the same refusal on another runtime is an ordinary peer failure", %{machine: m} do
      assert {^m, [{:finish, "failed", %{"error" => error}, _}, {:drop_connection, "failed"}]} =
               TurnMachine.handle(
                 m,
                 {:failed, {:oauth_org_not_allowed, "policy"}},
                 %{runtime_module: Managoat.Runtimes.Gemini}
               )

      assert error =~ "oauth_org_not_allowed"
    end
  end

  describe "finish/4" do
    test "closes the row, publishes the stage, emits the metric, idles the conversation and clears",
         %{machine: m, conv: conv, row: row} do
      attach_telemetry([[:fountain, :turn, :completed]])
      {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

      assert %TurnMachine{row: nil, span: nil, metrics: nil, tracer: nil} =
               TurnMachine.finish(m, "completed", %{"stop_reason" => "end_turn"}, %{
                 stop_reason: "end_turn"
               })

      assert %{status: "completed", ended_at: %DateTime{}} =
               Fountain.Repo.get!(Conversations.Turn, row.id)

      assert [{"done", %{"turn_id" => turn_id, "stop_reason" => "end_turn"}}] =
               stages(conv.id, "turn")

      assert turn_id == row.id
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      assert_receive {:telemetry, [:fountain, :turn, :completed], %{duration_ms: _},
                      %{
                        runtime: "claude",
                        provider: "e2b",
                        status: "completed",
                        conv_id: conv_id
                      }}

      assert conv_id == conv.id
    end

    for stale <- [:reassigned, :terminated, :failed, :completed, :interrupted, :deleted] do
      @tag stale: stale
      test "a #{stale} completion preserves the persisted result without duplicate events", ctx do
        attach_telemetry([[:fountain, :turn, :completed]])
        insert_log_event(ctx.conv, turn_id: ctx.row.id, stream: "acp", data: @update_line)

        case ctx.stale do
          :reassigned ->
            replacement = insert_sandbox(user_id: ctx.user.id)

            Conversations.update_conversation(ctx.conv, %{
              sandbox_id: replacement.id,
              status: "running"
            })

          terminal when terminal in [:terminated, :failed] ->
            Conversations.update_conversation(ctx.conv, %{status: Atom.to_string(terminal)})

          ended when ended in [:completed, :interrupted] ->
            ctx.row
            |> Ecto.Changeset.change(status: Atom.to_string(ended))
            |> Fountain.Repo.update!()

            Conversations.update_conversation(ctx.conv, %{status: "running"})
            insert_turn(ctx.conv, status: "running")

          :deleted ->
            Fountain.Repo.delete!(ctx.conv)
        end

        persisted_turn = Fountain.Repo.get(Conversations.Turn, ctx.row.id)
        persisted_conv = Fountain.Repo.get(Conversations.Conversation, ctx.conv.id)

        assert %TurnMachine{row: nil, span: nil, metrics: nil, tracer: nil} =
                 TurnMachine.finish(ctx.machine, "completed", %{}, %{})

        assert Fountain.Repo.get(Conversations.Turn, ctx.row.id) == persisted_turn
        assert Fountain.Repo.get(Conversations.Conversation, ctx.conv.id) == persisted_conv
        assert stages(ctx.conv.id, "turn") == []
        refute_receive {:telemetry, [:fountain, :turn, :completed], _, _}, 50
      end
    end

    test "a successor admitted mid-completion keeps the conversation running", ctx do
      Conversations.update_conversation(ctx.conv, %{status: "running"})
      successor = insert_turn(ctx.conv, status: "running")

      TurnMachine.finish(ctx.machine, "completed", %{}, %{})

      assert Fountain.Repo.reload!(ctx.row).status == "completed"
      assert Fountain.Repo.reload!(ctx.conv).status == "running"
      assert Fountain.Repo.reload!(successor).status == "running"
    end

    test "completion materializes a reply", ctx do
      insert_log_event(ctx.conv, turn_id: ctx.row.id, stream: "acp", data: @update_line)
      TurnMachine.finish(ctx.machine, "completed", %{}, %{})
      assert Fountain.Repo.reload!(ctx.row).reply_text == "hi"
    end

    test "a failed status is the failed stage, and no metric without metrics", %{
      machine: m,
      conv: conv
    } do
      attach_telemetry([[:fountain, :turn, :completed]])

      TurnMachine.finish(%{m | metrics: nil}, "failed", %{"error" => "x"}, %{reason: "x"})

      assert [{"failed", %{"reason" => "x"}}] = stages(conv.id, "turn")
      refute_receive {:telemetry, [:fountain, :turn, :completed], _, _}, 50
    end
  end

  describe "the interrupt pair" do
    test "marks the row, publishes, then closes the span and idles", %{
      machine: m,
      conv: conv,
      row: row
    } do
      attach_telemetry([[:fountain, :turn, :completed]])
      {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

      marked = TurnMachine.mark_interrupted(m)
      assert marked.interrupted?
      assert Fountain.Repo.reload!(conv).status == "running"
      assert marked.row == row
      assert Fountain.Repo.get!(Conversations.Turn, row.id).status == "interrupted"
      assert [{"interrupted", %{"turn_id" => _}}] = stages(conv.id, "turn")

      assert %TurnMachine{row: nil, metrics: nil} = TurnMachine.close_interrupted(marked)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
      assert_receive {:telemetry, [:fountain, :turn, :completed], _, %{status: "interrupted"}}
    end

    # The interrupt is a second door onto the writer that materialises
    # `reply_text`; `_unsafe_interrupt_turn/2` passes `idle?: false`, and the
    # reply must not be gated on the idle write.
    test "an interrupted turn materializes its reply", ctx do
      insert_log_event(ctx.conv, turn_id: ctx.row.id, stream: "acp", data: @update_line)

      TurnMachine.mark_interrupted(ctx.machine)

      assert Fountain.Repo.reload!(ctx.row).reply_text == "hi"
    end

    for stale <- [:reassigned, :terminated, :completed, :interrupted] do
      @tag stale: stale
      test "a #{stale} turn is not interrupted by the stale actor", ctx do
        attach_telemetry([[:fountain, :turn, :completed]])

        case ctx.stale do
          :reassigned ->
            replacement = insert_sandbox(user_id: ctx.user.id)

            Conversations.update_conversation(ctx.conv, %{
              sandbox_id: replacement.id,
              status: "running"
            })

          :terminated ->
            Conversations.update_conversation(ctx.conv, %{status: "terminated"})

          status ->
            ctx.row
            |> Ecto.Changeset.change(status: Atom.to_string(status))
            |> Fountain.Repo.update!()
        end

        persisted_turn = Fountain.Repo.reload!(ctx.row)
        persisted_conv = Fountain.Repo.get!(Conversations.Conversation, ctx.conv.id)
        marked = TurnMachine.mark_interrupted(ctx.machine)
        refute marked.interrupted?

        assert %TurnMachine{row: nil, metrics: nil, interrupted?: false} =
                 TurnMachine.close_interrupted(marked)

        assert Fountain.Repo.reload!(ctx.row) == persisted_turn
        assert Fountain.Repo.get!(Conversations.Conversation, ctx.conv.id) == persisted_conv
        assert stages(ctx.conv.id, "turn") == []
        refute_receive {:telemetry, [:fountain, :turn, :completed], _, _}, 50
      end
    end

    for change <- [:terminated, :new_turn, :deleted] do
      @tag between: change
      test "#{change} between interrupt halves keeps the newer conversation state", ctx do
        attach_telemetry([[:fountain, :turn, :completed]])
        Conversations.update_conversation(ctx.conv, %{status: "running"})
        marked = TurnMachine.mark_interrupted(ctx.machine)
        assert marked.interrupted?

        case ctx.between do
          :terminated ->
            Conversations.update_conversation(ctx.conv, %{status: "terminated"})

          :new_turn ->
            insert_turn(ctx.conv, status: "running")

          :deleted ->
            Fountain.Repo.delete!(ctx.conv)
        end

        persisted_conv = Fountain.Repo.get(Conversations.Conversation, ctx.conv.id)
        prior_stages = stages(ctx.conv.id, "turn")

        assert %TurnMachine{row: nil, metrics: nil, interrupted?: false} =
                 TurnMachine.close_interrupted(marked)

        assert Fountain.Repo.get(Conversations.Conversation, ctx.conv.id) == persisted_conv
        assert stages(ctx.conv.id, "turn") == prior_stages
        assert_receive {:telemetry, [:fountain, :turn, :completed], _, %{status: "interrupted"}}
        refute_receive {:telemetry, [:fountain, :turn, :completed], _, _}, 50
      end
    end

    # The first half retires the turn, so turn recovery cannot idle its parent.
    # A rebind can arrive while the peer stops. The matching second half must
    # still finish cleanup when this remains the latest turn, without relying
    # on a later machine-gone cast or lifecycle cleanup to idle the parent.
    test "a rebind between the interrupt halves still releases the parent", ctx do
      Conversations.update_conversation(ctx.conv, %{status: "running"})
      marked = TurnMachine.mark_interrupted(ctx.machine)
      assert marked.interrupted?
      assert Fountain.Repo.reload!(ctx.conv).status == "running"

      replacement = insert_sandbox(user_id: ctx.user.id)
      Conversations.update_conversation(ctx.conv, %{sandbox_id: replacement.id})

      TurnMachine.close_interrupted(marked)

      assert Fountain.Repo.reload!(ctx.conv).status == "idle"
      assert Fountain.Repo.reload!(ctx.conv).sandbox_id == replacement.id
      assert Fountain.Repo.reload!(ctx.row).status == "interrupted"
    end

    # The predicate is `latest_turn?/2`, not "no other turn is running". An
    # older turn abandoned `running` — which the stale-actor arm of
    # `_unsafe_interrupt_turn/2` manufactures — must not pin the parent.
    test "an abandoned older turn does not stop the interrupt idling the parent", ctx do
      abandoned = insert_turn(ctx.conv, status: "running", started_at: DateTime.utc_now())
      newest = insert_turn(ctx.conv, status: "running", started_at: DateTime.utc_now())
      assert abandoned.turn_number < newest.turn_number
      Conversations.update_conversation(ctx.conv, %{status: "running"})

      machine = %{ctx.machine | row: newest}

      machine |> TurnMachine.mark_interrupted() |> TurnMachine.close_interrupted()

      assert Fountain.Repo.reload!(ctx.conv).status == "idle"
      assert Fountain.Repo.reload!(abandoned).status == "running"
    end

    # `_unsafe_idle_interrupted_turn/1` idles a `running` parent, nothing else.
    # A `pending` conversation completing an interrupt was going `idle` here.
    for status <- ["pending", "idle"] do
      @tag parent: status
      test "the interrupt leaves a #{status} conversation alone", ctx do
        marked = TurnMachine.mark_interrupted(%{ctx.machine | row: ctx.row})

        ctx.conv
        |> Ecto.Changeset.change(status: ctx.parent)
        |> Fountain.Repo.update!()

        TurnMachine.close_interrupted(marked)

        assert Fountain.Repo.reload!(ctx.conv).status == ctx.parent
      end
    end

    # Ours to release means ours: a turn another writer moved off `interrupted`
    # is no longer the one this half retired, so it writes nothing.
    test "a turn moved off interrupted between the halves is not released", ctx do
      Conversations.update_conversation(ctx.conv, %{status: "running"})
      marked = TurnMachine.mark_interrupted(ctx.machine)
      assert marked.interrupted?

      ctx.row |> Ecto.Changeset.change(status: "completed") |> Fountain.Repo.update!()

      TurnMachine.close_interrupted(marked)

      assert Fountain.Repo.reload!(ctx.conv).status == "running"
    end
  end

  describe "the metrics" do
    test "first text excludes thinking and empty text and includes request setup time", %{
      machine: m
    } do
      attach_telemetry([[:fountain, :turn, :first_text], [:fountain, :response, :first_text]])
      now = System.monotonic_time(:millisecond)
      metrics = TurnMachine.start_metrics("codex", :sprites, now - 100, 1)

      metrics =
        TurnMachine.with_response_timing(metrics, %{started_mono: now - 1000, path: "cold"})

      m = %{m | metrics: metrics}

      line = fn kind, text ->
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{update: %{sessionUpdate: kind, content: %{type: "text", text: text}}}
        })
      end

      assert TurnMachine.maybe_emit_first_text(m, line.("agent_thought_chunk", "thinking")) == m
      assert TurnMachine.maybe_emit_first_text(m, line.("agent_message_chunk", "")) == m
      assert TurnMachine.maybe_emit_first_text(m, "not json") == m
      refute_received {:telemetry, [:fountain, :turn, :first_text], _, _}
      once = TurnMachine.maybe_emit_first_text(m, line.("agent_message_chunk", "hello"))

      assert_receive {:telemetry, [:fountain, :turn, :first_text], %{elapsed_ms: prompt_ms},
                      %{runtime: "codex", provider: "sprites", turn_class: "first"}}

      assert_receive {:telemetry, [:fountain, :response, :first_text], %{elapsed_ms: total_ms},
                      %{path: "cold"}}

      assert total_ms - prompt_ms == 900
      assert once.metrics.first_text?

      assert TurnMachine.maybe_emit_first_text(once, line.("agent_message_chunk", "again")) ==
               once

      assert TurnMachine.maybe_emit_first_text(idle(m), line.("agent_message_chunk", "replay")) ==
               idle(m)

      refute_received {:telemetry, [:fountain, :turn, :first_text], _, _}
    end

    test "first output is reported once, and never without metrics", %{machine: m} do
      attach_telemetry([[:fountain, :turn, :first_output]])

      once = TurnMachine.maybe_emit_first_output(m)
      assert once.metrics.first_output?

      assert_receive {:telemetry, [:fountain, :turn, :first_output], %{elapsed_ms: _},
                      %{runtime: "claude", provider: "e2b"}}

      assert TurnMachine.maybe_emit_first_output(once) == once
      refute_receive {:telemetry, [:fountain, :turn, :first_output], _, _}, 50

      assert TurnMachine.maybe_emit_first_output(idle(m)) == idle(m)
    end

    # #2564: first_output fires on handshake bytes; this one waits for the
    # agent to show something.
    test "first update is reported once, on the first agent update", %{machine: m} do
      attach_telemetry([[:fountain, :turn, :first_update]])

      update = fn kind ->
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{sessionId: "s", update: %{sessionUpdate: kind}}
        }) <> "\n"
      end

      bookkeeping = TurnMachine.maybe_emit_first_update(m, update.("available_commands_update"))
      assert bookkeeping == m
      refute_receive {:telemetry, [:fountain, :turn, :first_update], _, _}, 50

      once = TurnMachine.maybe_emit_first_update(m, update.("agent_thought_chunk"))

      assert_receive {:telemetry, [:fountain, :turn, :first_update], %{elapsed_ms: _},
                      %{runtime: "claude", provider: "e2b", kind: "agent_thought_chunk"}}

      assert TurnMachine.maybe_emit_first_update(once, update.("agent_message_chunk")) == once
      refute_receive {:telemetry, [:fountain, :turn, :first_update], _, _}, 50

      assert TurnMachine.maybe_emit_first_update(idle(m), update.("tool_call")) == idle(m)
      assert TurnMachine.maybe_emit_first_update(m, "not json\n") == m
    end

    test "record_usage/2 records nothing for nil, and warns on a second recording", %{
      machine: m,
      row: row
    } do
      assert :ok = TurnMachine.record_usage(m, nil)
      assert :ok = TurnMachine.record_usage(%{m | row: nil}, %{"input" => 1})
      assert :ok = TurnMachine.record_usage(m, %{"input" => 1})
      assert Fountain.Repo.get!(Conversations.Turn, row.id).usage == %{"input" => 1}
    end
  end

  describe "starting a turn" do
    test "open/3 creates the running row, numbered after the last", %{conv: conv} do
      assert {:ok, %{id: conv_id}, %{turn_number: 2, status: "running", prompt: "hi"}} =
               TurnMachine.open(conv.id, conv.sandbox_id, "hi")

      assert conv_id == conv.id
    end

    test "gate/1 admits a verified account", %{user: user} do
      assert :ok = TurnMachine.gate(user.id)
    end

    test "session_plan/2 runs fresh with a persisted placeholder, and continues an existing id",
         %{conv: conv, row: row} do
      {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})
      assert {:ok, {:run, id}} = TurnMachine.session_plan(row, nil)
      assert Conversations._unsafe_get_conversation!(conv.id).runtime_session_id == id
      assert {:ok, {:continue, "keep"}} = TurnMachine.session_plan(row, "keep")
    end

    test "command/3 returns the ACP adapter with the sandbox's cwd",
         %{conv: conv, agent: agent} do
      handle = %Managoat.Sandbox.Handle{provider: :sprites, name: "s"}

      assert {cmd, args, dir} = TurnMachine.command(conv, agent, handle)
      assert {cmd, args} == Fountain.RuntimeDispatch.command(conv.runtime, agent)
      assert dir == Managoat.Sandbox.host_path(handle, Managoat.Runtimes.ACP.cwd("claude"))

      # A launch's own cwd is the adapter's, and so the session's (ADR 0097).
      assert {_cmd, _args, "/home/sprite/work"} =
               TurnMachine.command(%{conv | cwd: "/home/sprite/work"}, agent, handle)
    end

    test "store_images/2 keeps a rejected image from taking the turn down", %{row: row} do
      assert :ok =
               TurnMachine.store_images(row, [
                 %{media_type: "image/png", data: <<137, 80, 78, 71>>}
               ])

      assert :ok = TurnMachine.store_images(row, [%{media_type: "text/plain", data: "nope"}])
    end

    test "effective_permission_policy/2 and agent_for/1", %{conv: conv, agent: agent} do
      assert TurnMachine.agent_for(conv).id == agent.id
      assert TurnMachine.agent_for(%{conv | agent_id: nil}) == nil

      assert TurnMachine.effective_permission_policy(conv, agent) ==
               Managoat.ACP.Permissions.effective(agent.permission_policy, conv.permission_policy)
    end
  end

  describe "a turn that never started" do
    test "fail_before_start/4 fails the row with the detail, and idles a running conversation",
         %{conv: conv, row: row} do
      {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})
      detail = ":enoent"

      assert :ok =
               TurnMachine.fail_before_start(
                 row,
                 conv.id,
                 conv.sandbox_id,
                 detail
               )

      assert %{status: "failed", exit_code: nil} = Fountain.Repo.get!(Conversations.Turn, row.id)
      assert [{"failed", %{"reason" => ^detail, "exit_code" => nil}}] = stages(conv.id, "turn")
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
    end

    test "startup failure materializes a reply and accepts a missing exit code", ctx do
      insert_log_event(ctx.conv, turn_id: ctx.row.id, stream: "acp", data: @update_line)

      assert :ok =
               TurnMachine.fail_before_start(
                 ctx.row,
                 ctx.conv.id,
                 ctx.conv.sandbox_id,
                 "boom"
               )

      assert %{status: "failed", exit_code: nil, reply_text: "hi", ended_at: %DateTime{}} =
               Fountain.Repo.reload!(ctx.row)

      assert [{"failed", %{"exit_code" => nil}}] = stages(ctx.conv.id, "turn")
    end

    for stale <- [:reassigned, :terminated, :failed, :completed, :interrupted, :deleted] do
      @tag stale: stale
      test "a #{stale} startup failure preserves persisted state without a failure stage", ctx do
        insert_log_event(ctx.conv, turn_id: ctx.row.id, stream: "acp", data: @update_line)

        case ctx.stale do
          :reassigned ->
            replacement = insert_sandbox(user_id: ctx.user.id)

            Conversations.update_conversation(ctx.conv, %{
              sandbox_id: replacement.id,
              status: "running"
            })

          terminal when terminal in [:terminated, :failed] ->
            Conversations.update_conversation(ctx.conv, %{status: Atom.to_string(terminal)})

          ended when ended in [:completed, :interrupted] ->
            ctx.row
            |> Ecto.Changeset.change(status: Atom.to_string(ended), exit_code: 0)
            |> Fountain.Repo.update!()

            Conversations.update_conversation(ctx.conv, %{status: "running"})
            insert_turn(ctx.conv, status: "running")

          :deleted ->
            Fountain.Repo.delete!(ctx.conv)
        end

        persisted_turn = Fountain.Repo.get(Conversations.Turn, ctx.row.id)
        persisted_conv = Fountain.Repo.get(Conversations.Conversation, ctx.conv.id)

        assert :ok =
                 TurnMachine.fail_before_start(
                   ctx.row,
                   ctx.conv.id,
                   ctx.conv.sandbox_id,
                   "boom"
                 )

        assert Fountain.Repo.get(Conversations.Turn, ctx.row.id) == persisted_turn
        assert Fountain.Repo.get(Conversations.Conversation, ctx.conv.id) == persisted_conv
        assert stages(ctx.conv.id, "turn") == []
      end
    end
  end

  describe "the session reset and the messages" do
    test "reset_runtime_session/2 clears the row and says why", %{conv: conv} do
      {:ok, conv} = Conversations.update_conversation(conv, %{runtime_session_id: "old"})
      assert :ok = TurnMachine.reset_runtime_session(conv, conv.id)
      assert Conversations._unsafe_get_conversation!(conv.id).runtime_session_id == nil

      assert [{"done", %{"event" => "reset", "reason" => "fresh_sandbox"}}] =
               stages(conv.id, "session")
    end

    test "reset_runtime_session/4 records the reason the caller knows", %{conv: conv} do
      {:ok, conv} = Conversations.update_conversation(conv, %{runtime_session_id: "old"})
      assert :ok = TurnMachine.reset_runtime_session(conv, conv.id, "session_gone", "no rollout")
      assert Conversations._unsafe_get_conversation!(conv.id).runtime_session_id == nil

      assert [{"done", %{"reason" => "session_gone", "detail" => "no rollout"}}] =
               stages(conv.id, "session")
    end

    test "forget_runtime_session/2 clears the server's copy along with the row", %{conv: conv} do
      {:ok, conv} = Conversations.update_conversation(conv, %{runtime_session_id: "old"})
      state = %{conversation_id: conv.id, runtime_session_id: "old"}

      assert %{runtime_session_id: nil} = TurnMachine.forget_runtime_session(state, conv)
      assert Conversations._unsafe_get_conversation!(conv.id).runtime_session_id == nil
      assert [{"done", %{"reason" => "fresh_sandbox"}}] = stages(conv.id, "session")
    end

    test "forget_runtime_session/2 on a conversation with no session is not an event",
         %{conv: conv} do
      state = %{conversation_id: conv.id, runtime_session_id: nil}

      assert ^state = TurnMachine.forget_runtime_session(state, conv)
      assert stages(conv.id, "session") == []
    end

    test "model_unavailable_message/2 names the model when there is one" do
      assert TurnMachine.model_unavailable_message("m", " gone ") =~ "model (m): gone Change"
      refute TurnMachine.model_unavailable_message(nil, "gone") =~ "("
    end
  end
end
