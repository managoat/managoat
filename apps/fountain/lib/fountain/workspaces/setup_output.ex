defmodule Fountain.Workspaces.SetupOutput do
  @moduledoc """
  An explicit workspace's setup output, while the setup runs (#3009): framed
  into whole lines, redacted, bounded, sent live as `workspace.setup` events
  on the owner's account stream, and kept as the workspace's last setup log
  (`Fountain.Workspaces.SetupLog`).

  ## Where it runs

  Every setup of an explicit workspace's machine is a build under its owner,
  `Fountain.Machines.Provision`: the create's (`Workspaces.Provisioner`), a
  retry's, the rebuild a caller asks for, and the rebuild after a loss, which
  a conversation's server runs with its own pipeline. The build calls
  `begin/1` before the machine is created and `finish/1` once its pipeline
  has answered, in the process that runs the steps, and the steps report
  into it from there: `step/1` as each begins, `output/1` with what it
  printed. The collector lives in that process's dictionary, so a step needs
  no argument to report and a step run anywhere else (an implicit
  workspace's build, a wake, a step in a task of its own) reports nothing.

  An **implicit** workspace's setup is not collected: its conversation's
  transcript already has it, as `output` events of the `packages`, `clone`
  and `setup` stages, and `workspace.status` is explicit-only too. A rebuild
  after a loss run by a conversation of an explicit workspace goes to both:
  the conversation's transcript, as before, and the workspace's log.

  ## The steps

  `machine` (the provider creates it), `broker` (the egress broker's floor,
  CA and relay), `environment` (the environment's and vault's variables
  written to the machine), `packages`, `repositories`, `setup_script`, and
  `runtime_template` (copying the runtime template into the config home of
  the conversation whose provision built the machine, #2998). A step is
  reported only when it runs: an environment with no packages has no
  `packages` step. In a workspace's own setup the template's directories are
  made in the setup script's exec, so that output is the `setup_script`
  step's. The order is the build's: a workspace's own setup settles the
  broker before it writes the environment, a conversation's provision the
  other way round. Step names are this fixed set and never carry input.

  ## Lines, not chunks

  Output arrives in chunks whose boundaries nobody chooses (about one a
  second from the setup wrapper, `Provisioning.stream_wrapper/0`, or a
  clone's whole output at its end). It is sent and kept as **whole lines**:
  a chunk's bytes after its last newline wait for the rest of their line.
  That is what makes redaction hold across chunk boundaries: a value is
  matched against the whole line it is printed on, never against a fragment.
  Each line of a value that spans lines (a PEM key) is matched as well, as
  `Workspaces.describe_failure/2` does. A line is shown as a terminal would
  show it, after its last carriage return (a progress bar's last state), and
  is cut at 4 KiB. A line still unfinished at 64 KiB is written
  as it stands, cut, and the rest of it up to its newline is dropped; the
  cut stops short of any value lying across it, and a value as long as that
  whole buffer drops the line instead.

  ## Redaction

  With every value of the workspace's environment and vault, and whatever a
  live conversation on the machine registered (`Workspaces.redaction_values/1`),
  read when the setup begins and again as each step begins, plus the setup
  broker session's token once it exists (`add_values/1`). When the values
  cannot be read (the tenant key will not load), a step's output is
  withheld: one line says so, and nothing it printed is kept or sent.

  ## Bounds

    * **Kept:** the last 64 KiB of each step, in whole lines, and 256 KiB
      in all, the earliest step's earliest lines going first; each step says
      how many lines and bytes it lost (`omitted_lines`, `omitted_bytes`).
    * **Written:** the row is rewritten as each step begins and ends, at the
      end, and while output flows at most every 5 s. A setup's lines reach
      `GET /api/workspaces/:id/setup-log` within that.
    * **Sent:** at most one `output` event per 500 ms per setup, each with
      at most 16 KiB of lines: lines past that within one window are
      dropped from the event, oldest first, and counted in its
      `omitted_lines` (they are still kept). Plus one event as each step
      starts and ends. A noisy script costs the account stream about
      32 KiB a second however much it prints; the events are one local
      PubSub broadcast each, on the owner's `workspaces:<user_id>` topic.

  ## Attempts

  Every event carries the `sandbox_id` of the machine its setup builds, and
  the first of each setup is `machine` starting: a client drops what it
  showed and starts again. Each setup's writes are conditional on the row
  still being its own (`SetupLog`), so a setup that has been replaced writes
  nothing more.

  Nothing here may fail a setup: a fault in it is logged, and the setup goes
  on unrecorded.
  """

  require Logger

  alias Fountain.Conversations.Sandbox
  alias Fountain.Workspaces
  alias Fountain.Workspaces.SetupLog

  @key {__MODULE__, :setup}

  @steps ~w(machine broker environment packages repositories setup_script runtime_template)a

  @max_line 4_096
  @max_pending 65_536
  @step_bytes 65_536
  @total_bytes 262_144
  @event_bytes 16_384
  @event_interval_ms 500
  @flush_interval_ms 5_000

  @withheld "[Managoat: this step's output is withheld: the secrets to redact it with " <>
              "could not be read]"
  @long_withheld "[Managoat: a line too long to redact safely was dropped]"

  @typedoc "A setup step's name."
  @type step ::
          :machine
          | :broker
          | :environment
          | :packages
          | :repositories
          | :setup_script
          | :runtime_template

  @doc "The steps a setup reports, in a workspace's own setup's order."
  @spec steps() :: [String.t()]
  def steps, do: Enum.map(@steps, &Atom.to_string/1)

  @doc "The bounds, for the docs and the tests."
  @spec bounds() :: map()
  def bounds do
    %{
      max_line: @max_line,
      max_pending: @max_pending,
      step_bytes: @step_bytes,
      total_bytes: @total_bytes,
      event_bytes: @event_bytes,
      event_interval_ms: event_interval_ms(),
      flush_interval_ms: flush_interval_ms()
    }
  end

  defp event_interval_ms,
    do: Application.get_env(:fountain, :setup_event_interval_ms, @event_interval_ms)

  defp flush_interval_ms,
    do: Application.get_env(:fountain, :setup_log_flush_ms, @flush_interval_ms)

  @doc """
  A build of `sandbox` begins, before its machine is created: when it is an
  explicit workspace's, start collecting its setup in this process, replace
  the workspace's log with this setup's, and report the `machine` step.
  Anything else collects nothing.
  """
  @spec begin(Sandbox.t()) :: :ok
  def begin(%Sandbox{workspace_id: workspace_id, user_id: user_id} = sandbox)
      when is_binary(workspace_id) and is_binary(user_id) do
    # A collector this process left behind (a build that raised past its
    # `finish/1`) is not this setup's.
    Process.delete(@key)

    safely(fn ->
      if Workspaces.machine_kind(sandbox) == :explicit do
        state = new_state(sandbox)

        :ok =
          SetupLog.begin(%{
            workspace_id: workspace_id,
            user_id: user_id,
            sandbox_id: sandbox.id,
            step: nil,
            steps: [],
            started_at: DateTime.utc_now()
          })

        Process.put(@key, state)
        step(:machine)
      end
    end)
  end

  def begin(%Sandbox{}), do: :ok

  defp new_state(%Sandbox{} = sandbox) do
    now = System.monotonic_time(:millisecond)

    refresh_values(%{
      workspace_id: sandbox.workspace_id,
      user_id: sandbox.user_id,
      sandbox: sandbox,
      sandbox_id: sandbox.id,
      values: [],
      extra: [],
      pattern: nil,
      longest: 0,
      steps: [],
      pending: "",
      skipping?: false,
      total: 0,
      ev: :queue.new(),
      ev_bytes: 0,
      ev_omitted: 0,
      ev_at: now - event_interval_ms(),
      db_at: now,
      dirty?: false
    })
  end

  @doc "Whether a setup is being collected in this process."
  @spec active?() :: boolean()
  def active?, do: Process.get(@key) != nil

  @doc """
  `step` begins: the step before it, if any, has succeeded. A step already
  running is not begun again (a step that reports from two places).
  """
  @spec step(step()) :: :ok
  def step(step) when step in @steps do
    name = Atom.to_string(step)

    update(fn
      %{steps: [%{step: ^name, status: "running"} | _]} = s ->
        s

      s ->
        s
        |> close_current("succeeded")
        |> refresh_values()
        |> open(name)
        |> emit()
        |> persist()
    end)
  end

  @doc """
  Bytes the running step printed, in whatever chunks they arrived: whole
  lines are redacted, kept and sent; the rest waits for its newline.
  """
  @spec output(binary()) :: :ok
  def output(""), do: :ok

  def output(data) when is_binary(data) do
    update(fn
      %{steps: []} = s -> s
      s -> s |> feed(data) |> maybe_emit() |> maybe_persist()
    end)
  end

  @doc """
  Values to redact beside the environment's and vault's: the setup broker
  session's token, which the proxy variables a step can print carry.
  """
  @spec add_values([String.t()]) :: :ok
  def add_values(values) when is_list(values) do
    update(fn s ->
      extra = Enum.filter(values, &(is_binary(&1) and &1 != ""))
      compile(%{s | extra: Enum.uniq(s.extra ++ extra)})
    end)
  end

  @doc """
  A command of the running step has ended: what it left without a newline is
  its last line (the next command's output starts a line of its own), and
  what is held for the stream is sent now.
  """
  @spec flush() :: :ok
  def flush, do: update(fn s -> s |> end_line() |> emit_held() |> maybe_persist() end)

  @doc """
  The build's pipeline has answered: the running step ends `succeeded` or
  `failed` with the setup, which is written whole and stops being collected.
  """
  @spec finish(:succeeded | :failed) :: :ok
  def finish(outcome) when outcome in [:succeeded, :failed] do
    status = Atom.to_string(outcome)

    update(fn s ->
      s = close_current(s, status)

      SetupLog.put(s.workspace_id, s.sandbox_id,
        status: status,
        step: current_name(s),
        steps: render(s),
        finished_at: DateTime.utc_now()
      )

      nil
    end)
  end

  @doc """
  The build left without `finish/1` (it raised): the setup has failed.
  Nothing when it was finished or never begun.
  """
  @spec abandon() :: :ok
  def abandon do
    if active?(), do: finish(:failed), else: :ok
  end

  # ── the steps ───────────────────────────────────────────────────────────

  defp open(s, name) do
    step = %{
      step: name,
      status: "running",
      started_at: DateTime.utc_now(),
      finished_at: nil,
      lines: :queue.new(),
      bytes: 0,
      omitted_lines: 0,
      omitted_bytes: 0,
      withheld?: false
    }

    %{s | steps: [step | s.steps], pending: "", skipping?: false, dirty?: true}
  end

  # The running step ends with `status`: what it left unfinished is written as
  # its last line, and what is held for the stream goes out with its end.
  defp close_current(%{steps: []} = s, _status), do: s

  defp close_current(%{steps: [%{status: "running"} | _]} = s, status) do
    s = end_line(s)
    [current | earlier] = s.steps
    closed = %{current | status: status, finished_at: DateTime.utc_now()}
    emit(%{s | steps: [closed | earlier], dirty?: true})
  end

  defp close_current(s, _status), do: s

  defp current_name(%{steps: [%{step: name} | _]}), do: name
  defp current_name(_s), do: nil

  # ── framing ─────────────────────────────────────────────────────────────

  defp feed(s, data) do
    text = s.pending <> data
    parts = :binary.split(text, "\n", [:global])
    {lines, [rest]} = Enum.split(parts, -1)

    s = Enum.reduce(lines, %{s | pending: ""}, &complete/2)

    cond do
      byte_size(rest) <= @max_pending -> %{s | pending: rest}
      s.skipping? -> s
      true -> %{overflow(s, rest) | skipping?: true}
    end
  end

  # A line's newline arrived. The first one after an overflow ends the line
  # whose head was already written, and is dropped.
  defp complete(_line, %{skipping?: true} = s), do: %{s | skipping?: false}
  defp complete(line, s), do: keep(s, redact(s, line))

  # What the running step left without a newline, at its end.
  defp end_line(%{pending: ""} = s), do: %{s | skipping?: false}
  defp end_line(%{skipping?: true} = s), do: %{s | pending: "", skipping?: false}
  defp end_line(s), do: keep(%{s | pending: ""}, redact(s, s.pending))

  # A line past `@max_pending` with no newline yet: its head is written now,
  # cut short of any value that lies across the cut, since the value's end is
  # not here to be matched.
  defp overflow(%{values: :withheld} = s, _text), do: keep(s, :withheld)

  defp overflow(s, text) do
    if s.longest >= byte_size(text) - @max_line do
      keep(s, {:line, @long_withheld})
    else
      keep(s, redact(s, binary_part(text, 0, cut_at(s, text, @max_line))))
    end
  end

  # The cut, carried forward to the end of a value lying across it (the
  # matches `:binary.replace/4` will make, as `SandboxFiles` cuts a read).
  defp cut_at(%{pattern: nil}, _text, limit), do: limit

  defp cut_at(%{pattern: pattern}, text, limit) do
    text
    |> :binary.matches(pattern)
    |> Enum.find_value(limit, fn {start, length} ->
      if start < limit and start + length > limit, do: start + length
    end)
  end

  # ── redaction ───────────────────────────────────────────────────────────

  defp redact(%{values: :withheld}, _line), do: :withheld

  defp redact(s, line) do
    redacted =
      case s.pattern do
        nil ->
          line

        pattern ->
          :binary.replace(line, pattern, Fountain.Conversations.Redaction.placeholder(), [:global])
      end

    {:line, display(redacted)}
  end

  # What a terminal would show of the line, as text: after its last carriage
  # return, without NULs, valid UTF-8, at most `@max_line` bytes. Redacted
  # before any of this, so no cut here can split a value.
  defp display(line) do
    shown =
      line
      |> :binary.split("\r", [:global])
      |> Enum.reverse()
      |> Enum.find("", &(&1 != ""))
      |> String.replace(<<0>>, "")

    if byte_size(shown) > @max_line,
      do: String.replace_invalid(binary_part(shown, 0, @max_line)) <> " …",
      else: String.replace_invalid(shown)
  end

  defp refresh_values(s) do
    case Workspaces.redaction_values(s.sandbox) do
      {:ok, values} -> compile(%{s | values: values})
      :error -> %{s | values: :withheld, pattern: nil, longest: 0}
    end
  end

  defp compile(%{values: :withheld} = s), do: s

  defp compile(s) do
    case Enum.uniq(s.values ++ s.extra) do
      [] ->
        %{s | pattern: nil, longest: 0}

      all ->
        %{
          s
          | pattern: :binary.compile_pattern(all),
            longest: all |> Enum.map(&byte_size/1) |> Enum.max()
        }
    end
  end

  # ── keeping ─────────────────────────────────────────────────────────────

  defp keep(%{steps: [current | _]} = s, :withheld) do
    if current.withheld?,
      do: s,
      else: s |> mark_withheld() |> keep({:line, @withheld})
  end

  defp keep(s, {:line, line}) do
    size = byte_size(line) + 1
    [current | earlier] = s.steps

    current = %{current | lines: :queue.in(line, current.lines), bytes: current.bytes + size}
    {current, dropped} = trim_step(current, 0)

    %{s | steps: [current | earlier], total: s.total + size - dropped, dirty?: true}
    |> trim_total()
    |> hold(line, size)
  end

  defp mark_withheld(%{steps: [current | earlier]} = s),
    do: %{s | steps: [%{current | withheld?: true} | earlier]}

  defp trim_step(%{bytes: bytes} = step, dropped) when bytes <= @step_bytes, do: {step, dropped}

  defp trim_step(step, dropped) do
    {_line, size, step} = drop_oldest(step)
    trim_step(step, dropped + size)
  end

  defp drop_oldest(step) do
    {{:value, line}, lines} = :queue.out(step.lines)
    size = byte_size(line) + 1

    {line, size,
     %{
       step
       | lines: lines,
         bytes: step.bytes - size,
         omitted_lines: step.omitted_lines + 1,
         omitted_bytes: step.omitted_bytes + size
     }}
  end

  # Over the whole setup's cap, the earliest step with lines loses its
  # earliest first: the latest output is what a reader of a failure needs.
  defp trim_total(%{total: total} = s) when total <= @total_bytes, do: s

  defp trim_total(s) do
    {earlier_first, _} =
      s.steps
      |> Enum.reverse()
      |> Enum.map_reduce(s.total, fn
        step, over when over > @total_bytes and step.bytes > 0 ->
          drop_until(step, over)

        step, over ->
          {step, over}
      end)

    steps = Enum.reverse(earlier_first)
    %{s | steps: steps, total: Enum.reduce(steps, 0, &(&1.bytes + &2))}
  end

  defp drop_until(step, over) when over <= @total_bytes or step.bytes == 0, do: {step, over}

  defp drop_until(step, over) do
    {_line, size, step} = drop_oldest(step)
    drop_until(step, over - size)
  end

  # ── sending ─────────────────────────────────────────────────────────────

  # Held for the next event, at most `@event_bytes`: past it the oldest held
  # line is dropped from the event and counted.
  defp hold(s, line, size),
    do: trim_held(%{s | ev: :queue.in(line, s.ev), ev_bytes: s.ev_bytes + size})

  defp trim_held(%{ev_bytes: bytes} = s) when bytes <= @event_bytes, do: s

  defp trim_held(s) do
    {{:value, line}, ev} = :queue.out(s.ev)

    trim_held(%{
      s
      | ev: ev,
        ev_bytes: s.ev_bytes - byte_size(line) - 1,
        ev_omitted: s.ev_omitted + 1
    })
  end

  defp maybe_emit(s) do
    if not :queue.is_empty(s.ev) and
         System.monotonic_time(:millisecond) - s.ev_at >= event_interval_ms(),
       do: emit(s),
       else: s
  end

  defp emit_held(s), do: if(:queue.is_empty(s.ev) and s.ev_omitted == 0, do: s, else: emit(s))

  # One `workspace.setup` event: the running (or just ended) step, its status,
  # and the lines held since the last event.
  defp emit(%{steps: [current | _]} = s) do
    Workspaces.publish_setup(s.user_id, %{
      workspace_id: s.workspace_id,
      sandbox_id: s.sandbox_id,
      step: current.step,
      status: current.status,
      lines: :queue.to_list(s.ev),
      omitted_lines: s.ev_omitted,
      at: DateTime.utc_now()
    })

    %{
      s
      | ev: :queue.new(),
        ev_bytes: 0,
        ev_omitted: 0,
        ev_at: System.monotonic_time(:millisecond)
    }
  end

  defp emit(s), do: s

  # ── writing ─────────────────────────────────────────────────────────────

  defp maybe_persist(%{dirty?: false} = s), do: s

  defp maybe_persist(s) do
    if System.monotonic_time(:millisecond) - s.db_at >= flush_interval_ms(),
      do: persist(s),
      else: s
  end

  defp persist(s) do
    :ok = SetupLog.put(s.workspace_id, s.sandbox_id, step: current_name(s), steps: render(s))
    %{s | dirty?: false, db_at: System.monotonic_time(:millisecond)}
  end

  defp render(s) do
    s.steps
    |> Enum.reverse()
    |> Enum.map(fn step ->
      %{
        "step" => step.step,
        "status" => step.status,
        "started_at" => DateTime.to_iso8601(step.started_at),
        "finished_at" => step.finished_at && DateTime.to_iso8601(step.finished_at),
        "output" => step.lines |> :queue.to_list() |> Enum.map_join(&(&1 <> "\n")),
        "omitted_lines" => step.omitted_lines,
        "omitted_bytes" => step.omitted_bytes
      }
    end)
  end

  # ── the process's collector ─────────────────────────────────────────────

  defp update(fun) do
    case Process.get(@key) do
      nil ->
        :ok

      state ->
        safely(fn ->
          case fun.(state) do
            nil -> Process.delete(@key)
            next -> Process.put(@key, next)
          end
        end)
    end
  end

  # A fault here stops the collecting, never the setup. Only the exception's
  # module is logged: its message could quote the output, unredacted.
  defp safely(fun) do
    _ = fun.()
    :ok
  rescue
    exception ->
      Process.delete(@key)
      Logger.warning("setup output not collected any further: #{inspect(exception.__struct__)}")
      :ok
  end
end
