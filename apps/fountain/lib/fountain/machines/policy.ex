defmodule Fountain.Machines.Policy do
  @moduledoc """
  What a machine's reclaim means, as decisions rather than as branches (ADR
  0058, stage 7a).

  Until #2676 this module also held what the two sandbox modes meant: the
  default mode a launch got, whether the last detach kept a persistent home,
  and whether the max-lifetime ceiling parked one. Persistent homes are gone;
  what is left here is the provider's half, whether an idle machine can be
  parked (ADR 0017), and since ADR 0097 step 4 the workspace's half of the
  ceiling: an explicit workspace's machine is parked there, an implicit one's
  destroyed. Whether a detach keeps the machine is the same split, decided in
  `Fountain.Machines.Binding.detach/2`.

  ## What deliberately did not move

  **`Lifecycle.check/4`, the clock.** Whether a bound has been crossed is a
  measurement, not a policy, and `Park.still_expired?/3` and
  `SandboxReaper.expired?/2` both re-run it. Moving it would separate it from
  the two `explain/2` strings that have to stay honest about what each bound
  does (a suspend keeps the disk; a destroy does not).
  """

  @doc """
  What crossing the idle bound does on this provider: `:suspend` where the disk
  can be kept, `:destroy` where it cannot.

  The capability question, and the whole of ADR 0017's degradation. A provider
  that advertises `:suspend` parks with the disk preserved — implicit
  scale-to-zero for Sprites, an explicit pause for E2B. A provider without it would leave an
  idle machine billing, so the cost control wins over the agent's memory,
  exactly as the max-lifetime ceiling already prices it.

  A capability, not a promise about a particular machine: `Machines.Park` asks
  this again under the lease, because a pre-lease verdict is stale by
  construction, and the provider's answer to `suspend/1` is the one that
  decides.
  """
  @spec idle_action(atom()) :: :suspend | :destroy
  def idle_action(provider) when is_atom(provider) do
    if Managoat.Sandbox.supports?(provider, :suspend), do: :suspend, else: :destroy
  end

  @doc """
  What a reclaim does to this machine: `:park` it, or `:destroy` it, by the
  bound it crossed, its provider, and the kind of workspace that owns it
  (ADR 0097, which amends 0017's ceiling table).

  | Bound | Workspace | Provider can park | Provider cannot park |
  |---|---|---|---|
  | `:idle` | either | `:park` | `:destroy` |
  | `:max_lifetime` | implicit | `:destroy` | `:destroy` |
  | `:max_lifetime` | explicit | `:park` | `:destroy` |

  An idle machine is parked because the disk is the agent's memory (#649 proved
  it cannot be rebuilt on a fresh one). The ceiling exists for the
  conversation that never stops being busy, so it fires with work in flight
  and reclaims the machine whatever the activity. On an implicit workspace,
  the machine of one conversation, it is destroyed, as it has been since
  persistent homes went (#2676). On an explicit one, a disk the caller kept on
  purpose, it is parked instead, after every running turn on it is
  interrupted (`Fountain.Machines.Park`'s ceiling cut), so the park leaves
  nothing running unattended; a provider that cannot park still destroys.
  """
  @spec reclaim_action(:idle | :max_lifetime, atom(), :implicit | :explicit) :: :park | :destroy
  def reclaim_action(:max_lifetime, provider, :implicit) when is_atom(provider), do: :destroy

  def reclaim_action(_bound, provider, kind)
      when is_atom(provider) and kind in [:implicit, :explicit] do
    case idle_action(provider) do
      :suspend -> :park
      :destroy -> :destroy
    end
  end
end
