defmodule Fountain.Machines.PolicyTest do
  @moduledoc """
  What a reclaim does to a machine (ADR 0058 stage 7a; ADR 0017). An idle
  machine parks where the provider can. The ceiling destroys an implicit
  workspace's machine, and parks an explicit one's where the provider can
  (ADR 0097).
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations.Lifecycle
  alias Fountain.Machines.Policy

  defp can_park, do: stub(Managoat.Sandbox, :supports?, fn _p, cap -> cap == :suspend end)
  defp cannot_park, do: stub(Managoat.Sandbox, :supports?, fn _p, _cap -> false end)

  describe "idle_action/1" do
    test "a provider that can park, parks" do
      can_park()
      assert Policy.idle_action(:sprites) == :suspend
    end

    test "a provider that cannot, destroys — the cost control wins" do
      cannot_park()
      assert Policy.idle_action(:sprites) == :destroy
    end
  end

  describe "reclaim_action/3" do
    test "the idle bound parks where the provider can, and destroys where it cannot" do
      for kind <- [:implicit, :explicit] do
        can_park()
        assert Policy.reclaim_action(:idle, :sprites, kind) == :park
        cannot_park()
        assert Policy.reclaim_action(:idle, :sprites, kind) == :destroy
      end
    end

    test "the ceiling destroys an implicit workspace's machine, whatever the provider" do
      can_park()
      assert Policy.reclaim_action(:max_lifetime, :sprites, :implicit) == :destroy
      cannot_park()
      assert Policy.reclaim_action(:max_lifetime, :sprites, :implicit) == :destroy
    end

    test "the ceiling parks an explicit workspace's machine where the provider can" do
      can_park()
      assert Policy.reclaim_action(:max_lifetime, :sprites, :explicit) == :park
      cannot_park()
      assert Policy.reclaim_action(:max_lifetime, :sprites, :explicit) == :destroy
    end
  end

  describe "Lifecycle.ceiling_action/2" do
    test "reads the kind of the conversation's workspace" do
      can_park()
      handle = Managoat.Sandbox.build_handle(:sprites, "whatever")
      implicit = insert_sandbox(status: "ready")
      user = insert_verified_user()
      workspace = insert_workspace(user_id: user.id, implicit: false, name: "mine")
      explicit = insert_sandbox(user_id: user.id, workspace_id: workspace.id, status: "ready")
      legacy = insert_sandbox(status: "ready", workspace_id: nil)

      assert Lifecycle.ceiling_action(implicit.id, handle) == :destroy
      assert Lifecycle.ceiling_action(explicit.id, handle) == :park
      assert Lifecycle.ceiling_action(legacy.id, handle) == :destroy
      assert Lifecycle.ceiling_action(nil, handle) == :destroy
    end
  end

  describe "the call sites delegate" do
    test "Lifecycle.idle_action/1 is this one" do
      cannot_park()
      assert Lifecycle.idle_action(:sprites) == Policy.idle_action(:sprites)
    end

    test "Lifecycle.idle_machine_action/1 is reclaim_action(:idle, …)" do
      can_park()
      handle = Managoat.Sandbox.build_handle(:sprites, "whatever")
      assert Lifecycle.idle_machine_action(handle) == :park
    end
  end
end
