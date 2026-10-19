defmodule Fountain.Workspaces.Network do
  @moduledoc """
  The network an explicit workspace's machine is set up under before any
  conversation exists (ADR 0097, step 5; ADR 0019).

  A conversation's provision applies the broker's network floor, installs the
  broker CA and starts the transport relay with its own broker session
  (`Fountain.Conversations.Egress`). A workspace provisioned on create has no
  conversation yet, so its machine-level steps (packages, repositories, the
  setup script) run under this instead:

    * **The floor and the CA are the machine's.** `allow: [broker]` and the
      broker root in the OS trust store are properties of the machine, not of
      whoever applied them, and are idempotent: every conversation that later
      attaches applies them again (`Egress.reattach_policy/2`,
      `Egress.install_ca/4`), on a wake and after a rebuild alike, so they
      hold on whatever machine the workspace currently has.
    * **The transport relay belongs to the workspace.** It holds no token, and
      it refuses a second owner, so on an explicit workspace's machine it is
      owned by the workspace (`Fountain.Workspaces.relay_owner/2`) and every
      conversation there shares it.
    * **The setup's broker session belongs to the workspace.** Its rules are
      the workspace's own environment and vault, split by the account's
      bindings exactly as a conversation's are (`Fountain.Broker.split/2`), and
      the network shape is the environment's (`Fountain.Broker.network_for/1`).
      It carries no inference credential and no connection token: nothing in
      a setup runs an agent. It is minted when the setup starts and released
      when it ends, whatever the outcome (`release/1`); deleting the workspace
      cascades it, and `Fountain.Workers.BrokerReaper` sweeps one past its TTL.
      A secret written while it is live rewrites its rules in place
      (`refresh_live/3`, #2548).

  Each conversation that attaches afterwards still mints its own session, with
  its own token in its own process environment. Inside a workspace those
  tokens are readable by every process on the machine, which ADR 0097's "one
  trust boundary" accepts; the placeholders hold, because the floor admits
  only the broker.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Fountain.Broker
  alias Fountain.Broker.Native.Sessions
  alias Fountain.Broker.TransportRelay
  alias Fountain.Conversations.Provisioning
  alias Fountain.Conversations.SpriteEnv
  alias Fountain.Environments
  alias Fountain.Repo
  alias Fountain.Vaults
  alias Fountain.Workspaces.Workspace

  @enforce_keys [:workspace_id, :user_id]
  defstruct [
    :workspace_id,
    :user_id,
    brokered: %{},
    bindings: %{},
    network: :unrestricted,
    session: nil
  ]

  @typedoc """
  What the setup's broker session is minted from: the brokered values of the
  workspace's environment and vault, the account's bindings, the
  environment's network shape, and, once `establish/2` has run, the session.
  """
  @type t :: %__MODULE__{
          workspace_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          brokered: %{String.t() => String.t()},
          bindings: Broker.bindings(),
          network: Broker.network(),
          session: Broker.session() | nil
        }

  @typedoc """
  What a setup is built from, read from the workspace's rows: the
  environment and vault (`nil` for none), the sandbox-side secrets (each
  brokered value already a placeholder), the environment's plain variables,
  and the network to set it up under.
  """
  @type inputs :: %{
          environment: Environments.Environment.t() | nil,
          vault: Vaults.Vault.t() | nil,
          secrets: %{String.t() => String.t()},
          plain: %{String.t() => String.t()},
          network: t()
        }

  @doc """
  Read what `workspace`'s setup is built from. Every read is scoped by the
  workspace's owner: a workspace row whose environment or vault has gone (or
  was never the owner's) contributes nothing, as a conversation's provision
  treats one.
  """
  @spec inputs(Workspace.t()) :: {:ok, inputs()} | {:error, term()}
  def inputs(%Workspace{user_id: user_id} = workspace) when is_binary(user_id) do
    env =
      workspace.environment_id && Environments.get_environment(workspace.environment_id, user_id)

    vault = workspace.vault_id && Vaults.get_vault(workspace.vault_id, user_id)

    with {:ok, dek} <- Fountain.Crypto.load_tenant_key(user_id) do
      bindings = Fountain.SecretBindings.enabled_by_key(user_id)
      {secrets, brokered} = Broker.split(SpriteEnv.merge_secrets(env, vault, dek), bindings)

      {:ok,
       %{
         environment: env,
         vault: vault,
         secrets: secrets,
         plain: plain_vars(env),
         network: %__MODULE__{
           workspace_id: workspace.id,
           user_id: user_id,
           brokered: brokered,
           bindings: bindings,
           network: Broker.network_for(env)
         }
       }}
    end
  end

  def inputs(%Workspace{}), do: {:error, :workspace_ownerless}

  defp plain_vars(nil), do: %{}

  defp plain_vars(env),
    do: Map.new(env.env_vars || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

  @doc """
  The process env a workspace's setup runs under, before the network's
  variables: the git author, the environment's plain variables and the
  secrets. `Fountain.Machines.Setup.pipeline/2` puts the broker's CA
  defaults in front (overridable, as for a conversation) and the proxy
  variables last, which nothing overrides, as `SpriteEnv.build/4` orders
  them. No callback key, no conversation id, no runtime or config home: no
  agent runs in a setup.
  """
  @spec setup_env(inputs()) :: [{String.t(), String.t()}]
  def setup_env(%{plain: plain, secrets: secrets}) do
    SpriteEnv.git_author_env() ++ Enum.to_list(plain) ++ Enum.to_list(secrets)
  end

  @doc """
  Settle the machine behind `handle` for a setup: refuse a provider or a
  broker that cannot enforce the floor, mint the workspace's session, install
  the broker CA, start the relay as the workspace's, and apply the floor, in
  that order, before anything dials out. Answers the network with its
  session, the CA defaults and the proxy variables to run under; on a
  failure the session minted here is released before the error returns.
  Publishes nothing: there is no conversation to publish to.
  """
  @spec establish(t(), Managoat.Sandbox.Handle.t()) ::
          {:ok, t(), [{String.t(), String.t()}], [{String.t(), String.t()}]} | {:error, term()}
  def establish(%__MODULE__{} = net, handle) do
    with :ok <- Provisioning.check_broker_support(handle.provider, nil),
         {:ok, session} <-
           Broker.prepare_workspace(net.workspace_id, net.brokered, net.bindings,
             network: net.network,
             user_id: net.user_id
           ) do
      net = %{net | session: session}

      case trust_and_floor(handle, net) do
        :ok ->
          {:ok, net, Broker.ca_env(Broker.system_ca_files()), Broker.proxy_env(session)}

        {:error, _} = error ->
          release(net)
          error
      end
    end
  end

  # The CA and the relay first, then the floor, as a conversation's provision
  # orders them (`FreshProvision`): neither dials anywhere the floor would
  # refuse, and every step after the floor needs both.
  defp trust_and_floor(handle, net) do
    with :ok <- Provisioning.install_broker_ca(handle, nil),
         :ok <- TransportRelay.ensure(handle, net.workspace_id) do
      Provisioning.apply_broker_floor(handle, nil)
    end
  end

  @doc "Release the workspace's setup session, if it has one. Idempotent."
  @spec release(t() | Ecto.UUID.t()) :: :ok
  def release(%__MODULE__{workspace_id: workspace_id}), do: release(workspace_id)

  def release(workspace_id) when is_binary(workspace_id),
    do: Broker.release_workspace(workspace_id)

  @doc """
  The secret values a setup's failure must not carry back out: the session's
  token, which stands in the proxy variables a step's output may print.
  """
  @spec secrets(t()) :: [String.t()]
  def secrets(%__MODULE__{session: %{token: token}}) when is_binary(token), do: [token]
  def secrets(%__MODULE__{}), do: []

  @doc """
  A secret was written to `kind`'s `source_id` (#2548): rewrite the rules of
  every live setup session of `user_id`'s workspaces that name it, in place,
  so a setup already running reaches the new value on its next tunnel. Best
  effort and off the caller's path; a workspace with no live session (the
  ordinary case, once its setup has finished) is not touched, because each
  conversation that attaches re-reads the rows for its own session.
  """
  @spec refresh_live(:vault | :environment, Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def refresh_live(kind, source_id, user_id) do
    ids =
      from(w in Workspace,
        where: w.user_id == ^user_id and not w.implicit,
        select: w.id
      )
      |> on_source(kind, source_id)
      |> Repo.all()
      |> Sessions.live_workspace_ids()

    if ids != [] do
      _ =
        Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
          Enum.each(ids, &refresh_one(&1, user_id))
        end)
    end

    :ok
  end

  defp on_source(query, :vault, id), do: from(w in query, where: w.vault_id == ^id)
  defp on_source(query, :environment, id), do: from(w in query, where: w.environment_id == ^id)

  defp refresh_one(workspace_id, user_id) do
    with %Workspace{} = workspace <-
           Repo.one(from(w in Workspace, where: w.id == ^workspace_id and w.user_id == ^user_id)),
         {:ok, %{network: net}} <- inputs(workspace),
         {:ok, n} when n > 0 <-
           Broker.refresh_workspace(workspace_id, net.brokered, net.bindings,
             network: net.network,
             user_id: user_id
           ) do
      Logger.info("workspace #{workspace_id}: a secret write reached its setup's broker rules")
    else
      other ->
        Logger.info(
          "workspace #{workspace_id}: setup broker rules not rewritten: #{inspect(other)}"
        )
    end

    :ok
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "workspace #{workspace_id}: setup broker refresh failed: #{Exception.message(error)}"
      )

      :ok
  end
end
