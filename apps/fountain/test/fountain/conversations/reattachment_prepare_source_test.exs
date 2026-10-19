defmodule Fountain.Conversations.ReattachmentPrepareSourceTest do
  @moduledoc """
  #2562: a reattach writes the runtime config, the instructions, the env file
  and broker trust/transport at once, as a fresh provision does. Both broker
  readiness and the env file decide whether the reattach carries on.
  """
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.{ConfigHome, Egress, InferenceBinding, Provisioning}
  alias Fountain.Conversations.{Reattachment, Skills}
  alias Managoat.Sandbox.Handle

  @receive_timeout 2_000

  setup do
    conv = insert_conversation()

    state = %{
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
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

    stub(Egress, :install_ca, fn _broker, _handle, _conv_id, _relay_owner ->
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

  test "the relay is the conversation's on its own machine and the workspace's on a shared one",
       ctx do
    test_pid = self()
    stub(Provisioning, :write_runtime_config, fn _, _, _, _ -> :ok end)

    stub(Egress, :install_ca, fn _, _, _, owner ->
      send(test_pid, {:relay_owner, owner})
      :ok
    end)

    assert :ok = Reattachment.prepare_source(ctx.handle, ctx.state, ctx.conv, nil, [])
    assert_received {:relay_owner, owner}
    assert owner == ctx.conv.id

    sandbox = explicit_workspace!(Repo.get!(Fountain.Conversations.Sandbox, ctx.conv.sandbox_id))
    assert :ok = Reattachment.prepare_source(ctx.handle, ctx.state, ctx.conv, nil, [])
    assert_received {:relay_owner, owner}
    assert owner == sandbox.workspace_id
  end

  test "the wake's skills get the conversation's env, after the CA", ctx do
    test_pid = self()
    stub(Provisioning, :write_runtime_config, fn _, _, _, _ -> :ok end)
    stub(Egress, :install_ca, fn _, _, _, _ -> send(test_pid, :ca) && :ok end)

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
    stub(Egress, :install_ca, fn _, _, _, _ -> {:error, {:broker, :ca_install_exit, 1, ""}} end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:broker, :ca_install_exit, 1, ""}} =
                 Reattachment.prepare_source(ctx.handle, ctx.state, ctx.conv, nil, [])
      end)

    assert log =~ "runtime config write on wake"
  end

  test "a failed env file write is the reattach's answer", ctx do
    stub(Provisioning, :write_runtime_config, fn _, _, _, _ -> :ok end)
    stub(Egress, :install_ca, fn _, _, _, _ -> :ok end)
    stub(Provisioning, :write_env_file, fn _, _ -> {:error, :disk_full} end)
    reject(&Provisioning.prepare_runtime_sprite/7)

    assert {:error, :disk_full} =
             Reattachment.prepare_source(ctx.handle, ctx.state, ctx.conv, nil, [])
  end

  describe "the runtime template (#2998)" do
    test "goes into a new config home before Managoat's files, beside the CA", ctx do
      test_pid = self()

      stub(ConfigHome, :seed, fn _handle, conv, _agent, mode ->
        send(test_pid, {:seed, conv.id, mode, self()})
        receive do: (:go -> :ok)
      end)

      stub(Provisioning, :write_runtime_config, fn _, _, _, _ ->
        send(test_pid, :config)
        :ok
      end)

      stub(Provisioning, :write_instructions, fn _, _, _, _ ->
        send(test_pid, :instructions)
        :ok
      end)

      stub(Egress, :install_ca, fn _, _, _, _ ->
        send(test_pid, :ca)
        :ok
      end)

      task =
        Task.async(fn ->
          Reattachment.prepare_source(ctx.handle, ctx.state, ctx.conv, nil, [])
        end)

      conv_id = ctx.conv.id
      assert_receive {:seed, ^conv_id, :new, seed}, @receive_timeout
      # The CA does not wait for it; Managoat's files in the home do.
      assert_receive :ca, @receive_timeout
      refute_received :config
      refute_received :instructions
      send(seed, :go)

      assert Task.await(task) == :ok
      assert_received :config
      assert_received :instructions
    end

    test "a conversation with a runtime session on the machine has its home: no check", ctx do
      reject(&ConfigHome.seed/4)
      stub(Provisioning, :write_runtime_config, fn _, _, _, _ -> :ok end)
      stub(Egress, :install_ca, fn _, _, _, _ -> :ok end)
      state = Map.put(ctx.state, :runtime_session_id, "sess-1")

      assert :ok = Reattachment.prepare_source(ctx.handle, state, ctx.conv, nil, [])
    end

    test "a template that cannot be copied refuses the reattach", ctx do
      stub(ConfigHome, :seed, fn _, _, _, :new ->
        {:error, {:runtime_template, {:not_a_json_object, "settings.json"}}}
      end)

      stub(Egress, :install_ca, fn _, _, _, _ -> :ok end)
      reject(&Provisioning.write_runtime_config/4)
      reject(&Provisioning.prepare_runtime_sprite/7)

      assert {:error, {:runtime_template, {:not_a_json_object, "settings.json"}}} =
               Reattachment.prepare_source(ctx.handle, ctx.state, ctx.conv, nil, [])
    end
  end

  describe "ConfigHome.seed/4" do
    test "a legacy home and a runtime with no template are never seeded", ctx do
      reject(&Managoat.Runtimes.Template.seed/5)
      assert is_nil(ctx.conv.config_home)
      assert :ok = ConfigHome.seed(ctx.handle, ctx.conv, nil, :new)

      acp = %{
        ctx.conv
        | config_home: Managoat.Runtimes.Layout.config_home(ctx.conv.id),
          runtime: "acp"
      }

      assert :ok = ConfigHome.seed(ctx.handle, acp, nil, :new)
    end

    test "a conversation's own home is seeded, with the skills Managoat writes named", ctx do
      home = Managoat.Runtimes.Layout.config_home(ctx.conv.id)
      conv = %{ctx.conv | config_home: home, runtime: "codex"}
      agent = %{skills: [%{"name" => "mine", "content" => "x"}, %{"source" => "o/r"}]}
      test_pid = self()

      stub(Managoat.Runtimes.Template, :seed, fn _h, runtime, ^home, mode, opts ->
        send(test_pid, {:seeded, runtime, mode, opts[:skills]})
        :ok
      end)

      assert :ok = ConfigHome.seed(ctx.handle, conv, agent, :into)
      assert_received {:seeded, "codex", :into, ["managoat", "mine"]}
    end
  end
end
