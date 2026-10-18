defmodule Fountain.Machines do
  @moduledoc """
  The machine — a sandbox with one owner (ADR 0058).

  A sandbox's workspace gets one `Fountain.Machines.Machine` process,
  registered in `Fountain.MachineRegistry` under the workspace id, with the
  lease on the workspace's row (ADR 0097, step 3b). It is the only writer of
  `sandboxes.status` and the only caller of the provider's create, resume,
  suspend and destroy. It answers one read-only question,
  `Machine.who_is_here/1`, and owns six protocols: `Fountain.Machines.Destroy`
  (stage 5), `Park` (6b), `Resume` (7a), `Provision` (7b), `Admission` (8a)
  and `Binding` (8b) — attach, detach, the skills record and the Codex auth
  binding.

  The protocol is what makes a verb correct: the lease it takes on the row, the
  compare-and-set it finalizes with and the event it records. The process in
  front of it is what serializes two operations on one machine, so the second
  finds the first's result instead of waiting out its lease. Until stage 9b a
  runtime flag, `MACHINE_OWNER_ENABLED`, chose between running a verb in the
  owner and running it inline on its caller; stage 9b deleted the flag, and
  the owner is the only path.
  """
end
