defmodule Managoat.Runtimes.Testing.FakeRuntime do
  @moduledoc """
  A `Managoat.Runtimes` implementation for tests.

  A host that takes its runtime module as a start argument (Fountain's
  conversation server does) can run its whole turn machinery against this
  instead of stubbing four real runtime modules to test behaviour that has
  nothing to do with which CLI is being driven.

  Every callback records itself to an observer process so a test can assert
  what the host asked the runtime to do. The observer is registered with
  `observe/1` — the callbacks run in the host's process, not the test's, so
  `self()` there is the wrong pid to report to.

  Test-only (`test/support`), like the sandbox fake and the scripted ACP
  agent.
  """

  @behaviour Managoat.Runtimes

  @app :fountain
  @key :fake_runtime_observer

  @doc "Register `pid` as the process every callback reports to."
  @spec observe(pid()) :: :ok
  def observe(pid) when is_pid(pid), do: Application.put_env(@app, @key, pid)

  @doc "Where callbacks report to, or nil when no test has called `observe/1`."
  @spec observer() :: pid() | nil
  def observer, do: Application.get_env(@app, @key)

  defp report(msg) do
    if pid = observer(), do: send(pid, msg)
    :ok
  end

  @impl true
  def default_env(_agent, _credentials), do: [{"FAKE_RUNTIME", "1"}]

  @impl true
  def write_config(_sprite, _agent, _home), do: report(:write_config)

  @impl true
  def prepare_sandbox(_sprite, _agent, _sprite_env, _home), do: report(:prepare_sandbox)

  @impl true
  def skills_root(home), do: Path.join(home, "fake-skills")
end

defmodule Managoat.Runtimes.Testing.FailingRuntime do
  @moduledoc """
  A runtime whose `prepare_sandbox/4` fails, for exercising a host's
  provisioning failure path without having to make a sandbox call fail.
  """

  @behaviour Managoat.Runtimes

  @impl true
  def default_env(_agent, _credentials), do: []

  @impl true
  def write_config(_sprite, _agent, _home), do: :ok

  @impl true
  def prepare_sandbox(_sprite, _agent, _sprite_env, _home), do: {:error, :prepare_failed}

  @impl true
  def skills_root(home), do: Path.join(home, "fake-skills")
end

defmodule Managoat.Runtimes.Testing.ConfigFailingRuntime do
  @moduledoc """
  A runtime whose `write_config/3` fails: the sandbox never took the runtime's
  config file. A host's provisioning must treat that as a failure rather than
  run the agent without its MCP servers.
  """

  @behaviour Managoat.Runtimes

  @impl true
  def default_env(_agent, _credentials), do: []

  @impl true
  def write_config(_sprite, _agent, _home),
    do: {:error, {:runtime_config, "/x/.mcp.json", :timeout}}

  @impl true
  def prepare_sandbox(_sprite, _agent, _sprite_env, _home), do: :ok

  @impl true
  def skills_root(home), do: Path.join(home, "fake-skills")
end
