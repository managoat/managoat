defmodule Fountain.Conversations.LiveMachineNameTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox

  for status <- ~w(pending starting ready suspended) do
    test "a #{status} machine name cannot belong to a second live row" do
      user = insert_verified_user()
      first = insert_sandbox(user_id: user.id, status: unquote(status))

      assert {:error, changeset} = duplicate(first, user.id)

      assert changeset.errors[:machine_name] ==
               {"is already assigned to a live sandbox on this provider",
                [constraint: :unique, constraint_name: "sandboxes_live_machine_name_index"]}

      assert Repo.reload!(first) == first
    end
  end

  test "the provider's namespace is unique across accounts too" do
    first = insert_sandbox(status: "ready")
    other = insert_verified_user()
    assert {:error, changeset} = duplicate(first, other.id)
    assert Keyword.has_key?(changeset.errors, :machine_name)
  end

  test "different providers may use the same name" do
    first = insert_sandbox(status: "ready")

    assert {:ok, second} =
             Fountain.Machines.Provision.reserve(%{
               machine_name: first.machine_name,
               user_id: first.user_id,
               workspace_id: insert_workspace(user_id: first.user_id).id,
               provider: "e2b",
               status: "ready"
             })

    assert second.id != first.id
  end

  for status <- ~w(terminated failed) do
    test "#{status} history does not prevent a fresh live row" do
      history = insert_sandbox(status: unquote(status))

      assert {:ok, fresh} =
               Fountain.Machines.Provision.reserve(%{
                 machine_name: history.machine_name,
                 user_id: history.user_id,
                 workspace_id: insert_workspace(user_id: history.user_id).id,
                 status: "pending"
               })

      assert fresh.id != history.id
      assert Repo.reload!(history).status == unquote(status)
    end
  end

  test "a direct write cannot reactivate history onto an occupied name" do
    history = insert_sandbox(status: "terminated")
    insert_sandbox(user_id: history.user_id, machine_name: history.machine_name, status: "ready")

    assert {:error, changeset} =
             history
             |> Sandbox.changeset(%{status: "ready"})
             |> Repo.update(mode: :savepoint)

    assert Keyword.has_key?(changeset.errors, :machine_name)
    assert Repo.reload!(history).status == "terminated"
  end

  defp duplicate(first, user_id) do
    %Sandbox{}
    |> Sandbox.changeset(%{
      machine_name: first.machine_name,
      user_id: user_id,
      workspace_id: Fountain.Factory.insert_workspace(user_id: user_id).id,
      status: "ready"
    })
    |> Repo.insert(mode: :savepoint)
  end
end
