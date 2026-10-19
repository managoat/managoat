defmodule Managoat.Runtimes.QuirksTest do
  @moduledoc """
  The guardrail that makes the registry worth more than the comments it
  replaces.

  The load-bearing test is `implemented_by`: every entry names the function
  that carries the workaround, and that function has to exist. Delete a
  workaround without deleting its entry and this fails; leave an entry
  pointing at code that is gone and this fails. Everything else here is
  shape-checking so an entry cannot be added without saying what would delete
  it.
  """
  use ExUnit.Case, async: true

  alias Managoat.Runtimes.Layout
  alias Managoat.Runtimes.Quirks

  test "ids are unique" do
    ids = Enum.map(Quirks.all(), & &1.id)
    assert ids == Enum.uniq(ids)
  end

  test "every quirk names at least one runtime, and every runtime is a real one" do
    for q <- Quirks.all() do
      assert q.runtimes != [], "#{q.id} names no runtime"

      for runtime <- q.runtimes do
        assert runtime in Layout.runtimes(),
               "#{q.id} names runtime #{inspect(runtime)}, which has no layout"
      end
    end
  end

  test "the code each quirk points at still exists" do
    for %{id: id, implemented_by: {mod, fun, arity}} <- Quirks.all() do
      Code.ensure_loaded!(mod)

      assert function_exported?(mod, fun, arity),
             """
             #{id} says it is implemented by #{inspect(mod)}.#{fun}/#{arity}, \
             which does not exist. Either the workaround was removed and the \
             entry should go with it, or it moved and the entry should follow.\
             """
    end
  end

  test "every quirk says what would delete it, and how to find out" do
    for q <- Quirks.all() do
      for field <- [:summary, :why, :reprobe, :delete_when, :measured_against] do
        value = Map.fetch!(q, field)

        assert is_binary(value) and String.trim(value) != "",
               "#{q.id} has an empty #{field}"
      end
    end
  end

  test "upstream is a URL, or an explicit reason there is none" do
    for q <- Quirks.all() do
      case q.upstream do
        url when is_binary(url) ->
          assert String.starts_with?(url, "https://"), "#{q.id}'s upstream is not a URL"

        {:none, reason} ->
          assert is_binary(reason) and String.trim(reason) != "",
                 "#{q.id} has no upstream and no reason why not"

        other ->
          flunk("#{q.id} has an unrecognised upstream: #{inspect(other)}")
      end
    end
  end

  test "for_runtime/1 and upstream_tracked/0 select from the same table" do
    assert Enum.map(Quirks.for_runtime("gemini"), & &1.id) == [:gemini_usage_in_meta_quota]

    assert Enum.map(Quirks.for_runtime("codex"), & &1.id) == [:sprite_node_shim]
    assert Quirks.for_runtime("nope") == []

    assert Quirks.get(:gemini_usage_in_meta_quota).runtimes == ["gemini"]
    # Gone with config homes (ADR 0097): the rename it dodged fails only in the
    # image's own ~/.gemini, which no conversation's gemini uses any more.
    assert Quirks.get(:home_on_tmp) == nil
    assert Quirks.get(:not_a_quirk) == nil

    # The two we are waiting on someone else for.
    assert Keyword.keys(Quirks.upstream_tracked()) == [
             :claude_mcp_via_files,
             :gemini_usage_in_meta_quota
           ]
  end

  test "codex's login is deliberately not recorded as a quirk" do
    # It is codex's documented auth mechanism, not a defect: no upstream fix
    # would remove it and there is no condition under which we stop. It
    # belongs to the irreducible tier in `Managoat.Runtimes`. Recorded as a
    # test so the next person to look at `Codex.prepare_sandbox/3` and reach
    # for this registry finds the reasoning rather than repeating it.
    refute Enum.any?(Quirks.all(), &match?({Managoat.Runtimes.Codex, _, _}, &1.implemented_by))
  end
end
