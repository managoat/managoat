defmodule Fountain.Machines.DurableDestroyingTest do
  @moduledoc """
  `destroying` is the one durable transition (ADR 0058 stage 9a).

  Four of the five transitions are *abandonable*: a stamp whose lease has
  expired is an owner that died, and three doors clear it on sight so the
  machine can be used again — `Conversations.register_server/2`,
  `Resume.under_lease/3` and `Provision.clear_foreign_stamp/2`. Stage 6a made
  that the rule and it is the right one for `parking`, `resuming`,
  `provisioning` and `retargeting`.

  Until stage 9a that was only *safe* because `reset_requested_at` and
  `teardown_requested_at` sat underneath: every `destroying` stamp arrived with
  a fence, and every reader answered the fence first. 9a made the stamp itself
  the rule — `destroying` refuses regardless of lease, no reader clears it, and
  `SandboxReaper.sweep_fenced_teardowns/0` drives it to terminal — and stage 9b
  stopped reading the columns, so the stamp is the whole of the intent.

  **Every row here carries the stamp alone**, which is what the fences write
  since 9b. The rows are forged with `Ecto.Changeset.change/2` for the reason
  the other files here forge them: no changeset casts the stamp.

  What is covered elsewhere, so that a reader looking for it does not conclude
  it is missing: the reaper's driver and its counters in
  `workers/sandbox_reaper_test.exs`; the resume's refusal in `resume_test.exs`;
  the turn admission's in `admission_test.exs`; the boot sweep's in
  `conversations/rehydrator_test.exs`; the destroy protocol's continuation in
  `destroy_test.exs`.
  """
  use Fountain.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations
  alias Fountain.Conversations.{Lifecycle, Sandbox, Wake}
  alias Fountain.Machines.{Lease, Machine, Provision}
  alias Fountain.Workers.SandboxReaper

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        agent_id: agent.id,
        environment_id: agent.environment_id,
        status: "ready",
        machine_name: "durable-#{System.unique_integer([:positive])}"
      )

    conv =
      insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    %{user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  defp stamp(sandbox, changes), do: put_lease(sandbox, changes)

  # The intent, and nothing else. The lease is spent and released, which is what
  # makes every refusal below a statement about the stamp rather than about an
  # owner at work.
  defp destroying(sandbox, reason \\ "terminated") do
    stamp(sandbox,
      transition: "destroying",
      transition_reason: reason,
      lease_epoch: 1,
      lease_node: nil
    )
  end

  defp conv_with_sandbox(ctx), do: Repo.reload!(ctx.conv) |> Repo.preload(:sandbox)

  defp row(ctx), do: Repo.reload!(ctx.sandbox)

  describe "the stamp is not a lease reading" do
    test "a lease-less destroying row is still not busy", ctx do
      # The distinction the whole stage rests on, stated once. `Machine.busy?/2`
      # is unchanged and still answers "is an owner mid-operation" — a live
      # lease and nothing else (stage 6a). A `destroying` row with a dead lease
      # is not an owner at work, and every refusal below is therefore a *fence*
      # reading rather than a busy one. Conflating the two is what 6a round 1
      # found and reverted: it answered 503, for up to 75 minutes, on machines
      # `main` handed out at once.
      refute Machine.busy?(destroying(ctx.sandbox))
    end
  end

  describe "the fence writers stamp it" do
    test "the teardown fence writes the stamp in the same commit as the columns", ctx do
      {:ok, fenced} =
        Lifecycle.fence_sandbox_for_teardown(ctx.sandbox,
          actor: "system:conversation_server",
          reason: "conversation_terminated",
          transition_reason: :terminated
        )

      assert fenced.transition == "destroying"
      # The destroy vocabulary, not the event's — see the describe below.
      assert fenced.transition_reason == "terminated"
    end

    test "a reason that is not a word at all falls back rather than raising", ctx do
      # Blocker G's other half. `:reason` carries interpolated provider errors
      # on several paths, and the first draft read it straight into the
      # changeset — an `Ecto.ChangeError` from inside the fence's transaction,
      # a crash path that did not exist before this stage.
      {:ok, fenced} =
        Lifecycle.fence_sandbox_for_teardown(ctx.sandbox,
          actor: "self",
          transition_reason: {:unexpected, %{shape: true}}
        )

      assert fenced.transition_reason == "teardown"
    end

    test "a fence with no reason of its own stamps the word both ends default to", ctx do
      # `:teardown` is this module's event default *and*
      # `Destroy.reason_from_string/1`'s fallback, so a caller that names
      # neither leaves one unknown rather than two.
      {:ok, fenced} = Lifecycle.fence_sandbox_for_teardown(ctx.sandbox, actor: "self")

      assert fenced.transition_reason == "teardown"

      assert [event] =
               Fountain.Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.teardown")

      assert event.metadata["reason"] == "teardown"
    end

    test "a repeated fence leaves the stamp and the reason it already had", ctx do
      {:ok, _} =
        Lifecycle.fence_sandbox_for_teardown(ctx.sandbox,
          actor: "self",
          reason: "first",
          transition_reason: :terminated
        )

      {:ok, again} =
        Lifecycle.fence_sandbox_for_teardown(row(ctx),
          actor: "self",
          reason: "again",
          transition_reason: :admin_reap
        )

      assert again.transition_reason == "terminated"
      assert [_one] = Fountain.Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.teardown")
    end
  end

  describe "Lease.cas_update/4 keeps the stamp" do
    setup ctx do
      {:ok, epoch} = Lease.claim(ctx.sandbox.id)
      %{epoch: epoch}
    end

    test "a write that would clear it on a live row leaves it, and says so", ctx do
      destroying(ctx.sandbox)

      # `Machines.Park`'s finalize, verbatim: the machine really is suspended
      # and the row must say so, but a fence that landed during the suspend has
      # not been withdrawn by it. Both halves are asserted, because a primitive
      # that refused the write outright would strand the row `parking` for ever.
      assert {:ok, written} =
               Lease.cas_update(ctx.sandbox.id, ctx.epoch,
                 status: "suspended",
                 transition: nil,
                 transition_reason: nil
               )

      assert written.status == "suspended"
      assert written.transition == "destroying"
      assert written.transition_reason == "terminated"
    end

    test "a write that retires the row clears it, because that is the finalize", ctx do
      destroying(ctx.sandbox)

      assert {:ok, written} =
               Lease.cas_update(ctx.sandbox.id, ctx.epoch,
                 status: "terminated",
                 transition: nil,
                 transition_reason: nil
               )

      assert written.status == "terminated"
      assert is_nil(written.transition)
    end

    test "a write to an already terminal row clears it, because that is leftovers", ctx do
      # `Destroy.clear_stale_transition/2`'s write: a status-free clear of a
      # stamp on a row that has already stopped. Preserving it here would make
      # "is this machine mid-destroy?" unanswerable from the row for ever,
      # which is the column's only job.
      ctx.sandbox |> destroying() |> stamp(status: "terminated")

      assert {:ok, written} =
               Lease.cas_update(ctx.sandbox.id, ctx.epoch,
                 transition: nil,
                 transition_reason: nil
               )

      assert is_nil(written.transition)
      assert is_nil(written.transition_reason)
    end

    test "a re-stamp of destroying goes through, with the new reason", ctx do
      destroying(ctx.sandbox, "idle")

      assert {:ok, written} =
               Lease.cas_update(ctx.sandbox.id, ctx.epoch,
                 transition: "destroying",
                 transition_reason: "max_lifetime"
               )

      assert written.transition == "destroying"
      assert written.transition_reason == "max_lifetime"
    end

    test "a write naming transition alone does not erase the reason", ctx do
      # Blocker G. `Resume.stamp/2` writes `[transition: "resuming"]` and
      # nothing else, and `update_all` has always written the columns it is
      # given and no others. The first draft moved both columns into `CASE`
      # fragments whatever the caller named, so the reason's `ELSE` branch was
      # a `nil` nobody asked for — a stamp that named one column silently
      # erased the other.
      stamp(ctx.sandbox, transition: nil, transition_reason: "why-this-machine-matters")

      assert {:ok, written} =
               Lease.cas_update(ctx.sandbox.id, ctx.epoch, transition: "resuming")

      assert written.transition == "resuming"
      assert written.transition_reason == "why-this-machine-matters"
    end

    test "a write naming both still writes both", ctx do
      # The symmetric case: the guard is the caller's own key, so naming the
      # reason still sets it.
      stamp(ctx.sandbox, transition: nil, transition_reason: "old")

      assert {:ok, written} =
               Lease.cas_update(ctx.sandbox.id, ctx.epoch,
                 transition: "resuming",
                 transition_reason: "new"
               )

      assert written.transition_reason == "new"
    end

    test "a write naming neither column is untouched by the rule", ctx do
      destroying(ctx.sandbox)

      assert {:ok, written} =
               Lease.cas_update(ctx.sandbox.id, ctx.epoch, provider_meta: %{"checkpoint" => "c1"})

      assert written.provider_meta == %{"checkpoint" => "c1"}
      assert written.transition == "destroying"
    end

    test "another verb's stamp is still cleared, which is stage 6a's rule intact", ctx do
      stamp(ctx.sandbox, transition: "parking", transition_reason: "idle")

      assert {:ok, written} =
               Lease.cas_update(ctx.sandbox.id, ctx.epoch,
                 transition: nil,
                 transition_reason: nil
               )

      assert is_nil(written.transition)
    end

    test "refuse_fenced refuses the stamp, as it refuses the two columns", ctx do
      # `Machines.Provision`'s finalize asks for this: a `ready` write must not
      # land on a machine somebody asked to be destroyed while it was being
      # built. The columns carried that until 9a; the stamp has to carry it
      # after 9b, and the diagnosis has to agree with the write.
      destroying(ctx.sandbox)

      assert {:error, :fenced} =
               Lease.cas_update(ctx.sandbox.id, ctx.epoch, [status: "ready"], refuse_fenced: true)

      assert row(ctx).status == "ready"
    end
  end

  describe "the reason on the row is the destroy vocabulary" do
    # Surfaces S1. `transition_reason` has always held the *destroy* vocabulary,
    # because `Destroy.stamp_then_destroy/3` wrote it. Stage 9a made the fence
    # stamp first and the protocol continue from that stamp without writing its
    # own, so a fence that stamped its own event wording would have changed what
    # the column means — and `SandboxReaper`'s driver, which reads it back to
    # finish an abandoned destroy, would record `teardown` where the owner
    # recorded `terminated`, for the same machine in the same situation.

    test "every term in the vocabulary survives a round trip", _ctx do
      # Total by construction, and driven term by term rather than by sampling:
      # the first version used `String.to_existing_atom/1`, where whether a term
      # converts depends on what else is loaded. Six of the twelve strings this
      # column can hold raised under `mix run` and fell back to `:teardown`.
      for reason <- Fountain.Machines.Destroy.reasons() do
        assert Fountain.Machines.Destroy.reason_from_string(to_string(reason)) == reason
      end
    end

    test "a word from outside the vocabulary is the one documented fallback", _ctx do
      # A row written by an older replica, or by hand. Finishing its destroy
      # with a generic word beats refusing to finish it — and `:teardown` is the
      # same word `Lifecycle`'s fence defaults its own event to, so the unknown
      # is spelled the same at both ends.
      for other <- ["conversation_terminated", "agent_deleted", "sandbox_expired", "", nil] do
        assert Fountain.Machines.Destroy.reason_from_string(other) == :teardown
      end
    end

    test "the fence stamps what the owner would have stamped", ctx do
      # The parity S1 says was claimed and untrue. The fence's own `:reason` is
      # the event's wording and is deliberately different; what lands on the row
      # is the destroy reason, so an operator reading the row and an operator
      # reading the trail see one story.
      {:ok, fenced} =
        Lifecycle.fence_sandbox_for_teardown(ctx.sandbox,
          actor: "admin",
          reason: "reaped",
          transition_reason: :admin_reap
        )

      assert fenced.transition_reason == "admin_reap"
      assert Fountain.Machines.Destroy.reason_from_string(fenced.transition_reason) == :admin_reap

      # And the event keeps its own word, which is the half that must not move.
      assert [event] =
               Fountain.Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.teardown")

      assert event.metadata["reason"] == "reaped"
    end

    test "a terminate and the sweep that finishes it record the same reason", ctx do
      # End to end, and the shape the claim was actually about: a conversation
      # terminate fences with `conversation_terminated` and destroys with
      # `:terminated`. If its owner dies between the two, the driver has to
      # reach the same `:terminated` — where reading the fence's word would have
      # given `:teardown`.
      {:ok, fenced} =
        Lifecycle.fence_sandbox_for_teardown(ctx.sandbox,
          actor: "self",
          reason: "conversation_terminated",
          transition_reason: :terminated
        )

      assert fenced.transition_reason == "terminated"
      assert Fountain.Machines.Destroy.reason_from_string(fenced.transition_reason) == :terminated
    end
  end

  describe "the readers refuse it, lease or no lease" do
    test "Wake.maybe_reuse_sandbox/1 answers the fence's word, not the lease's", ctx do
      reject(Managoat.Sandbox, :get, 1)
      destroying(ctx.sandbox)

      assert {:error, :sandbox_reset_pending} =
               Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "Wake reuses a terminal row's machine not at all, and does not 409 it", ctx do
      # The ordering every reader shares: a terminal row's stamp is leftovers,
      # and the answer there is a fresh machine rather than a retry.
      ctx.sandbox |> destroying() |> stamp(status: "terminated")

      assert :create_new = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "register_server/2 refuses it rather than clearing it", ctx do
      # The door that would otherwise delete the intent: it clears a lease-less
      # stamp under the sandbox lock on its way to `start_child`. Both halves
      # are asserted — the refusal, and that the stamp is still there.
      destroying(ctx.sandbox)

      assert {:error, :sandbox_reset_pending} =
               Conversations.register_server(ctx.sandbox.id, {Agent, fn -> :ok end})

      assert row(ctx).transition == "destroying"
    end

    test "register_server/2 clears abandoned stamps that do not require recovery", ctx do
      # Destroy intent and unfinished exec readiness both require their owner
      # protocol; registration can still clear the other abandoned operations.
      for transition <- Sandbox.transitions(), transition not in ["destroying", "resuming"] do
        stamp(ctx.sandbox, transition: transition, transition_reason: "x")

        {:ok, _pid} =
          Conversations.register_server(ctx.sandbox.id, %{
            id: make_ref(),
            start: {Agent, :start_link, [fn -> :ok end]}
          })

        assert is_nil(row(ctx).transition), "#{transition} outlived the registration door"
      end
    end

    test "Provision refuses to build a machine somebody asked to destroy", ctx do
      # Building one would reserve compute at the provider for a machine
      # somebody has already said goodbye to, and then write `ready` over a row
      # the driver is about to finish.
      stamp(ctx.sandbox, status: "pending")
      destroying(ctx.sandbox)
      reject(Managoat.Sandbox, :create, 2)

      assert {:error, :fenced} =
               capture_answer(fn ->
                 Provision.run(ctx.sandbox.id, fn _sandbox, _handle -> {:ok, %{}} end,
                   actor: "self",
                   reason: :initial
                 )
               end)

      assert row(ctx).transition == "destroying"
    end

    test "the reattach door will not confirm a machine somebody asked to destroy", ctx do
      # Blocker B, found by two reviewers and missed by my own revert sweep.
      # `confirm_up/2` is the reattach arm: a server that has asked the provider
      # and been told its machine is up writes `ready` on the row. On a
      # `destroying` row that write puts a suspended machine back to `ready`
      # with `last_resumed_at`, a `sandbox.resumed` event and a
      # `sandbox_resumed` usage row — **billing reopened on a machine somebody
      # asked to destroy**, from a reachable caller.
      #
      # `confirm_under_lease/3` carries the same fence as `admissible/1` and
      # needs its own case, because a clause repeated at two sites is two
      # behaviours however identical the text.
      stamp(ctx.sandbox, status: "suspended")
      destroying(ctx.sandbox)

      assert {:error, :fenced} =
               capture_answer(fn -> Provision.confirm_up(ctx.sandbox.id, actor: "self") end)

      kept = row(ctx)
      assert kept.status == "suspended"
      assert kept.transition == "destroying"
      assert is_nil(kept.last_resumed_at)

      assert Fountain.Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.resumed") == []
    end
  end

  describe "the reaper's other passes leave it alone" do
    # The idle/ceiling sweep's half of this lives in
    # `workers/sandbox_reaper_test.exs`: it has to set the two lifetime bounds,
    # which is application env, and this module is `async: true`
    # (`async_global_config_guardrail_test.exs`).

    test "release_stuck_sandboxes/0 does not fail a machine that is being destroyed", ctx do
      # Writing `failed` over it would leave the stamp and the sprite behind
      # and take the row away from the driver, which is the pass that finishes
      # what the fence asked for.
      stamp(ctx.sandbox, status: "pending")
      destroying(ctx.sandbox)
      age(ctx.sandbox, 120)

      assert 0 = SandboxReaper.release_stuck_sandboxes()
      assert row(ctx).status == "pending"
    end

    test "release_stuck_sandboxes/0 still fails an ordinary stuck row", ctx do
      stamp(ctx.sandbox, status: "pending")
      age(ctx.sandbox, 120)

      capture_log(fn -> assert 1 = SandboxReaper.release_stuck_sandboxes() end)
      assert row(ctx).status == "failed"
    end
  end

  describe "Quotas" do
    test "a machine being destroyed holds its slot until the row is terminal", ctx do
      assert active_sandbox_count(ctx.user.id) == 1

      # Parked, so the status counts for nothing, and stamped with a dead lease
      # so no lease reading counts it either. What holds the slot is the intent:
      # the machine is still at the provider and still billing until the driver
      # ends it.
      ctx.sandbox |> stamp(status: "suspended") |> destroying()
      assert active_sandbox_count(ctx.user.id) == 1

      stamp(row(ctx), status: "terminated")
      assert active_sandbox_count(ctx.user.id) == 0
    end

    test "a suspended machine nobody is destroying holds none", ctx do
      stamp(ctx.sandbox, status: "suspended")
      assert active_sandbox_count(ctx.user.id) == 0
    end

    test "the replacement exclusion cannot spend the slot of a machine being destroyed", ctx do
      destroying(ctx.sandbox)

      assert Fountain.Quotas.fleet_count(exclude: ctx.sandbox.id) == 1
    end
  end

  defp age(sandbox, minutes) do
    at = DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id), set: [updated_at: at])
  end

  defp capture_answer(fun) do
    key = :erlang.make_ref()
    Process.put(key, nil)
    capture_log(fn -> Process.put(key, fun.()) end)
    Process.get(key)
  end
end
