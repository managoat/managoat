defmodule Fountain.Conversations.PromptDelivery do
  @moduledoc """
  What travels with a prompt's text to the turn it opens (#1406).

  A prompt reaches its turn by one of two roads. A live `ConversationServer`
  takes it in a call and opens the turn before it answers. A conversation with
  no server is woken first, and the prompt follows in a cast once the machine
  is up, long after the request that carried it was answered. The caller's
  `client_request_id` has to arrive at `TurnMachine.open/7` down both, and this
  module is the one place that says how.

  The message only changes shape when there is something to carry: with
  nothing travelling, a prompt is `{:send_prompt, prompt, images}` or
  `{:initial_prompt, prompt, images}`, and with something it gains a fourth
  element. Fountain runs as one node (ADR 0072), so the server that receives
  the message runs the release that built it.
  """

  alias Fountain.Conversations.{ConversationServer, Turn}

  # `:withdrawn_turn` is the number of the turn a prompt was withdrawn from
  # when its machine was lost (`MachineLoss`): a report that it did not run
  # again ends that turn for the client following it.
  @carried [:client_request_id, :response_timing, :prompt_receipt_id, :withdrawn_turn]

  @type travelling :: keyword()
  @type wake_prompt :: nil | String.t() | {String.t(), travelling()}

  @doc """
  The part of a door's `opts` that goes with the prompt to its turn.

  An id the turn's changeset would refuse is dropped here, because the API has
  already refused it (422) and this is the backstop for a caller that is not
  the API. Reaching the insert instead would make turn admission fail, and a
  live server answers a failed admission by dropping its connection: a healthy
  agent session torn down over a label. An id carrying U+0000 is worse than a
  refused changeset — PostgreSQL raises 22021 from inside the insert — and it
  is dropped here for the same reason.
  """
  @spec travelling(keyword()) :: travelling()
  def travelling(opts) when is_list(opts) do
    for {key, value} <- opts, key in @carried, carriable?(key, value), do: {key, value}
  end

  defp carriable?(:client_request_id, value) when is_binary(value),
    do: String.length(value) in 1..Turn.client_request_id_max() and not Turn.has_nul?(value)

  defp carriable?(:response_timing, %{started_mono: time, path: path})
       when is_integer(time) and path in ["cold", "warm", "wake"], do: true

  defp carriable?(:prompt_receipt_id, value) when is_binary(value), do: true
  defp carriable?(:withdrawn_turn, value) when is_integer(value) and value > 0, do: true

  defp carriable?(_key, _value), do: false

  @doc """
  What a launch request asks to travel with its first prompt. `attrs` is the
  string-keyed map `Launch` takes, from the API or replayed from the queue.
  """
  @spec from_request(map()) :: travelling()
  def from_request(attrs) when is_map(attrs) do
    travelling(client_request_id: attrs["client_request_id"])
  end

  @doc """
  Queue a launch's first prompt on the server just started for it. With
  nothing travelling this is the three-argument `queue_initial_prompt`, the
  call it has always been.
  """
  @spec queue(pid(), String.t(), list(), travelling()) :: :ok
  def queue(pid, prompt, images, []),
    do: ConversationServer.queue_initial_prompt(pid, prompt, images)

  def queue(pid, prompt, images, meta),
    do: ConversationServer.queue_initial_prompt(pid, prompt, images, meta)

  @doc "The call the live server `pid` takes a prompt in."
  @spec call(pid(), String.t(), list(), keyword()) :: tuple()
  def call(_pid, prompt, images, opts) do
    case travelling(opts) do
      [] -> {:send_prompt, prompt, images}
      meta -> {:send_prompt, prompt, images, meta}
    end
  end

  @doc """
  Deliver to a live server. A timeout answers `:provisioning`; an explicit
  refusal from the server is returned unchanged.
  """
  def deliver(pid, prompt, images, opts) do
    ConversationServer.call_server(pid, call(pid, prompt, images, opts))
  end

  @doc "The cast that delivers a prompt to the server `pid` once it has provisioned."
  @spec cast(pid(), String.t(), list(), keyword()) :: tuple()
  def cast(_pid, prompt, images, opts) do
    case travelling(opts) do
      [] -> {:initial_prompt, prompt, images}
      meta -> {:initial_prompt, prompt, images, meta}
    end
  end

  @doc """
  The prompt as `Wake` carries it: the bare text when nothing travels with it,
  which is what every existing caller of `Wake.wake_conversation/3` passes.
  """
  @spec for_wake(String.t() | nil, keyword()) :: wake_prompt()
  def for_wake(prompt, opts) when is_binary(prompt) do
    case travelling(opts) do
      [] -> prompt
      meta -> {prompt, meta}
    end
  end

  def for_wake(prompt, _opts), do: prompt

  @doc """
  Hand a woken conversation's prompt to the server that ended up owning it.
  Nothing to deliver is not an error: a wake for an interrupt carries no prompt.

  `images` has no default, for the reason #2373 gave: the wake used to reach
  `queue_initial_prompt/2`, whose default was `[]`, and a woken turn opened
  with the text and none of its images while the caller was told `queued`.
  """
  @spec hand_over(pid(), wake_prompt(), list()) :: :ok
  def hand_over(pid, {prompt, meta}, images) when is_binary(prompt) and prompt != "" do
    ConversationServer.queue_initial_prompt(pid, prompt, images, meta)
  end

  def hand_over(pid, prompt, images) when is_binary(prompt) and prompt != "" do
    ConversationServer.queue_initial_prompt(pid, prompt, images)
  end

  def hand_over(_pid, _nothing, _images), do: :ok
end
