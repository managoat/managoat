defmodule Fountain.SandboxProviders do
  @moduledoc """
  Which sandbox providers this deployment can name, and which it can use.

  `Managoat.Sandbox` (lib/managoat/sandbox, decisions/0037) answers only
  "which module serves this provider atom", through its adapter map.
  Everything here is deployment policy layered on that, and it reads
  Fountain's configuration, which is why it lives here rather than in
  `Managoat.Sandbox`:

    * `known_providers/0` — the closed vocabulary the schemas validate
      against (`Agents.Agent`, `Conversations.Sandbox`). Knowing a provider
      is not the same as having it configured.
    * `default_provider/0` — `SANDBOX_PROVIDER`, validated at boot in
      `config/runtime.exs`.
    * `enabled?/1` / `enabled_providers/0` — whether a provider is usable on
      this instance: its adapter is registered **and** its credential is
      configured. Enabledness is runtime state — the schema validates
      against `known_providers/0`, selection validates against this.
  """

  alias Managoat.Sandbox

  @known ~w(sprites e2b)

  @doc "The closed vocabulary of providers Fountain knows how to name."
  @spec known_providers() :: [String.t()]
  def known_providers, do: @known

  @doc "The instance-default provider (`SANDBOX_PROVIDER`; validated at boot)."
  @spec default_provider() :: Sandbox.provider()
  def default_provider do
    Application.get_env(:fountain, :sandbox_default_provider, :sprites)
  end

  @doc "Whether a provider is usable on this instance."
  @spec enabled?(Sandbox.provider()) :: boolean()
  def enabled?(provider) when is_atom(provider) do
    Map.has_key?(Sandbox.adapters(), provider) and credential_present?(provider)
  end

  @doc """
  What `sandbox_provider_disabled` tells its caller to do, by whose provider
  it is, so the advice names the thing the caller can change:

    * `:agent` — a new sandbox placed on the agent's `sandbox_provider`
      override: set the provider's credentials, or clear the override.
    * `:workspace_create` — `POST /api/workspaces` naming the provider: set
      its credentials, or create the workspace on another provider or the
      instance default.
    * `:workspace` — a conversation waking in an explicit workspace, which
      fixes its provider at create (ADR 0097): the agent's override is not
      read there, so the advice is the workspace's, as at create.
    * `:sandbox` — a conversation waking on its own parked sandbox, whose
      disk is on the provider: only the provider's credentials wake it.
  """
  @spec disabled_message(Sandbox.provider(), :agent | :workspace_create | :workspace | :sandbox) ::
          String.t()
  def disabled_message(provider, :agent),
    do:
      "sandbox provider #{provider} is not configured on this instance — " <>
        "set its credentials or clear the agent's sandbox_provider override"

  def disabled_message(provider, :workspace_create),
    do:
      "sandbox provider #{provider} is not configured on this instance — set its " <>
        "credentials, or create the workspace with another sandbox_provider, or " <>
        "without one for the instance default"

  def disabled_message(provider, :workspace),
    do:
      "sandbox provider #{provider} is not configured on this instance, and this " <>
        "workspace runs on it — set its credentials, or create a workspace with " <>
        "another sandbox_provider, or without one for the instance default"

  def disabled_message(provider, :sandbox),
    do:
      "sandbox provider #{provider} is not configured on this instance, and this " <>
        "conversation's sandbox is parked on it — set its credentials to wake it"

  @doc "Every provider currently usable on this instance."
  @spec enabled_providers() :: [Sandbox.provider()]
  def enabled_providers do
    known_providers()
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.filter(&enabled?/1)
  end

  # The platform credentials live under the adapters' own keys
  # (`config :fountain, Managoat.Sandbox.Sprites, ...`), where
  # config/runtime.exs writes them from SPRITES_TOKEN / E2B_API_KEY.
  # "Is it set" is read back from there rather than kept in
  # a second :fountain key that could drift from what the adapter uses.
  defp credential_present?(:sprites), do: Sandbox.Config.get(Sandbox.Sprites, :token) != nil
  defp credential_present?(:e2b), do: Sandbox.Config.get(Sandbox.E2B, :api_key) != nil
  # Non-production adapters (the in-memory Fake) carry no credentials; being
  # registered in the adapter map is what enables them.
  defp credential_present?(_other), do: true
end
