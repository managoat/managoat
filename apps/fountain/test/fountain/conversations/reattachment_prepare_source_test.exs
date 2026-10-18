defmodule Fountain.Conversations.ReattachmentPrepareSourceTest do
  @moduledoc """
  #2562: a reattach writes the runtime config, the instructions, the env file
  and broker trust/transport at once, as a fresh provision does. Both broker
  readiness and the env file decide whether the reattach carries on.
  """
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.{Egress, InferenceBinding, Provisioning, Reattachment, Skills}
  alias Managoat.Sandbox.Handle

  @receive_timeout 2_000

  setup do
    conv = insert_conversation()

    state = %{
      conversation_id: conv.id,
      user_id: conv.user_id,
      runtime_module: nil,
      callback_token: "t",
      broker: nil,
      inference_source: nil
    }

    stub(Provisioning, :write_instructions, fn _handle, _runtime, _agent, _home -> :ok end)
    stub(Provisioning, :write_env_file, fn _handle, _env -> :ok end)
    stub(Skills, :mount, fn _handle, _conv, _agent, _sprite_env -> :ok end)
    stub(InferenceBinding, :reserve, fn _conv, _source -> :ok end)
    stub(Provisioning, :prepare_runtime_sprite, fn _, _, _, _, _, _, _ -> :ok end)

    %{conv: conv, state: state, handle: %Handle{provider: :sprites, name: "s"}}
  end

  test "the config and the CA are written at once", ctx do
    test_pid = self()

    stub(Provisioning, :write_runtime_config, fn _handle, _module, _agent, _home ->
      send(test_pid, {:config, self()})
      receive do: (:go -> :ok)
    end)

    stub(Egress, :install_ca, fn _broker, _handle, _conv_id ->
      send(test_pid, {:ca, self()})
      receive do: (:go -> :ok)
    end)

    task =
      Task.async(fn ->
        Reattachment.prepare_source(ctx.handle, ctx.state, ctx.conv, nil, [])
      end)

    # Both have started while neither has finished: one after another, the
    # second would never begin.
    assert_receive {:config, config}, @receive_timeout
    assert_receive {:ca, ca}, @receive_timeout
    send(config, :go)
    send(ca, :go)

    assert Task.await(task) == :ok
  end

  test "the wake's skills get the conversation's env, after the CA", ctx do
    test_pid = self()
    stub(Provisioning, :write_runtime_config, fn _, _, _, _ -> :ok end)
    stub(Egress, :install_ca, fn _, _, _ -> send(test_pid, :ca) && :ok end)

    stub(Skills, :mount, fn _handle, _conv, _agent, sprite_env ->
      send(test_pid, {:skills, sprite_env})
      :ok
    end)

    sprite_env = [{"HTTPS_PROXY", "http://tok:c-x@broker:8443"}]
    assert :ok = Reattachment.prepare_source(ctx.handle, ctx.state, ctx.conv, nil, sprite_env)
    assert_received :ca
    assert_received {:skills, ^sprite_env}
  end

  test "a failed runtime config is logged but broker readiness refuses the wake", ctx do
    stub(Provisioning, :write_runtime_config, fn _, _, _, _ -> {:error, :refused} end)
    stub(Egress, :install_ca, fn _, _, _ -> {:error, {:broker, :ca_install_exit, 1, ""}} end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:broker, :ca_install_exit, 1, ""}} =
                 Reattachment.prepare_source(ctx.handle, ctx.state, ctx.conv, nil, [])
      end)

    assert log =~ "runtime config write on wake"
  end

  test "a failed env file write is the reattach's answer", ctx do
    stub(Provisioning, :write_runtime_config, fn _, _, _, _ -> :ok end)
    stub(Egress, :install_ca, fn _, _, _ -> :ok end)
    stub(Provisioning, :write_env_file, fn _, _ -> {:error, :disk_full} end)
    reject(&Provisioning.prepare_runtime_sprite/7)

    assert {:error, :disk_full} =
             Reattachment.prepare_source(ctx.handle, ctx.state, ctx.conv, nil, [])
  end
end
