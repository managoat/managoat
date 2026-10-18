defmodule Fountain.Machines.Occupancy do
  @moduledoc """
  Who is on one machine: the single answer to "is anyone here" (ADR 0058,
  #2255 decision 1).

  Four unrelated predicates used to answer that question, each with its own
  query and its own idea of what counts — `Conversations._unsafe_sandbox_busy_elsewhere?/4`,
  `Lifecycle._unsafe_sandbox_held_by_other?/2` (`Machines.Binding.held_by_other?/2`
  since stage 8b), `Lifecycle.live_conversation_ids/1`
  and `Lifecycle.any_server_alive?/1`. They all delegate here now. The
  differences between them were deliberate, so this module keeps every one of
  them rather than flattening them into a single boolean; what is shared is
  the reading of the rows and the registry, not the verdict taken from it.

  Nothing here holds a process or writes anything. `Fountain.Machines.Machine`
  serves this struct over a `GenServer.call`, so a later stage can put writes
  behind the same door; the functions themselves stay callable directly, which
  is what keeps the gate-off path identical to today's behaviour.

  ## Loading

  The three constructors cost different amounts, and each caller takes the
  cheapest one that answers its question:

    * `from_preloaded/1` — no query at all. For a `%Sandbox{}` whose
      `conversations` are already loaded, which is what the reaper's scans and
      the reap target both carry. Fills `bound` and `live`.
    * `bindings/1` — one query. Fills `bound` only; the registry is not
      consulted, because the caller that needs this (the teardown fence) asks
      inside a transaction under the sandbox advisory lock and only wants to
      know who holds the row.
    * `load/1` — three queries (two with the sandbox row in hand). The whole
      answer, including turns and last activity. This is what
      `Machine.who_is_here/1` returns.

  A field a constructor did not fill is `:unloaded`, and the function that
  needs it raises rather than quietly answering from a blank. The alternative
  — defaulting to `[]` or `nil` — would turn "nobody asked for this" into
  "nobody is here", which is the exact mistake this module exists to stop
  being possible in four places at once.

  `busy_elsewhere?/4` additionally takes a **sandbox id** in place of a
  struct, and then runs the two short-circuiting `EXISTS` probes the predicate
  has always run rather than loading the machine. Its caller is the
  conversation server's lifecycle tick; see the function's own doc for why
  that path does not pay for the full reading.

  ## `live` is not a subset of `bound`

  `bound` excludes `terminated` and `failed` conversations. `live` does not:
  it is every conversation on the machine with a registered
  `ConversationServer`, whatever its row says. That asymmetry is today's
  behaviour, and it is load-bearing in both directions — the reaper treats a
  registered server as "provisioning is still in flight, do not touch this
  row" regardless of status, while
  `Termination.reap_sandbox/1` terminates through a live server precisely
  because that is what stopping a runaway agent means. Whether an owner should
  keep the distinction is a stage 5/8 question; this stage preserves it.
  """

  import Ecto.Query

  alias Fountain.Conversations.{Conversation, ConversationServer, Sandbox, Turn}
  alias Fountain.Repo

  @typedoc """
  One conversation's activity on the machine, as the idle window reads it.

  `turns?` distinguishes a conversation that has never taken a turn — judged
  by its own row's `updated_at` — from one whose turns are simply all old.
  """
  @type activity :: %{
          turns?: boolean(),
          running?: boolean(),
          newest_turn_inserted_at: DateTime.t() | nil,
          newest_turn_started_at: DateTime.t() | nil,
          newest_turn_ended_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type t :: %__MODULE__{
          sandbox_id: String.t() | nil,
          bound: [String.t()],
          live: [String.t()] | :unloaded,
          running_turns: %{String.t() => String.t() | nil} | :unloaded,
          last_activity_at: DateTime.t() | nil | :unloaded,
          activity: %{String.t() => activity()} | :unloaded
        }

  defstruct sandbox_id: nil,
            bound: [],
            live: :unloaded,
            running_turns: :unloaded,
            last_activity_at: :unloaded,
            activity: :unloaded

  # ── constructors ──────────────────────────────────────────────────────────

  @doc """
  The occupancy of a `%Sandbox{}` whose `conversations` are preloaded, with no
  query of any kind.

  Every caller of `Lifecycle.live_conversation_ids/1` and
  `any_server_alive?/1` already carries the association from the query that
  fetched the sandbox, and both sit inside reaper scans over every candidate
  row — a query here would be one per row per pass.
  """
  @spec from_preloaded(Sandbox.t()) :: t()
  def from_preloaded(%Sandbox{id: sandbox_id, conversations: conversations})
      when is_list(conversations) do
    %__MODULE__{
      sandbox_id: sandbox_id,
      bound: conversations |> Enum.filter(&bound?/1) |> Enum.map(& &1.id),
      live: conversations |> Enum.filter(&registered?(&1.id)) |> Enum.map(& &1.id)
    }
  end

  @doc """
  Who holds `sandbox_id`, in one query, without consulting the registry.

  For a caller that only needs `held_by_other?/2` or `cotenant_ids/2` — the
  teardown fence asks inside its transaction, under the machine's advisory
  lock, where the cheapest correct read is the right one.
  """
  @spec bindings(String.t()) :: t()
  def bindings(sandbox_id) when is_binary(sandbox_id) do
    %__MODULE__{sandbox_id: sandbox_id, bound: bound_ids(sandbox_id)}
  end

  @doc """
  The whole answer for `sandbox_id`: who is bound, whose server is registered,
  which conversations are mid-turn and on what runtime, and when the machine
  last saw activity.

  Three queries — the sandbox row, its conversations, one grouped aggregate
  over their turns — or two when the row is passed in. `last_activity_at` is
  the fold `SandboxReaper` makes over the machine's whole history: the
  sandbox's own `inserted_at` and `last_resumed_at` against the newest turn
  insertion, start and end across every conversation on it. Bookkeeping
  updates are deliberately not in it (the rehydrator touches
  `conversations.updated_at` on every boot, which would make an abandoned
  machine look freshly active after each deploy).
  """
  @spec load(String.t() | Sandbox.t()) :: t()
  def load(sandbox_id) when is_binary(sandbox_id) do
    load(Repo.one(from s in Sandbox, where: s.id == ^sandbox_id), sandbox_id)
  end

  def load(%Sandbox{id: sandbox_id} = sandbox), do: load(sandbox, sandbox_id)

  defp load(sandbox, sandbox_id) do
    rows = conversation_rows(sandbox_id)
    ids = Enum.map(rows, fn {id, _status, _runtime, _updated_at} -> id end)
    turns = turn_rollup(ids)

    %__MODULE__{
      sandbox_id: sandbox_id,
      bound: for({id, status, _runtime, _at} <- rows, bound_status?(status), do: id),
      live: Enum.filter(ids, &registered?/1),
      running_turns: running_turns(rows, turns),
      activity: activity_map(rows, turns),
      last_activity_at: last_activity_at(sandbox, turns)
    }
  end

  # ── the four derived answers ──────────────────────────────────────────────

  @doc """
  Whether a conversation other than `conv_id` still holds the machine —
  status only, no clock.

  What `Machines.Binding.held_by_other?/2` answers: a sandbox
  has one conversation; a second appeared when a teammate started a fresh
  one on the same computer (removed with the team, ADR 0074), and from then
  on the retired thread's lifecycle must not reach the disk its successor
  is running on.
  """
  @spec held_by_other?(t(), String.t()) :: boolean()
  def held_by_other?(%__MODULE__{bound: bound}, conv_id) when is_binary(conv_id) do
    Enum.any?(bound, &(&1 != conv_id))
  end

  @doc """
  The bound conversations other than `conv_id`: the machine's co-tenants.
  """
  @spec cotenant_ids(t(), String.t()) :: [String.t()]
  def cotenant_ids(%__MODULE__{bound: bound}, conv_id) when is_binary(conv_id) do
    Enum.reject(bound, &(&1 == conv_id))
  end

  @doc """
  Whether any *other* conversation on the machine is mid-turn, or was active
  within the last `idle_seconds` — status **and** the idle window, which is
  what separates this from `held_by_other?/2`.

  What `Conversations._unsafe_sandbox_busy_elsewhere?/4` answers. A server
  that finds its own conversation idle asks it before parking the machine
  everyone is on: the idle verdict is the machine's, taken over the union of
  its conversations' activity (ADR 0023 step 5), not one conversation's clock.
  Activity is a co-tenant's newest turn row (start or end), falling back to
  the conversation's own `updated_at` for one that never took a turn. `nil`
  idle seconds — the bound is off — is never busy.

  ## Two costs, one answer

  Given a **sandbox id**, this asks the two short-circuiting `EXISTS` probes
  the predicate has always run: one query for the co-tenants, then a turn
  probe scoped to them that stops at the first matching row, and a second one
  only if the first found nothing. Given a **loaded struct**, it answers from
  the reading already in hand and runs no query at all.

  The by-id form is the one on the hot path. `Lifecycle.busy_elsewhere?/2`
  asks it from the conversation server's lifecycle tick, once per server, and
  the busiest production home carries 36 conversations (ADR 0023) — so a
  `GROUP BY` over every turn of every conversation on the machine, plus the
  sandbox row that only `last_activity_at` reads, is 38 queries' worth of work
  per tick to answer a question two `EXISTS` short-circuit. `load/1` stays the
  fuller reading for `Machine.who_is_here/1`, which wants the whole struct
  anyway.

  The two forms must agree, and `occupancy_test.exs` pins that differentially
  against the pre-ADR-0058 query on every edge the semantics have: a `nil`
  `ended_at`, a timestamp exactly on the cutoff, the disjunction split across
  two turn rows, a terminated co-tenant holding a `running` row.
  """
  @spec busy_elsewhere?(t() | String.t(), String.t(), non_neg_integer() | nil, DateTime.t()) ::
          boolean()
  def busy_elsewhere?(occupancy_or_sandbox_id, conv_id, idle_seconds, now \\ DateTime.utc_now())

  def busy_elsewhere?(_occupancy_or_sandbox_id, _conv_id, nil, _now), do: false

  def busy_elsewhere?(sandbox_id, conv_id, idle_seconds, now)
      when is_binary(sandbox_id) and is_binary(conv_id) and is_integer(idle_seconds) do
    cutoff = cutoff(idle_seconds, now)

    case bound_ids(sandbox_id, except: conv_id) do
      [] ->
        false

      cotenants ->
        Repo.exists?(
          from t in Turn,
            where:
              t.conversation_id in ^cotenants and
                (t.status == "running" or t.inserted_at > ^cutoff or t.ended_at > ^cutoff)
        ) or
          Repo.exists?(
            from c in Conversation,
              left_join: t in Turn,
              on: t.conversation_id == c.id,
              where: c.id in ^cotenants and is_nil(t.id) and c.updated_at > ^cutoff
          )
    end
  end

  def busy_elsewhere?(%__MODULE__{activity: :unloaded} = occupancy, _conv_id, _idle, _now) do
    raise ArgumentError, unloaded_message(occupancy, "busy_elsewhere?/4", :activity)
  end

  def busy_elsewhere?(%__MODULE__{} = occupancy, conv_id, idle_seconds, now)
      when is_binary(conv_id) and is_integer(idle_seconds) do
    cutoff = cutoff(idle_seconds, now)

    case cotenant_ids(occupancy, conv_id) do
      [] ->
        false

      cotenants ->
        Enum.any?(cotenants, &turn_activity?(occupancy, &1, cutoff)) or
          Enum.any?(cotenants, &row_activity?(occupancy, &1, cutoff))
    end
  end

  @doc """
  The conversations on the machine that are mid-turn.

  Ids rather than a count, because the only caller has to decide *whose* turn
  it is: `Fountain.Machines.Park` treats the requester's own turn differently
  at the ceiling, and ignores one whose conversation has no live server. A
  plain `any_running_turn?` predicate lived here for one round of review and
  went when the veto stopped being a yes-or-no question.
  """
  @spec running_turn_ids(t()) :: [String.t()]
  def running_turn_ids(%__MODULE__{running_turns: :unloaded} = occupancy) do
    raise ArgumentError, unloaded_message(occupancy, "running_turn_ids/1", :running_turns)
  end

  def running_turn_ids(%__MODULE__{running_turns: running}), do: Map.keys(running)

  @doc """
  When the machine last saw activity: its own creation and last wake against
  the newest turn insertion, start and end across every conversation on it.

  The fold the reaper's idle verdict is made on, and the one
  `Fountain.Machines.Park` re-runs under the lease. It lived in
  `SandboxReaper.last_activity_at/1` as well until stage 6b, in a second copy
  that had to agree with this one about which timestamps count; a park that
  revalidates the reaper's verdict has to ask the *same* question the reaper
  asked, so there is one fold.

  Bookkeeping is deliberately excluded. `conversations.updated_at` moves on
  every rehydrator boot, which would make an abandoned machine look freshly
  active after each deploy.

  Two forms. Given a loaded `t()` it is the field, free. Given a `%Sandbox{}`
  whose `conversations` are preloaded it is one grouped query over their
  turns — the reaper's per-row cost, unchanged.
  """
  @spec last_activity_at(t() | Sandbox.t()) :: DateTime.t() | nil
  def last_activity_at(%__MODULE__{last_activity_at: :unloaded} = occupancy) do
    raise ArgumentError, unloaded_message(occupancy, "last_activity_at/1", :last_activity_at)
  end

  def last_activity_at(%__MODULE__{last_activity_at: at}), do: at

  def last_activity_at(%Sandbox{conversations: conversations} = sandbox)
      when is_list(conversations) do
    last_activity_at(sandbox, conversations |> Enum.map(& &1.id) |> turn_rollup())
  end

  @doc """
  Conversation ids on the machine with a live, registered `ConversationServer`.

  What `Lifecycle.live_conversation_ids/1` answers. Read the moduledoc on why
  this is not filtered by status.
  """
  @spec live_ids(t()) :: [String.t()]
  def live_ids(%__MODULE__{live: :unloaded} = occupancy) do
    raise ArgumentError, unloaded_message(occupancy, "live_ids/1", :live)
  end

  def live_ids(%__MODULE__{live: live}), do: live

  @doc """
  Whether any conversation on the machine has a live, registered
  `ConversationServer` — `live_ids/1` for a caller that only needs yes or no.

  What `Lifecycle.any_server_alive?/1` answers. The registry is local (ADR
  0072) and `Conversations.register_server/2` starts a server under the
  per-sandbox lock, so a reader that holds that lock and finds nobody has found
  nobody.
  """
  @spec any_live?(t()) :: boolean()
  def any_live?(%__MODULE__{} = occupancy), do: live_ids(occupancy) != []

  # ── internals ─────────────────────────────────────────────────────────────

  @terminal ["terminated", "failed"]

  defp bound?(%{status: status}), do: bound_status?(status)

  defp bound_status?(status), do: status not in @terminal

  # Through `ConversationServer.whereis/1` rather than the registry directly:
  # that function is the one door onto the conversation registry, and tests
  # that stand a process in for a server stub it there.
  defp registered?(conv_id), do: ConversationServer.whereis(conv_id) != nil

  defp bound_ids(sandbox_id, opts \\ []) do
    query =
      from c in Conversation,
        where: c.sandbox_id == ^sandbox_id and c.status not in @terminal,
        order_by: [asc: c.inserted_at, asc: c.id],
        select: c.id

    query =
      case Keyword.get(opts, :except) do
        nil -> query
        conv_id -> from c in query, where: c.id != ^conv_id
      end

    Repo.all(query)
  end

  # The idle window's left edge. `truncate(:second)` matters: every timestamp
  # it is compared against is `:utc_datetime`, so a microsecond tail on the
  # cutoff would move the boundary for a row sitting exactly on it.
  defp cutoff(idle_seconds, now) do
    now |> DateTime.add(-idle_seconds, :second) |> DateTime.truncate(:second)
  end

  defp conversation_rows(sandbox_id) do
    Repo.all(
      from c in Conversation,
        where: c.sandbox_id == ^sandbox_id,
        order_by: [asc: c.inserted_at, asc: c.id],
        select: {c.id, c.status, c.runtime, c.updated_at}
    )
  end

  # One grouped pass over every turn of every conversation on the machine.
  # `bool_or` keeps the mid-turn question in the same round trip as the
  # timestamps; the three maxima are what the idle window and the last-activity
  # fold both read. A conversation with no turns has no row here at all, which
  # is exactly the "never took a turn" case the idle window falls back on.
  defp turn_rollup([]), do: %{}

  defp turn_rollup(conv_ids) do
    Turn
    |> where([t], t.conversation_id in ^conv_ids)
    |> group_by([t], t.conversation_id)
    |> select([t], {
      t.conversation_id,
      max(t.inserted_at),
      max(t.started_at),
      max(t.ended_at),
      fragment("bool_or(? = 'running')", t.status)
    })
    |> Repo.all()
    |> Map.new(fn {id, inserted_at, started_at, ended_at, running?} ->
      {id,
       %{
         turns?: true,
         running?: running? == true,
         newest_turn_inserted_at: inserted_at,
         newest_turn_started_at: started_at,
         newest_turn_ended_at: ended_at
       }}
    end)
  end

  # Keyed by conversation rather than by turn: the turn machine admits one turn
  # at a time per conversation, so "which conversations are mid-turn, and on
  # what runtime" is the shape capacity is counted in — per runtime, since
  # `Machines.Admission` (ADR 0058 stage 8a); the locked count it makes is
  # `Conversations._unsafe_running_turns_elsewhere/3`, and this is the same
  # reading for a caller holding the whole struct.
  defp running_turns(rows, turns) do
    for {id, _status, runtime, _updated_at} <- rows,
        Map.get(turns, id, %{running?: false}).running?,
        into: %{},
        do: {id, runtime}
  end

  defp activity_map(rows, turns) do
    Map.new(rows, fn {id, _status, _runtime, updated_at} ->
      turn_activity =
        Map.get(turns, id, %{
          turns?: false,
          running?: false,
          newest_turn_inserted_at: nil,
          newest_turn_started_at: nil,
          newest_turn_ended_at: nil
        })

      {id, Map.put(turn_activity, :updated_at, updated_at)}
    end)
  end

  defp last_activity_at(sandbox, turns) do
    seeds =
      case sandbox do
        %Sandbox{inserted_at: inserted_at, last_resumed_at: resumed_at} ->
          [inserted_at, resumed_at]

        nil ->
          []
      end

    turn_stamps =
      Enum.flat_map(turns, fn {_id, a} ->
        [a.newest_turn_inserted_at, a.newest_turn_started_at, a.newest_turn_ended_at]
      end)

    case Enum.reject(seeds ++ turn_stamps, &is_nil/1) do
      [] -> nil
      stamps -> Enum.max(stamps, DateTime)
    end
  end

  # Mid-turn, or a turn row inserted or ended inside the window. The three are
  # a disjunction per turn row in the query this replaces, which is the same
  # answer as a disjunction of per-conversation maxima.
  defp turn_activity?(occupancy, conv_id, cutoff) do
    a = Map.fetch!(occupancy.activity, conv_id)

    a.running? or after?(a.newest_turn_inserted_at, cutoff) or
      after?(a.newest_turn_ended_at, cutoff)
  end

  # Only for a conversation with no turns at all: one that has turns is judged
  # by them, because its own `updated_at` moves for bookkeeping it had nothing
  # to do with.
  defp row_activity?(occupancy, conv_id, cutoff) do
    a = Map.fetch!(occupancy.activity, conv_id)

    not a.turns? and after?(a.updated_at, cutoff)
  end

  # `nil > cutoff` is false, matching SQL's NULL comparison in the query this
  # replaces.
  defp after?(nil, _cutoff), do: false
  defp after?(at, cutoff), do: DateTime.compare(at, cutoff) == :gt

  defp unloaded_message(%__MODULE__{sandbox_id: sandbox_id}, fun, field) do
    "#{fun} needs #{inspect(field)}, which this occupancy of sandbox " <>
      "#{inspect(sandbox_id)} was not built with. Build it with " <>
      "Fountain.Machines.Occupancy.load/1 (or from_preloaded/1 for the " <>
      "registry fields) — see the moduledoc for what each constructor fills."
  end
end
