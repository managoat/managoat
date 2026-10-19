defmodule Managoat.SandboxTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Managoat.Sandbox
  alias Managoat.Sandbox.Command
  alias Managoat.Sandbox.Handle
  alias Managoat.Sandbox.NetworkPolicy

  @name "fountain-abc12345-deadbeef"

  describe "provider resolution" do
    test "the two shipped adapters are registered by provider atom" do
      assert Sandbox.adapters() == %{
               sprites: Managoat.Sandbox.Sprites,
               e2b: Managoat.Sandbox.E2B
             }

      assert Sandbox.adapter_for(:sprites) == Managoat.Sandbox.Sprites
    end

    test "an unconfigured provider raises with the configured set named" do
      assert_raise ArgumentError, ~r/unknown sandbox provider :modal/, fn ->
        Sandbox.adapter_for(:modal)
      end
    end

    test "supports? consults the adapter's capability set" do
      assert Sandbox.supports?(:sprites, :network_policy)
      assert Sandbox.supports?(:sprites, :suspend)

      handle = %Handle{provider: :sprites, name: @name}
      assert Sandbox.supports?(handle, :attach)
    end

    test "command inspection exposes correlation data without adapter-private state" do
      command = %Command{provider: :sprites, ref: :turn_ref, private: %{token: "secret"}}
      inspected = inspect(command)

      assert inspected =~ "provider: :sprites"
      assert inspected =~ "ref: :turn_ref"
      refute inspected =~ "secret"
    end
  end

  describe "dispatch" do
    test "creation-side operations dispatch on the provider atom" do
      expect(Managoat.Sandbox.Sprites, :create, fn @name, [] ->
        {:ok, %Handle{provider: :sprites, name: @name}}
      end)

      assert {:ok, %Handle{name: @name}} = Sandbox.create(:sprites, @name)
    end

    test "handle-taking operations dispatch on the handle's provider tag" do
      handle = %Handle{provider: :sprites, name: @name}

      expect(Managoat.Sandbox.Sprites, :get, fn ^handle ->
        {:ok, %{status: :running, raw: %{}}}
      end)

      assert {:ok, %{status: :running}} = Sandbox.get(handle)
    end

    test "command-taking operations dispatch on the command's provider tag" do
      command = %Command{provider: :sprites, ref: make_ref()}

      expect(Managoat.Sandbox.Sprites, :write_stdin, fn ^command, "data" -> :ok end)
      assert :ok = Sandbox.write_stdin(command, "data")
    end

    test "build_handle is pure and provider-tagged" do
      assert %Handle{provider: :sprites, name: @name, private: nil} =
               Sandbox.build_handle(:sprites, @name)
    end
  end

  describe "complete facade dispatch through configured adapters" do
    setup do
      previous = Application.get_env(:fountain, :sandbox_adapters)

      Application.put_env(
        :fountain,
        :sandbox_adapters,
        Map.new([:sprites, :e2b], &{&1, Managoat.Sandbox.Fake})
      )

      Managoat.Sandbox.Fake.reset()

      on_exit(fn ->
        if previous do
          Application.put_env(:fountain, :sandbox_adapters, previous)
        else
          Application.delete_env(:fountain, :sandbox_adapters)
        end
      end)

      :ok
    end

    for provider <- [:sprites, :e2b] do
      @provider provider

      test "every operation dispatches through the fake registered for #{@provider}" do
        provider = @provider
        name = @name <> "-#{provider}"

        assert Sandbox.adapter_for(provider) == Managoat.Sandbox.Fake
        assert Sandbox.supports?(provider, :suspend)
        assert %Handle{provider: :fake, name: ^name} = Sandbox.build_handle(provider, name)
        assert {:ok, %Handle{provider: :fake, name: ^name}} = Sandbox.create(provider, name)
        assert {:ok, names} = Sandbox.list_all_names(provider)
        assert MapSet.member?(names, name)

        # The caller's provider tag, not private adapter state, selects the adapter.
        handle = %Handle{provider: provider, name: name}
        assert Sandbox.supports?(handle, :network_policy)
        assert {:ok, %{status: :running}} = Sandbox.get(handle)
        expected_url = "https://#{name}.fake.test"
        assert {:ok, ^expected_url} = Sandbox.public_url(handle)
        assert :ok = Sandbox.suspend(handle)
        assert {:ok, %{status: :suspended}} = Sandbox.get(handle)
        assert {:ok, %Handle{name: ^name}} = Sandbox.resume(handle)

        assert :ok = Sandbox.write_file(handle, "/tmp/example", ["hel", "lo"], mode: 0o600)
        assert Managoat.Sandbox.Fake.file(name, "/tmp/example") == "hello"

        assert {:ok, "outerr", 4} =
                 Sandbox.exec(handle, "script", ["out:out", "err:err", "exit:4"],
                   stderr_to_stdout: true
                 )

        assert {:ok, spawned} = Sandbox.spawn(handle, "script", ["stay"], owner: self())
        command = %{spawned | provider: provider}
        spawned_ref = spawned.ref
        assert :ok = Sandbox.write_stdin(command, ["in", "put"])
        assert_receive {:stdout, %{ref: ^spawned_ref}, "echo:input"}
        assert :ok = Sandbox.close_stdin(command)
        assert_receive {:exit, %{ref: ^spawned_ref}, 0}
        assert :ok = Sandbox.stop_command(command)

        assert {:ok, detachable} = Sandbox.spawn(handle, "runner", ["stay"], owner: self())
        assert {:ok, sessions} = Sandbox.list_sessions(handle)
        assert session = Enum.find(sessions, &(&1.command == "runner stay"))
        assert {:ok, attached} = Sandbox.attach(handle, session.id, owner: self())
        assert attached.ref != detachable.ref
        detachable_ref = detachable.ref
        attached_ref = attached.ref
        assert :ok = Sandbox.close_stdin(%{detachable | provider: provider})
        assert_receive {:exit, %{ref: ^detachable_ref}, 0}
        assert_receive {:exit, %{ref: ^attached_ref}, 0}

        policy = %NetworkPolicy{allow: ["hex.pm"]}
        assert :ok = Sandbox.apply_network_policy(handle, policy)
        assert Managoat.Sandbox.Fake.policy(name) == policy

        # An adapter that cannot read its policy back is always written.
        widened = %NetworkPolicy{allow: ["hex.pm", "pypi.org"]}
        assert {:ok, :written} = Sandbox.ensure_network_policy(handle, widened)
        assert Managoat.Sandbox.Fake.policy(name) == widened
        assert Sandbox.host_path(handle, "/home/sprite") == "/home/sprite"

        assert :ok = Sandbox.destroy(handle)
        assert {:error, :not_found} = Sandbox.get(handle)
      end
    end

    test "all provider-tagged entry points reject an unknown provider" do
      handle = %Handle{provider: :unknown, name: @name}
      command = %Command{provider: :unknown, ref: make_ref()}
      policy = %NetworkPolicy{allow: []}

      calls = [
        fn -> Sandbox.supports?(:unknown, :suspend) end,
        fn -> Sandbox.supports?(handle, :suspend) end,
        fn -> Sandbox.build_handle(:unknown, @name) end,
        fn -> Sandbox.create(:unknown, @name) end,
        fn -> Sandbox.list_all_names(:unknown) end,
        fn -> Sandbox.get(handle) end,
        fn -> Sandbox.destroy(handle) end,
        fn -> Sandbox.public_url(handle) end,
        fn -> Sandbox.suspend(handle) end,
        fn -> Sandbox.resume(handle) end,
        fn -> Sandbox.write_file(handle, "/tmp/x", "x") end,
        fn -> Sandbox.exec(handle, "true", []) end,
        fn -> Sandbox.spawn(handle, "true", []) end,
        fn -> Sandbox.write_stdin(command, "x") end,
        fn -> Sandbox.close_stdin(command) end,
        fn -> Sandbox.stop_command(command) end,
        fn -> Sandbox.list_sessions(handle) end,
        fn -> Sandbox.attach(handle, "session") end,
        fn -> Sandbox.apply_network_policy(handle, policy) end,
        fn -> Sandbox.ensure_network_policy(handle, policy) end,
        fn -> Sandbox.host_path(handle, "/tmp/x") end
      ]

      for call <- calls do
        assert_raise ArgumentError, ~r/unknown sandbox provider :unknown/, call
      end
    end
  end
end
