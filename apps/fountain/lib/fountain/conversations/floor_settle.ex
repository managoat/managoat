defmodule Fountain.Conversations.FloorSettle do
  @moduledoc """
  Keeps a conversation's first model request clear of a Sprites network-floor
  write that may still be taking effect (fountain#2964, ADR 0019 §2).

  A Sprites policy write resets the guest's open TCP flows when it takes
  effect, and on production that can be a couple of seconds after the API
  has answered. On 2026-10-17 every one of 29 cold first turns that stalled
  had sent its first model request 1.76–2.14 s after the floor write
  returned; none of about 2,700 whose request went 2.2 s or later did.

  So a provision or a reattach on Sprites marks when its floor step returned
  (`mark/1`), and before the conversation can take a prompt it waits out
  whatever is left of `settle_ms/0` since then (`hold/3`). It is measured
  from the mark, not slept: a provision whose remaining steps already took
  longer adds nothing. Other providers are never marked, so never held.

  The window is 2 s to the moment the prompt can be sent. The model request
  the stall is about comes later. Of 3,138 Sprites first turns on
  2026-10-17, the shortest from turn start to the first model request was
  1.07 s, the 1st percentile 1.32 s. So a first request lands at least about
  3.07 s after the write. That is 0.93 s past the last stall (2.14 s), and
  0.87 s past the 2.2 s from which none stalled.

  Counted to the prompt it costs little: replayed over the same day's cold
  provisions with the floor written first, a 2 s window adds a median 0.15 s,
  p90 0.45 s, and nothing to a third of them. A 3 s window would add a
  median 1.15 s to nine in ten.

  Every hold emits `[:fountain, :floor, :settle]` with `gap_ms` (mark to
  hold) and `held_ms` (time added), so the gap is measurable on production.
  """

  alias Managoat.Sandbox.Handle

  @settle_ms 2_000

  @doc "The settle window in ms; `config :fountain, #{inspect(__MODULE__)}, settle_ms: n` overrides it (tests use 0)."
  @spec settle_ms() :: non_neg_integer()
  def settle_ms do
    :fountain |> Application.get_env(__MODULE__, []) |> Keyword.get(:settle_ms, @settle_ms)
  end

  @doc "Whether a provision writes the floor first and holds after it: Sprites only."
  @spec early?(Handle.t()) :: boolean()
  def early?(%Handle{provider: provider}), do: provider == :sprites

  @doc "When the floor step returned, as a monotonic ms reading; `nil` off Sprites."
  @spec mark(Handle.t()) :: integer() | nil
  def mark(%Handle{} = handle),
    do: if(early?(handle), do: System.monotonic_time(:millisecond))

  # A machine created this recently may have had its floor written by its
  # workspace's setup moments before an attach found it in force.
  @fresh_machine_s 60

  @doc """
  The mark for an attach's floor step: taken when it wrote the floor, or found
  it in force on a machine created in the last #{@fresh_machine_s} s (its
  workspace's setup wrote it a moment before; the attach's own step is later,
  so measuring from it is conservative). A floor in force for longer has
  nothing left to settle, so a wake of an older machine is not held.
  """
  @spec mark_attach(Handle.t(), :written | :unchanged, %{inserted_at: DateTime.t() | nil}) ::
          integer() | nil
  def mark_attach(%Handle{} = handle, :written, _machine), do: mark(handle)

  def mark_attach(%Handle{} = handle, :unchanged, %{inserted_at: %DateTime{} = created}) do
    if DateTime.diff(DateTime.utc_now(), created) < @fresh_machine_s, do: mark(handle)
  end

  def mark_attach(%Handle{}, :unchanged, _machine), do: nil

  @doc """
  Wait until `settle_ms` has passed since `marked_at`, if it has not already.
  Answers the ms actually added. `nil` (no mark) waits for nothing and emits
  nothing.
  """
  @spec hold(integer() | nil, map(), non_neg_integer()) :: non_neg_integer()
  def hold(marked_at, metadata, settle_ms \\ settle_ms())

  def hold(nil, _metadata, _settle_ms), do: 0

  def hold(marked_at, metadata, settle_ms) when is_integer(marked_at) do
    gap = System.monotonic_time(:millisecond) - marked_at
    held = max(settle_ms - gap, 0)
    if held > 0, do: Process.sleep(held)

    Fountain.Telemetry.event([:floor, :settle], metadata, %{
      gap_ms: gap,
      held_ms: held,
      settle_ms: settle_ms
    })

    held
  end
end
