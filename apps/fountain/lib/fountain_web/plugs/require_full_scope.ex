defmodule FountainWeb.Plugs.RequireFullScope do
  @moduledoc """
  Restricts account-level writes to `full`-scoped API keys.

  Every conversation hands its sprite a tenant API key so the agent can stream,
  prompt, and spawn sub-agents. Those tokens are `sprite`-scoped and are
  deliberately weaker than the owner's own key: code running in a sandbox is
  untrusted by design, so it must not be able to change the account out from
  under the person who owns it — replace the tenant's inference credentials,
  rotate the password, delete the account — or rewrite what the next launch
  runs: an agent, an environment, a vault, a manifest apply (ADR 0039,
  amended 2026-10-14).

  `FountainWeb.Plugs.RequireKeyManagement` is the original, API-key-specific
  instance of this rule and now delegates here so there is one implementation
  of "is this credential allowed to act on the account itself".

  Pass `:error` to describe the refused capability; it is the response's
  `message`. The response is `FountainWeb.ScopeRefusal`'s: `error:
  "insufficient_scope"` and `required_scope: "full"`, so callers branch on the
  code rather than prose.

  Session-authenticated browser routes never reach this plug; it guards the
  bearer-token API pipeline only.
  """

  import Plug.Conn, only: [halt: 1]

  alias Fountain.Accounts.ApiKey
  alias FountainWeb.ScopeRefusal

  @default_error "This API key is not permitted to perform account-level writes"

  def init(opts), do: opts

  def call(%{assigns: %{current_api_key: %ApiKey{}}} = conn, opts) do
    if full_scope?(conn) do
      conn
    else
      refuse(conn, Keyword.get(opts, :error, @default_error))
    end
  end

  # No key on the connection means this ran outside the bearer-token pipeline.
  # Fail closed rather than assume the caller is privileged.
  def call(conn, _opts) do
    refuse(conn, "API key scope could not be determined")
  end

  # Whether the request carries a full-scope key. `false` with no key, as the
  # plug fails closed.
  defp full_scope?(%Plug.Conn{assigns: %{current_api_key: %ApiKey{} = key}}),
    do: ApiKey.may_manage_keys?(key)

  defp full_scope?(%Plug.Conn{}), do: false

  defp refuse(conn, message) do
    conn
    |> ScopeRefusal.render(message)
    |> halt()
  end
end
