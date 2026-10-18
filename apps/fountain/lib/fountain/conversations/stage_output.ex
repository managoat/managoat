defmodule Fountain.Conversations.StageOutput do
  @moduledoc """
  A provisioning step's output on its way to the transcript, written while the
  step runs (#2550): the `packages` and `setup` stages' `output` events.

  Chunks arrive as the sandbox sends them. Only whole lines are written, so a
  client sees a script's `[HH:MM:SS] step` line whole or not yet; what follows
  the last newline waits for the rest of its line, or for the step's end. A
  line longer than `max_pending/0` is written as it stands rather than held
  without bound. How often a row is written is the sender's to pace: the setup
  wrapper in `Provisioning` sends what the script printed about once a second.

  The lines then go through `Output.log/4`, so the step's output counts
  against the conversation's durable log budget (#331) the way a turn's does:
  the head is kept, and past the budget one marker row replaces the rest. A
  registered value split across two chunks still reaches the redacting writer
  whole (`RedactionCarry`, #2359).

  `tail/1` is the end of what the step printed, for an error that quotes it.
  """

  alias Fountain.Conversations.Output

  @max_pending 65_536
  @tail_bytes 2_000

  defstruct [:ctx, pending: "", tail: "", output: %Output{}]

  @type t :: %__MODULE__{
          ctx: Output.ctx(),
          pending: binary(),
          tail: binary(),
          output: Output.t()
        }

  @doc "Output for `stage` of a conversation's provisioning, before its first turn."
  @spec new(String.t(), String.t()) :: t()
  def new(conversation_id, stage) do
    %__MODULE__{
      ctx: %{conversation_id: conversation_id, turn_id: nil, user_id: nil, stage: stage}
    }
  end

  @doc "The longest unfinished line held back before it is written anyway."
  def max_pending, do: @max_pending

  @doc "Take a chunk: write the whole lines it completes, hold the rest."
  @spec feed(t(), binary()) :: t()
  def feed(%__MODULE__{} = s, ""), do: s

  def feed(%__MODULE__{} = s, data) when is_binary(data) do
    s = %{s | tail: keep_tail(s.tail <> data)}
    text = s.pending <> data

    case :binary.matches(text, "\n") do
      [] when byte_size(text) < @max_pending ->
        %{s | pending: text}

      [] ->
        write(%{s | pending: ""}, text)

      matches ->
        {pos, 1} = List.last(matches)
        <<lines::binary-size(pos + 1), rest::binary>> = text
        write(%{s | pending: rest}, lines)
    end
  end

  @doc "The step is over: write whatever is still held."
  @spec finish(t()) :: t()
  def finish(%__MODULE__{} = s) do
    s = write(%{s | pending: ""}, s.pending)
    %{s | output: Output.flush(s.output)}
  end

  @doc "The last bytes the step printed."
  @spec tail(t()) :: binary()
  def tail(%__MODULE__{tail: tail}), do: tail

  defp write(s, ""), do: s
  # A step run with no conversation (`Fountain.Machines.Setup`) keeps only
  # its tail, for the error that quotes it.
  defp write(%{ctx: %{conversation_id: nil}} = s, _data), do: s
  defp write(s, data), do: %{s | output: Output.log(s.output, s.ctx, "stdout", data)}

  defp keep_tail(bin) when byte_size(bin) > @tail_bytes,
    do: binary_part(bin, byte_size(bin) - @tail_bytes, @tail_bytes)

  defp keep_tail(bin), do: bin
end
