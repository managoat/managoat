defmodule Fountain.Machines.BootSweep do
  @moduledoc """
  Clears the machine leases and abandoned operation stamps an earlier boot
  left behind (`Fountain.Machines.Lease.sweep_boot/0`, ADR 0072).

  A child of `Fountain.Application`, straight after the migrator, so it runs
  once the schema is current and before Oban, the endpoint or the rehydrator
  can claim anything. It does its work in `start_link/1` and returns
  `:ignore`, so the supervisor waits for it and keeps no process.

  First it runs `Fountain.Workspaces._unsafe_reconcile_live/0` (ADR 0097, step 3a):
  every live sandbox gets a workspace and every conversation points at its
  sandbox's, which a migration alone cannot promise once a rollback to a
  release before ADR 0097 has run and been rolled forward again.

  The lease sweep also carries onto the workspaces the stamps a release before
  ADR 0097 step 3b wrote on sandbox rows, and copies the workspaces' columns
  back onto their sandboxes for a rollback, so since 3b it is more than
  tidiness on a deployment that rolled back.

  A failure is logged, not raised: every lease of an earlier boot already reads
  as dead (`Lease.live?/1`), the tidying half (no stale holder on the admin
  table, no stale `parking` stamp for the next owner to take over) can wait a
  boot, and the carry and the copy are retried by the next one; a database
  hiccup at boot must not stop the node starting.

  `config :fountain, :machine_boot_sweep, false` turns it off; the test suite
  does, and calls `Lease.sweep_boot/0` itself.
  """

  require Logger

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc false
  def start_link(_opts) do
    if Application.get_env(:fountain, :machine_boot_sweep, true), do: sweep()
    :ignore
  end

  # The workspaces first: a live sandbox an earlier release made without one
  # gets one, and its stamps are carried, before the lease sweep reads them.
  # Each step logs its own failure and the other still runs.
  defp sweep do
    reconcile_workspaces()
    sweep_leases()
  end

  defp reconcile_workspaces do
    # ownership: a boot-time system sweep over every account, before any request.
    _ = Fountain.Workspaces._unsafe_reconcile_live()
  rescue
    error ->
      Logger.error("machine boot sweep: workspace reconcile failed: #{Exception.message(error)}")
  end

  defp sweep_leases do
    _ = Fountain.Machines.Lease.sweep_boot()
  rescue
    error ->
      Logger.error("machine boot sweep failed: #{Exception.message(error)}")
  end
end
