# async: false — the one test here rewrites the global `:sandboxes` config,
# and `Quotas.check_fleet_ceiling/1` reads it on every sandbox reservation in
# the suite.
#
# It used to sit in `quotas_test.exs`, which is `async: true`. While it held
# the ceiling at 2, every async test running beside it saw a ceiling of 2, and
# any of them that reserved a sandbox with two already live got
# `{:error, :fleet_full}` instead of what it asserted. That surfaced as
# `conversations_start_test.exs` failing on its capacity assertions — a
# different one each time, on some seeds and not others, and never locally,
# because CI runs the partition under `--cover` and the timing decides who is
# in the window.
#
# ExUnit runs every async module first and the sync ones one at a time
# afterwards, so a sync module cannot overlap an async one. That is the whole
# fix. Keep this module sync, and keep global-config tests out of
# `quotas_test.exs`.
defmodule Fountain.QuotasFleetCeilingTest do
  use Fountain.DataCase, async: false

  alias Fountain.Quotas

  describe "the fleet ceiling" do
    test "refuses the reservation once every slot is live, whoever holds them" do
      cfg = Application.get_env(:fountain, :sandboxes)
      on_exit(fn -> Application.put_env(:fountain, :sandboxes, cfg) end)
      Application.put_env(:fountain, :sandboxes, Keyword.put(cfg, :fleet_ceiling, 2))

      other = insert_active_user()
      insert_sandbox(user_id: other.id, status: "ready")
      insert_sandbox(user_id: other.id, status: "starting")

      assert {:error, :fleet_full} = Quotas.check_fleet_ceiling(provider: "sprites")

      assert {:error, :fleet_full} =
               Quotas.with_sandbox_reservation([provider: "sprites"], fn -> {:ok, :never} end)

      # A suspended sandbox is not compute and does not hold a slot.
      Fountain.Repo.update_all(Fountain.Conversations.Sandbox, set: [status: "suspended"])
      assert :ok = Quotas.check_fleet_ceiling(provider: "sprites")

      assert {:ok, :ran} =
               Quotas.with_sandbox_reservation([provider: "sprites"], fn -> {:ok, :ran} end)
    end

    test "each provider has its own ceiling, defaulting to fleet_ceiling (#2667)" do
      cfg = Application.get_env(:fountain, :sandboxes)
      on_exit(fn -> Application.put_env(:fountain, :sandboxes, cfg) end)

      Application.put_env(
        :fountain,
        :sandboxes,
        cfg |> Keyword.put(:fleet_ceiling, 2) |> Keyword.put(:fleet_ceilings, %{"e2b" => 1})
      )

      assert Quotas.fleet_ceiling(:e2b) == 1
      assert Quotas.fleet_ceiling("sprites") == 2

      other = insert_active_user()
      insert_sandbox(user_id: other.id, status: "ready", provider: "e2b")

      assert {:error, :fleet_full} = Quotas.check_fleet_ceiling(provider: "e2b")
      assert :ok = Quotas.check_fleet_ceiling(provider: "sprites")

      insert_sandbox(user_id: other.id, status: "ready", provider: "sprites")
      assert :ok = Quotas.check_fleet_ceiling(provider: "sprites")

      insert_sandbox(user_id: other.id, status: "starting", provider: "sprites")
      assert {:error, :fleet_full} = Quotas.check_fleet_ceiling(provider: "sprites")

      assert {:error, :fleet_full} =
               Quotas.with_sandbox_reservation([provider: "sprites"], fn -> {:ok, :never} end)
    end

    test "a machine being destroyed cannot be excluded out of the count" do
      # ADR 0058 stage 9a, and one of the two sites my revert sweep missed:
      # `check_fleet_ceiling/1` repeats `active_sandbox_count/2`'s exclusion
      # clause, so it is a second behaviour wearing identical text.
      #
      # The exclusion exists for a wake that provisions a replacement before
      # retiring the machine it replaces. A machine somebody has asked to
      # destroy is not replaced and not yet gone — it is still at the provider,
      # still billing, until the reaper's driver ends it — so excluding it would
      # let the deployment start one machine over its ceiling. The row here
      # carries the stamp and neither fence column, which is the shape stage 9b
      # leaves.
      cfg = Application.get_env(:fountain, :sandboxes)
      on_exit(fn -> Application.put_env(:fountain, :sandboxes, cfg) end)
      Application.put_env(:fountain, :sandboxes, Keyword.put(cfg, :fleet_ceiling, 1))

      other = insert_active_user()
      going = insert_sandbox(user_id: other.id, status: "ready")

      put_lease(going, transition: "destroying", transition_reason: "terminated")

      assert {:error, :fleet_full} =
               Quotas.check_fleet_ceiling(provider: "sprites", exclude: going.id)

      # And the symmetric case: a machine nobody is destroying really is
      # excludable, which is what the option is for.
      put_lease(going.id, transition: nil, transition_reason: nil)

      assert :ok = Quotas.check_fleet_ceiling(provider: "sprites", exclude: going.id)
    end
  end
end
