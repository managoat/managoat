defmodule Fountain.Conversations.TeardownFenceTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Audit
  alias Fountain.Conversations.Lifecycle

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)

    home =
      insert_sandbox(user_id: user.id, agent_id: agent.id, mode: "persistent", status: "ready")

    %{user: user, agent: agent, home: home}
  end

  test "records the first fence after commit with caller attribution", ctx do
    reject(Managoat.Sandbox.Sprites, :destroy, 1)

    expect(Audit, :record, fn attrs ->
      refute Repo.in_transaction?()
      assert Repo.reload!(ctx.home).transition == "destroying"
      Mimic.call_original(Audit, :record, [attrs])
    end)

    assert {:ok, fenced} =
             Lifecycle.fence_sandbox_for_teardown(ctx.home,
               actor: "ui",
               request_ip: "192.0.2.1",
               reason: "agent_deleted"
             )

    assert fenced.status == "ready"
    assert fenced.transition == "destroying"
    assert fenced.transition_reason == "teardown"
    assert active_sandbox_count(ctx.user.id) == 1
    assert [event] = events(ctx)
    assert event.actor == "ui"
    assert event.request_ip == "192.0.2.1"
    assert event.resource_type == "sandbox"
    assert event.resource_id == ctx.home.id
    assert event.metadata == %{"reason" => "agent_deleted", "provider" => ctx.home.provider}

    # A repeat writes nothing — not even a new reason — and records no second
    # intent.
    assert {:ok, repeated} =
             Lifecycle.fence_sandbox_for_teardown(ctx.home, transition_reason: :admin_reap)

    assert repeated.transition_reason == "teardown"
    assert repeated.updated_at == fenced.updated_at
    assert [^event] = events(ctx)
  end

  for status <- ["terminated", "failed"] do
    test "a #{status} sandbox needs no new fence or request event", ctx do
      ctx.home |> Ecto.Changeset.change(status: unquote(status)) |> Repo.update!()
      reject(Audit, :record, 1)
      reject(Managoat.Sandbox.Sprites, :destroy, 1)

      assert {:ok, retired} = Lifecycle.fence_sandbox_for_teardown(ctx.home)
      assert retired.status == unquote(status)
      refute retired.transition == "destroying"
      assert events(ctx) == []
    end
  end

  test "escalating a reset records forced intent and keeps the machine fenced", ctx do
    # A reset's stamp is not a teardown's, so a forced fence on top of one is
    # new intent: the reason is rewritten — the machine is going away for the
    # newer reason — and the event is recorded. The machine never stops being
    # fenced along the way. A second forced fence is then a repeat.
    ctx.home
    |> put_lease(transition: "destroying", transition_reason: "reset")

    reject(Managoat.Sandbox.Sprites, :destroy, 1)

    assert {:ok, fenced} =
             Lifecycle.fence_sandbox_for_teardown(ctx.home,
               actor: "ui",
               transition_reason: :admin_reap
             )

    assert fenced.transition == "destroying"
    assert fenced.transition_reason == "admin_reap"
    assert [event] = events(ctx)
    assert event.actor == "ui"
    assert {:ok, repeated} = Lifecycle.fence_sandbox_for_teardown(ctx.home)
    assert repeated.transition_reason == "admin_reap"
    assert [^event] = events(ctx)
  end

  test "general sandbox attributes cannot forge or clear forced intent", ctx do
    assert {:ok, fenced} = Lifecycle.fence_sandbox_for_teardown(ctx.home)

    for {field, value} <- [transition: nil, transition: "parking", transition_reason: "reset"] do
      changeset = Fountain.Conversations.Sandbox.changeset(fenced, %{field => value})

      refute Map.has_key?(changeset.changes, field)
      assert Ecto.Changeset.get_field(changeset, field) == Map.fetch!(fenced, field)
    end
  end

  test "a missing sandbox returns an error without an audit or provider call", ctx do
    Repo.delete!(ctx.home)
    reject(Audit, :record, 1)
    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    assert {:error, :not_found} = Lifecycle.fence_sandbox_for_teardown(ctx.home)
    assert events(ctx) == []
  end

  test "an enclosing transaction cannot create a fence or audit event", ctx do
    reject(Audit, :record, 1)
    reject(Managoat.Sandbox.Sprites, :destroy, 1)

    assert {:ok, {:error, :provider_transaction_open}} =
             Repo.transaction(fn ->
               Lifecycle.fence_sandbox_for_teardown(ctx.home)
             end)

    refute Repo.reload!(ctx.home).transition == "destroying"
    assert events(ctx) == []
  end

  def remove_listed_home(_event, _measurements, metadata, ctx) do
    # The query has returned its snapshot, but the teardown loop has not yet
    # tried to fence that row. Reproduce the deletion race without timing sleeps.
    if self() == ctx.owner and metadata.source == "sandboxes" and
         String.starts_with?(metadata.query, "SELECT") do
      :telemetry.detach(ctx.handler)
      Repo.delete!(ctx.home)
      send(ctx.owner, :home_removed_after_listing)
    end
  end

  defp events(ctx) do
    Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.teardown_requested")
  end
end
