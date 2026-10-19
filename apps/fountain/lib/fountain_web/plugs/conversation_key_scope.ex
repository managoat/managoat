defmodule FountainWeb.Plugs.ConversationKeyScope do
  @moduledoc """
  Confines a `"conversation"`-scoped key to reading its own conversation
  (#2934, ADR 0086).

  That key is what an `"auth": "conversation"` MCP server receives. The
  server is a third party the agent's author named, and the sandbox's own
  `sprite` key would have handed it the whole account: every transcript
  through `/api/search` and `/api/events/stream`, and every conversation to
  prompt, end or start. This key gets an allowlist instead, and every other
  route, present or future, refuses it with 403 `insufficient_scope`:

  - `GET /api/auth/me`, which names the conversation, so the server can bind
    the key to it;
  - `GET /api/conversations/:id`, and its `turns`, `events` and `stream`, and
    a turn's images, for that conversation alone.

  Writes are refused, even to its own conversation: a prompt, a label, an
  interrupt or an answer to a permission request is a decision the
  conversation's owner or its own agent makes, not a tool server.

  Sits in the `:api` pipeline straight after `TenantAPIAuth`, so no route
  can be reached without passing it. Any other key passes untouched.
  """

  import Plug.Conn, only: [halt: 1]

  alias Fountain.Accounts.ApiKey
  alias FountainWeb.ScopeRefusal

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_api_key: %ApiKey{} = key}} = conn, _opts) do
    cond do
      not ApiKey.conversation_bound?(key) -> conn
      allowed?(conn.method, conn.path_info, key.conversation_id) -> conn
      true -> refuse(conn)
    end
  end

  def call(conn, _opts), do: conn

  @doc false
  # The allowlist, over the method and the path's segments. A key with no
  # conversation (a row from before its binding, or a binding removed) reads
  # nothing but `/api/auth/me`.
  def allowed?("GET", ["api", "auth", "me"], _conversation_id), do: true

  def allowed?("GET", ["api", "conversations", id | rest], conversation_id)
      when is_binary(conversation_id) and id == conversation_id,
      do: own_read?(rest)

  def allowed?(_method, _path, _conversation_id), do: false

  defp own_read?([]), do: true
  defp own_read?([part]) when part in ["turns", "events", "stream"], do: true
  defp own_read?(["turns", _turn_id, "images", _position]), do: true
  defp own_read?(_rest), do: false

  defp refuse(conn) do
    conn
    |> ScopeRefusal.render("A conversation key reads only its own conversation")
    |> halt()
  end
end
