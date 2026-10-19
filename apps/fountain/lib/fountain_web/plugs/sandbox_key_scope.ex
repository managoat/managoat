defmodule FountainWeb.Plugs.SandboxKeyScope do
  @moduledoc """
  Confines a sandbox's own key (`sprite` scope, the conversation's
  `MANAGOAT_TOKEN`) to its conversation tree (#2981, ADR 0096).

  The key authenticates as the account, so without this every tenant-scoped
  route passed for it: code running in one sandbox could list the account's
  conversations, read every transcript, and prompt, end or start any of them.
  It gets an allowlist instead, and every other route, present or future,
  refuses it with 403 `insufficient_scope`:

  - **Spawn inputs, read only.** `GET /api/auth/me`, `GET /api/catalog`, and
    `GET` on agents (with their versions and avatar), environments and vaults,
    and the secret *names* of an environment or vault. Secret values are never
    returned over the API to any key.
  - **Starting a child.** `POST /api/conversations`. The new conversation is
    always a child of the key's own one
    (`Fountain.Conversations.Launch.start_conversation/2`), so the tree stays
    closed.
  - **Its tree.** For the key's own conversation and every conversation it
    spawned, at any depth: show, `turns`, `events`, `stream`, turn images,
    `prompts`, `interrupt`, `wake`, `terminate`, `labels` and `DELETE`. A
    conversation outside the tree, an ancestor or sibling included, answers
    404 as another account's conversation does, so an id is not confirmed to
    exist.

  Search, the account event stream, the conversation list, a conversation's
  whole `tree`, sandboxes, apply and every write to configuration are among
  the refused routes. The routes behind `:require_full_scope` were already
  refused to this key; the refusal here carries the same `required_scope`.

  Sits in the `:api` pipeline after `FountainWeb.Plugs.Audit`, so a refused
  write is still on the trail as the sandbox's. Any other key passes
  untouched; a `"conversation"` key has its own narrower plug,
  `FountainWeb.Plugs.ConversationKeyScope`.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Fountain.Conversations
  alias FountainWeb.SandboxKey
  alias FountainWeb.ScopeRefusal

  def init(opts), do: opts

  def call(%Plug.Conn{} = conn, _opts) do
    case SandboxKey.id(conn) do
      nil -> conn
      key_id -> enforce(conn, key_id, route(conn.method, conn.path_info))
    end
  end

  defp enforce(conn, _key_id, :allow), do: conn
  defp enforce(conn, _key_id, :deny), do: refuse(conn)

  defp enforce(conn, key_id, {:tree, conversation_id}) do
    user_id = conn.assigns.current_user.id

    case Conversations.get_conversation_for_callback_key(key_id, user_id) do
      %{id: root_id} ->
        if Conversations.in_spawn_tree?(root_id, conversation_id, user_id),
          do: conn,
          else: not_found(conn)

      nil ->
        not_found(conn)
    end
  end

  @doc false
  # The allowlist, over the method and the path's segments: `:allow`,
  # `{:tree, conversation_id}` for a route that is allowed only inside the
  # key's tree, or `:deny`. Public so a test can walk the router's routes
  # through it.
  @spec route(String.t(), [String.t()]) :: :allow | :deny | {:tree, String.t()}
  def route("GET", ["api", "auth", "me"]), do: :allow
  def route("GET", ["api", "catalog"]), do: :allow

  def route("GET", ["api", "agents" | rest]), do: agent_read(rest)
  def route("GET", ["api", "environments" | rest]), do: config_read(rest)
  def route("GET", ["api", "vaults" | rest]), do: config_read(rest)

  def route("POST", ["api", "conversations"]), do: :allow

  def route(method, ["api", "conversations", id | rest]) do
    if tree_route?(method, rest), do: {:tree, id}, else: :deny
  end

  def route(_method, _path), do: :deny

  defp agent_read([]), do: :allow
  defp agent_read([_id]), do: :allow
  defp agent_read([_id, "avatar"]), do: :allow
  defp agent_read([_id, "versions"]), do: :allow
  defp agent_read([_id, "versions", _version]), do: :allow
  defp agent_read(_rest), do: :deny

  # An environment or a vault, and the names of its secrets: the listing
  # renders key and timestamps, never a value (`SecretJSON`, `VaultSecretJSON`).
  defp config_read([]), do: :allow
  defp config_read([_id]), do: :allow
  defp config_read([_id, "secrets"]), do: :allow
  defp config_read(_rest), do: :deny

  defp tree_route?("GET", []), do: true
  defp tree_route?("DELETE", []), do: true
  defp tree_route?("GET", [part]) when part in ["turns", "events", "stream"], do: true
  defp tree_route?("GET", ["turns", _turn_id, "images", _position]), do: true

  defp tree_route?("POST", [part]) when part in ["prompts", "interrupt", "wake", "terminate"],
    do: true

  # The labels door applies its own narrower rule: a sandbox labels its own
  # conversation only (`Conversations.set_conversation_labels/4`).
  defp tree_route?("PATCH", ["labels"]), do: true
  defp tree_route?(_method, _rest), do: false

  defp refuse(conn) do
    conn
    |> ScopeRefusal.render(
      "A sandbox key reaches only its own conversation tree and the inputs to spawn"
    )
    |> halt()
  end

  # The shape `FallbackController` gives a conversation the account does not
  # own, so the two cannot be told apart.
  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
    |> halt()
  end
end
