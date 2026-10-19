defmodule Fountain.Conversations.PromptReceipt do
  @moduledoc """
  Durable evidence of an accepted prompt waiting for turn admission.

  Stores identifiers only, never prompt text or credentials. Admission deletes
  the receipt in the turn insert's transaction. A receipt left by an earlier
  boot therefore proves that no turn was admitted for this submission. Boot
  reports that outcome before serving requests; it never replays the prompt.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Fountain.Conversations
  alias Fountain.Conversations.Conversation
  alias Fountain.Machines.Lease
  alias Fountain.Repo

  require Logger

  # Acceptance to admission spans the wake and provisioning, whose setup
  # script alone may run 900 s (the environment cap): twice that, so a prompt
  # queued behind the slowest legitimate setup is still reported.
  @default_ttl_seconds 1800

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "prompt_receipts" do
    field :conversation_id, :binary_id
    field :boot_id, :string
    field :client_request_id, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "How old a receipt from an earlier boot may be and still be reported."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds,
    do: Application.get_env(:fountain, :prompt_receipt_ttl_seconds, @default_ttl_seconds)

  @doc "Register before acknowledging asynchronous acceptance, or carry an existing receipt."
  def accept(conversation_id, meta) do
    if meta[:prompt_receipt_id] do
      meta
    else
      receipt =
        Repo.insert!(%__MODULE__{
          conversation_id: conversation_id,
          boot_id: Lease.boot_id(),
          client_request_id: meta[:client_request_id]
        })

      Keyword.put(meta, :prompt_receipt_id, receipt.id)
    end
  end

  @doc "Resolve only this conversation's receipt; admission calls inside its transaction."
  def resolve(conversation_id, receipt_id) when is_binary(receipt_id) do
    Repo.delete_all(
      from r in __MODULE__, where: r.id == ^receipt_id and r.conversation_id == ^conversation_id
    )

    :ok
  end

  def resolve(_conversation_id, _receipt_id), do: :ok

  @doc "Whether this conversation's receipt is still waiting for a turn or a report."
  @spec pending?(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: boolean()
  def pending?(conversation_id, receipt_id) when is_binary(receipt_id) do
    Repo.exists?(
      from r in __MODULE__, where: r.id == ^receipt_id and r.conversation_id == ^conversation_id
    )
  end

  def pending?(_conversation_id, _receipt_id), do: false

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  @doc false
  def start_link(_opts) do
    unless Application.get_env(:fountain, :skip_rehydrate, false), do: recover()
    :ignore
  end

  @doc "Report submissions abandoned by a previous boot, before the endpoint starts."
  def recover do
    boot = Lease.boot_id()
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_seconds(), :second)

    expired =
      from(r in __MODULE__,
        join: c in Conversation,
        on: c.id == r.conversation_id,
        where: r.boot_id != ^boot,
        select: {r, c.status}
      )
      |> Repo.all()
      |> Enum.reduce(0, fn {receipt, status}, expired ->
        live? = status not in ["failed", "terminated"]
        fresh? = in_flight?(receipt, cutoff)

        if live? and fresh? do
          Conversations.publish_stage(receipt.conversation_id, "wake", "failed", %{
            reason: "deployment_interrupted",
            retryable: true,
            client_request_id: receipt.client_request_id,
            prompt_receipt_id: receipt.id
          })
        end

        resolve(receipt.conversation_id, receipt.id)
        if live? and not fresh?, do: expired + 1, else: expired
      end)

    if expired > 0,
      do: Logger.info("prompt receipts: dropped #{expired} expired without reporting them")

    :ok
  end

  # An ageless receipt predates the column and may be arbitrarily old.
  defp in_flight?(%__MODULE__{inserted_at: nil}, _cutoff), do: false

  defp in_flight?(%__MODULE__{inserted_at: inserted_at}, cutoff),
    do: DateTime.compare(inserted_at, cutoff) != :lt
end
