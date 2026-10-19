defmodule Fountain.Machines.Setup do
  @moduledoc """
  The machine-level steps of a provision: the ones that build the disk from
  the environment, as opposed to the ones that attach a conversation to it
  (ADR 0097, "An explicit workspace is provisioned on create").

  Those steps are the environment's packages, its repositories and its setup
  script, run in that order against the machine's process env. `run/2` is
  the one implementation of them: a conversation's own provision runs them
  through it (`Fountain.Conversations.FreshProvision`), after the
  conversation's network floor and broker CA are in place, and so does a
  machine's owner with no conversation at all, through `pipeline/2` and
  `Fountain.Machines.Machine.set_up/3`.

  **A setup with no conversation runs under the workspace's network**
  (`Fountain.Workspaces.Network`, ADR 0097 step 5): `pipeline/2` settles the
  machine first (the broker's floor, its CA, the workspace's relay, and a
  broker session owned by the workspace), runs the steps under the proxy and
  CA variables that gives it, and releases the session when they end,
  whatever the outcome. `set_up/3` refuses a setup that names no network.
  `Fountain.Workspaces.Provisioner` is the caller, when an explicit workspace
  is created.

  With no `conversation_id` the steps publish no stage events and write no
  output to a transcript, because there is no conversation to write them to;
  a failure still quotes the end of what the step printed, with the setup
  session's token taken out (`scrub/2`).
  """

  alias Fountain.Conversations.Provisioning
  alias Fountain.Workspaces.Network

  @enforce_keys [:environment, :sprite_env]
  defstruct [
    :environment,
    :sprite_env,
    secrets: %{},
    conversation_id: nil,
    write_env_file?: false
  ]

  @typedoc """
  What the machine is built from: the environment (`nil` for none), the
  process env every step runs under, the decrypted secrets a clone's token
  is taken from, and the conversation whose transcript gets the stages and
  output, or `nil`. `write_env_file?` also writes the env file first, which a
  conversation's provision does itself beside its other config writes.

  For `pipeline/2`, `sprite_env` is the env without the network's variables,
  which the pipeline adds once the network is settled.
  """
  @type t :: %__MODULE__{
          environment: Fountain.Environments.Environment.t() | nil,
          sprite_env: [{String.t(), String.t()}],
          secrets: map(),
          conversation_id: Ecto.UUID.t() | nil,
          write_env_file?: boolean()
        }

  @doc """
  Run the machine-level steps on `handle`, in order, stopping at the first
  that fails. Answers `:ok` or the failing step's `{:error, reason}`.
  """
  @spec run(Managoat.Sandbox.Handle.t(), t()) :: :ok | {:error, term()}
  def run(handle, %__MODULE__{} = setup) do
    %{environment: env, sprite_env: sprite_env, secrets: secrets, conversation_id: conv_id} =
      setup

    with :ok <- maybe_write_env_file(handle, setup),
         :ok <- Provisioning.install_packages(handle, env, sprite_env, conv_id),
         :ok <- Provisioning.clone_repositories(handle, env, secrets, sprite_env, conv_id) do
      Provisioning.run_setup_script(handle, env, sprite_env, conv_id)
    end
  end

  @doc """
  `run/2` as a `Fountain.Machines.Provision` pipeline under `network`: what
  an owner runs between the create and the `ready` finalize to build a
  machine with no conversation on it (`Fountain.Machines.Machine.set_up/3`).

  `Network.establish/2` comes first; the steps then run with the CA
  defaults ahead of `setup.sprite_env` and the proxy variables after it, as
  `SpriteEnv.build/4` orders them for a conversation. The session is
  released when the steps end. A failure is `{:error, reason, %{}}`, with
  the session's token scrubbed out of the reason: there is no conversation
  state to unwind.
  """
  @spec pipeline(t(), Network.t()) :: Fountain.Machines.Provision.pipeline()
  def pipeline(%__MODULE__{} = setup, %Network{} = network) do
    fn handle, _epoch ->
      case Network.establish(network, handle) do
        {:ok, settled, ca_env, proxy_env} ->
          try do
            setup = %{setup | sprite_env: ca_env ++ setup.sprite_env ++ proxy_env}

            case run(handle, setup) do
              :ok -> {:ok, :set_up}
              {:error, reason} -> {:error, scrub(reason, Network.secrets(settled)), %{}}
            end
          after
            Network.release(settled)
          end

        {:error, reason} ->
          {:error, reason, %{}}
      end
    end
  end

  @doc """
  `term` with every occurrence of each of `values` replaced in the strings
  it carries (a step's failure quotes the tail of what it printed, and a
  package script that prints its environment prints the proxy URL with the
  session's token in it).
  """
  @spec scrub(term(), [String.t()]) :: term()
  def scrub(term, []), do: term

  def scrub(term, values) when is_binary(term),
    do: :binary.replace(term, values, Fountain.Conversations.Redaction.placeholder(), [:global])

  def scrub(term, values) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&scrub(&1, values)) |> List.to_tuple()

  def scrub(term, values) when is_list(term), do: Enum.map(term, &scrub(&1, values))
  def scrub(term, _values), do: term

  defp maybe_write_env_file(_handle, %__MODULE__{write_env_file?: false}), do: :ok

  defp maybe_write_env_file(handle, %__MODULE__{sprite_env: sprite_env}),
    do: Provisioning.write_env_file(handle, Fountain.Conversations.Identity.disk_env(sprite_env))
end
