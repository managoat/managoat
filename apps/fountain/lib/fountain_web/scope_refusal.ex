defmodule FountainWeb.ScopeRefusal do
  @moduledoc """
  The one 403 body a key's scope check answers with, from the scope plugs
  (`FountainWeb.Plugs.RequireFullScope`, `SandboxKeyScope`,
  `ConversationKeyScope`) and from `FountainWeb.FallbackController` for a
  sandbox's own key naming a workspace:

      %{
        error: "insufficient_scope",
        message: "A sandbox key reaches only its own conversation tree ...",
        reason: "insufficient_scope",
        required_scope: "full"
      }

  `error` is the code to branch on, as on every other error the API sends,
  and `message` the sentence. `required_scope` names the scope a key needs
  for the request: `full`, the only one that passes every scope check.
  `reason` repeats the code: until 2026-10-19 `error` was the sentence and
  `reason` the only code, and a client that branches on `reason` keeps
  working.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  @doc "Renders the 403. Does not halt: a plug halts after it."
  @spec render(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def render(conn, message) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "insufficient_scope",
      message: message,
      reason: "insufficient_scope",
      required_scope: "full"
    })
  end
end
