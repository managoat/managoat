defmodule Fountain.CommandRuntimeTest do
  @moduledoc """
  The `acp` runtime and the host dispatch that resolves it (#1634).

  Nothing reaches this module yet: `"acp"` is not a value `Agent.changeset/2`
  accepts, and the `runtime_command` column it reads does not exist. What is
  pinned here is the runtime in isolation, so the PR that opens the door has
  only the schema to argue about.
  """

  use ExUnit.Case, async: true

  alias Fountain.CommandRuntime
  alias Fountain.RuntimeDispatch

  describe "dispatch" do
    test "acp resolves to the command runtime" do
      assert {:ok, CommandRuntime} = RuntimeDispatch.for_agent(%{runtime: "acp"})
    end

    test "the packaged runtimes still resolve to their own modules" do
      assert {:ok, Managoat.Runtimes.Claude} = RuntimeDispatch.for_agent(%{runtime: "claude"})
      assert {:error, _} = RuntimeDispatch.for_agent(%{runtime: "nonesuch"})
    end

    test "there is no adapter to install and no model to pin" do
      assert :ok = RuntimeDispatch.install(nil, "acp", [])
      assert :ok = RuntimeDispatch.ensure_installed(nil, "acp", [])
      assert is_nil(RuntimeDispatch.acp_model("acp", nil))
      # Even when a model was set anyway: it is inert, so it is never pinned
      # and the pin path that reports `model`/`failed` is unreachable.
      assert is_nil(RuntimeDispatch.acp_model("acp", "anthropic/claude-sonnet-4-6"))
    end

    test "a model-driven runtime still pins the model it was given" do
      assert RuntimeDispatch.acp_model("claude", "anthropic/claude-sonnet-4-6")
    end

    test "only acp takes a command, and only acp goes without a model" do
      assert RuntimeDispatch.command_required?("acp")
      refute RuntimeDispatch.model_required?("acp")

      for runtime <- ~w(claude codex gemini) do
        refute RuntimeDispatch.command_required?(runtime)
        assert RuntimeDispatch.model_required?(runtime)
      end
    end
  end

  describe "argv" do
    test "the command comes from the agent, and a missing one is answerable" do
      assert :error = CommandRuntime.argv(nil)
      assert :error = CommandRuntime.argv(%{})
      assert :error = CommandRuntime.argv(%{runtime_command: nil})
      assert :error = CommandRuntime.argv(%{runtime_command: "   "})

      assert {:ok, {"bash", ["-lc", "run me"]}} =
               CommandRuntime.argv(%{runtime_command: "run me"})
    end

    test "a whole shell line is handed to the login shell unparsed" do
      line = "cd /srv/app && exec ./bin/agent acp --env prod"

      assert {"bash", ["-lc", ^line]} =
               RuntimeDispatch.command("acp", %{runtime_command: line})
    end

    test "the packaged runtimes ignore the agent and resolve their own argv" do
      assert {_cmd, _args} = RuntimeDispatch.command("claude", %{runtime_command: "ignored"})
    end
  end

  describe "the sandbox environment" do
    test "no inference credential reaches the command" do
      env =
        CommandRuntime.default_env(
          %{model: "anthropic/claude-sonnet-4-6"},
          %{anthropic_api_key: "sk-live", openai_api_key: "sk-openai"}
        )

      refute Enum.any?(env, fn {_k, v} -> v =~ "sk-" end)
      assert env == []
    end

    test "skills land in claude-code's tree under the conversation's config home, exported" do
      home = "/home/sprite/.managoat/c/1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f"
      assert CommandRuntime.skills_root(home) == home <> "/skills"
      assert CommandRuntime.config_env(home) == [{"MANAGOAT_SKILLS_DIR", home <> "/skills"}]

      # A conversation from before config homes keeps the tree it had.
      legacy = Fountain.Conversations.ConfigHome.legacy_home("acp")
      assert CommandRuntime.skills_root(legacy) == "/home/sprite/.claude/skills"
    end

    test "provisioning finds nothing to write and nothing to prepare" do
      refute function_exported?(CommandRuntime, :write_config, 3)
      refute function_exported?(CommandRuntime, :prepare_sandbox, 4)
    end
  end
end
