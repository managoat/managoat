defmodule Fountain.Machines.Setup do
  @moduledoc """
  The machine-level steps of a provision: the ones that build the disk from
  the environment, as opposed to the ones that attach a conversation to it
  (ADR 0097, "An explicit workspace is provisioned on create").

  Those steps are the environment's packages, its repositories and its setup
  script, run in that order against the machine's process env. `run/2` is
  the one implementation of them: a conversation's own provision runs them
  through it (`Fountain.Conversations.FreshProvision`), after the
  conversation's network floor and broker CA are in place, and so can a
  machine's owner with no conversation at all, through `pipeline/1` and
  `Fountain.Machines.Machine.set_up/3`.

  **This is a seam, not a feature** (ADR 0097, step 3c). Nothing in this
  release provisions a machine without a conversation; step 5's explicit
  workspaces will, when a workspace is created. What step 5 still has to
  decide is the network a conversation-less setup runs under: today the
  floor and the broker CA are applied per conversation, with the
  conversation's broker session (`Fountain.Conversations.Egress`), and a
  `Setup` run without one runs on whatever network the caller has already
  given the machine, with the `sprite_env` the caller hands it.

  With no `conversation_id` the steps publish no stage events and write no
  output to a transcript, because there is no conversation to write them to;
  a failure still quotes the end of what the step printed.
  """

  alias Fountain.Conversations.Provisioning

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
  `run/2` as a `Fountain.Machines.Provision` pipeline: what an owner runs
  between the create and the `ready` finalize to build a machine with no
  conversation on it (`Fountain.Machines.Machine.set_up/3`). A failure is
  `{:error, reason, %{}}`: there is no conversation state to unwind.
  """
  @spec pipeline(t()) :: Fountain.Machines.Provision.pipeline()
  def pipeline(%__MODULE__{} = setup) do
    fn handle, _epoch ->
      case run(handle, setup) do
        :ok -> {:ok, :set_up}
        {:error, reason} -> {:error, reason, %{}}
      end
    end
  end

  defp maybe_write_env_file(_handle, %__MODULE__{write_env_file?: false}), do: :ok

  defp maybe_write_env_file(handle, %__MODULE__{sprite_env: sprite_env}),
    do: Provisioning.write_env_file(handle, Fountain.Conversations.Identity.disk_env(sprite_env))
end
