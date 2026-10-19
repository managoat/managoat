defmodule Fountain.Workspaces.SetupPacer do
  @moduledoc """
  Delivers one setup's output (#3009): the `workspace.setup` events and the
  writes of its `Fountain.Workspaces.SetupLog` row, paced.

  `Fountain.Workspaces.SetupOutput` frames, redacts and bounds the output in
  the process that runs the setup's steps. That process spends a step blocked
  inside the exec, so it can neither send a line held back by the event
  interval nor write a row held back by the write interval once output goes
  quiet. This process can: it holds what is due and sends it when its
  interval is up, so the last lines before a quiet stretch arrive within the
  interval rather than with the next output. Every event of a setup is sent
  from here, so they reach the account stream in the order they were made.

  It is started by the collector, monitors it, and ends with it: on
  `finish/2`, which writes the setup's last state and answers once it is
  written, or when the collector's process ends (a killed setup), after
  writing what it held. It is not linked, so a fault here never reaches the
  setup.

  Pacing: an `output` event at most every `event_interval_ms` with at most
  `event_bytes` of lines, the oldest held lines past that dropped from the
  event and counted in `omitted_lines`; one event as each step starts and
  ends, with what was held for it; the row written at most every
  `flush_interval_ms`, and at once (the caller waiting) as each step starts
  and ends.
  """

  require Logger

  alias Fountain.Workspaces
  alias Fountain.Workspaces.SetupLog

  @call_timeout 5_000

  @doc "Start the pacer of the setup building `sandbox_id` in `workspace_id`."
  @spec start(map()) :: pid()
  def start(%{owner: owner} = opts) do
    callers = [owner | Process.get(:"$callers", [])]

    spawn(fn ->
      # The owner's database access, in the tests' sandbox.
      Process.put(:"$callers", callers)
      ref = Process.monitor(owner)

      loop(%{
        owner_ref: ref,
        user_id: opts.user_id,
        workspace_id: opts.workspace_id,
        sandbox_id: opts.sandbox_id,
        event_interval: opts.event_interval_ms,
        event_bytes: opts.event_bytes,
        flush_interval: opts.flush_interval_ms,
        render: opts.render,
        held: :queue.new(),
        held_bytes: 0,
        held_step: nil,
        omitted: 0,
        ev_at: now() - opts.event_interval_ms,
        ev_timer?: false,
        pending: nil,
        db_at: now(),
        db_timer?: false
      })
    end)
  end

  @doc """
  Whole, redacted lines `step` printed, and how many more it printed that
  the collector already left out (past what one event carries).
  """
  @spec lines(pid(), String.t(), [String.t()], non_neg_integer()) :: :ok
  def lines(_pacer, _step, [], 0), do: :ok

  def lines(pacer, step, lines, omitted),
    do: tap(:ok, fn _ -> send(pacer, {:lines, step, lines, omitted}) end)

  @doc "`step` started, or ended, with `status`: its event goes now."
  @spec boundary(pid(), String.t(), String.t()) :: :ok
  def boundary(pacer, step, status),
    do: tap(:ok, fn _ -> send(pacer, {:boundary, step, status}) end)

  @doc """
  The setup as it now stands, for its row: written within the write interval,
  or, `now: true`, before this answers.
  """
  @spec persist(pid(), term(), keyword()) :: :ok
  def persist(pacer, snapshot, opts \\ []) do
    if Keyword.get(opts, :now, false),
      do: call(pacer, {:persist_now, snapshot}),
      else: send(pacer, {:persist, snapshot})

    :ok
  end

  @doc "The setup's end: its last state is written, and the pacer stops."
  @spec finish(pid(), term(), keyword()) :: :ok
  def finish(pacer, snapshot, final), do: call(pacer, {:finish, snapshot, final})

  defp call(pacer, message) do
    ref = Process.monitor(pacer)
    send(pacer, {message, self(), ref})

    receive do
      {^ref, :ok} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    after
      @call_timeout ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  # ── the loop ────────────────────────────────────────────────────────────

  defp loop(s) do
    message =
      receive do
        message -> message
      end

    case handle(message, s) do
      {:cont, s} -> loop(s)
      :stop -> :ok
    end
  end

  # One message, guarded, so the loop stays a tail call. A fault stops the
  # pacer, never the setup; only the exception's module is logged, since its
  # message could quote output.
  defp handle(message, s) do
    on(message, s)
  rescue
    exception ->
      Logger.warning("setup pacer stopped: #{inspect(exception.__struct__)}")
      :stop
  end

  defp on({:lines, step, lines, omitted}, s),
    do: {:cont, s |> take(step, lines, omitted) |> maybe_emit()}

  defp on({:boundary, step, status}, s), do: {:cont, boundary_event(s, step, status)}
  defp on({:persist, snapshot}, s), do: {:cont, maybe_write(%{s | pending: snapshot})}

  defp on({{:persist_now, snapshot}, from, ref}, s) do
    s = write(%{s | pending: snapshot}, [])
    send(from, {ref, :ok})
    {:cont, s}
  end

  defp on({{:finish, snapshot, final}, from, ref}, s) do
    s = emit_held(s)
    _ = write(%{s | pending: snapshot}, final)
    send(from, {ref, :ok})
    :stop
  end

  defp on(:emit_due, s), do: {:cont, emit_held(%{s | ev_timer?: false})}
  defp on(:write_due, s), do: {:cont, write(%{s | db_timer?: false}, [])}

  # The setup's process ended without finishing (killed): what it held is
  # written, and nothing more comes.
  defp on({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = s) do
    _ = s |> emit_held() |> write([])
    :stop
  end

  defp on(_other, s), do: {:cont, s}

  defp take(s, step, lines, omitted) do
    # Lines of a step that has ended went out with its end event.
    s = emit_other_step(s, step)
    s = %{s | held_step: step, omitted: s.omitted + omitted}

    Enum.reduce(lines, s, fn line, acc ->
      trim(%{
        acc
        | held: :queue.in(line, acc.held),
          held_bytes: acc.held_bytes + byte_size(line) + 1
      })
    end)
  end

  defp trim(%{held_bytes: bytes, event_bytes: max} = s) when bytes <= max, do: s

  defp trim(s) do
    {{:value, line}, held} = :queue.out(s.held)

    trim(%{
      s
      | held: held,
        held_bytes: s.held_bytes - byte_size(line) - 1,
        omitted: s.omitted + 1
    })
  end

  defp maybe_emit(s) do
    due = s.ev_at + s.event_interval - now()

    cond do
      due <= 0 ->
        emit_held(s)

      s.ev_timer? ->
        s

      true ->
        Process.send_after(self(), :emit_due, due)
        %{s | ev_timer?: true}
    end
  end

  # A step's start or end: its event carries what was held for it.
  defp boundary_event(s, step, status) do
    s = emit_other_step(s, step)
    emit(%{s | held_step: step}, step, status)
  end

  # What is held for another step than `step` goes out as that step's.
  defp emit_other_step(%{held_step: held} = s, step) when held in [nil, step], do: s
  defp emit_other_step(s, _step), do: emit_held(s)

  defp emit_held(%{held_step: nil} = s), do: s

  defp emit_held(s) do
    if :queue.is_empty(s.held) and s.omitted == 0,
      do: s,
      else: emit(s, s.held_step, "running")
  end

  defp emit(s, step, status) do
    Workspaces.publish_setup(s.user_id, %{
      workspace_id: s.workspace_id,
      sandbox_id: s.sandbox_id,
      step: step,
      status: status,
      lines: :queue.to_list(s.held),
      omitted_lines: s.omitted,
      at: DateTime.utc_now()
    })

    %{s | held: :queue.new(), held_bytes: 0, omitted: 0, ev_at: now()}
  end

  defp maybe_write(%{pending: nil} = s), do: s

  defp maybe_write(s) do
    due = s.db_at + s.flush_interval - now()

    cond do
      due <= 0 ->
        write(s, [])

      s.db_timer? ->
        s

      true ->
        Process.send_after(self(), :write_due, due)
        %{s | db_timer?: true}
    end
  end

  defp write(%{pending: nil} = s, []), do: s

  defp write(s, final) do
    set =
      case s.pending do
        nil -> final
        snapshot -> s.render.(snapshot) ++ final
      end

    :ok = SetupLog.put(s.workspace_id, s.sandbox_id, set)
    %{s | pending: nil, db_at: now()}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
