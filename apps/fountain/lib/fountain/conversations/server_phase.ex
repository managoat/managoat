defmodule Fountain.Conversations.ServerPhase do
  @moduledoc """
  Whether a conversation's server is setting up its machine (#2577).

  A `ConversationServer` provisions or reattaches inside
  `handle_continue(:provision)`, and a `GenServer.call` to it waits until that
  is over: a prompt sent then blocked for the call's 30 s timeout and answered
  `503`, while the prompt stayed in the mailbox and ran afterwards anyway. The
  server's value in `Fountain.ConversationRegistry` says which phase it is in,
  so a caller can tell without calling it.

  The value is advisory: a reader that looked the server up just before it
  changed phase acts on the old one, and one that misses `:setting_up` falls
  back to the call it made before.
  """

  @registry Fountain.ConversationRegistry

  @doc """
  From the server itself: it is setting up its machine. A server that is not
  registered (the test harness starts some outside the registry) stays unmarked,
  which is the old behaviour: a prompt calls it and waits.
  """
  @spec setting_up(String.t()) :: :ok
  def setting_up(conv_id), do: put(conv_id, :setting_up)

  @doc "From the server itself: setup is over, and calls reach it again."
  @spec ready(String.t()) :: :ok
  def ready(conv_id), do: put(conv_id, nil)

  @doc """
  The registry value of a server that is setting up, for a caller that has
  already looked the server up (`ConversationServer.send_prompt/4`).
  """
  @spec setting_up_value() :: :setting_up
  def setting_up_value, do: :setting_up

  @doc """
  Whether the registered server of `conv_id` is setting up its machine right
  now: a wake in flight, with no turn row yet to say so. Advisory, like the
  value itself.
  """
  @spec setting_up?(String.t()) :: boolean()
  def setting_up?(conv_id) do
    match?([{_pid, :setting_up}], Registry.lookup(@registry, conv_id))
  end

  # Only the registered process may change its value; from anyone else the
  # registry answers `:error`, which leaves the phase as it was.
  defp put(conv_id, value) do
    _ = Registry.update_value(@registry, conv_id, fn _ -> value end)
    :ok
  end
end
