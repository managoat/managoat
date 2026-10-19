defmodule Fountain.Conversations.FloorSettleTest do
  use ExUnit.Case, async: true

  alias Fountain.Conversations.FloorSettle
  alias Managoat.Sandbox.Handle

  @sprite %Handle{provider: :sprites, name: "s"}
  @e2b %Handle{provider: :e2b, name: "e"}

  describe "which providers settle (#2964)" do
    test "only Sprites writes the floor first and is marked" do
      assert FloorSettle.early?(@sprite)
      refute FloorSettle.early?(@e2b)
      assert is_integer(FloorSettle.mark(@sprite))
      assert FloorSettle.mark(@e2b) == nil
    end

    test "tests run with no window" do
      assert FloorSettle.settle_ms() == 0
    end
  end

  describe "mark_attach/3" do
    test "a floor the attach wrote settles" do
      assert is_integer(FloorSettle.mark_attach(@sprite, :written, %{inserted_at: nil}))
    end

    test "a floor found in force settles only on a machine created a moment ago" do
      fresh = %{inserted_at: DateTime.add(DateTime.utc_now(), -5)}
      old = %{inserted_at: DateTime.add(DateTime.utc_now(), -3_600)}

      assert is_integer(FloorSettle.mark_attach(@sprite, :unchanged, fresh))
      assert FloorSettle.mark_attach(@sprite, :unchanged, old) == nil
      assert FloorSettle.mark_attach(@sprite, :unchanged, %{inserted_at: nil}) == nil
    end

    test "never off Sprites" do
      assert FloorSettle.mark_attach(@e2b, :written, %{inserted_at: nil}) == nil
    end
  end

  describe "hold/3" do
    # Handlers are global and other tests emit this event, so each test only
    # hears the events carrying its own ref.
    setup do
      ref = make_ref()
      test = self()

      :telemetry.attach(
        "floor-settle-#{inspect(ref)}",
        [:fountain, :floor, :settle],
        fn _name, measurements, metadata, _ ->
          if metadata[:ref] == ref, do: send(test, {:settle, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("floor-settle-#{inspect(ref)}") end)
      %{meta: %{ref: ref, path: "fresh"}}
    end

    test "adds no time when the gap since the write is already long enough", %{meta: meta} do
      marked = System.monotonic_time(:millisecond) - 5_000
      {elapsed_us, held} = :timer.tc(fn -> FloorSettle.hold(marked, meta, 2_000) end)

      assert held == 0
      assert elapsed_us < 100_000
      assert_received {:settle, %{held_ms: 0, gap_ms: gap, settle_ms: 2_000}, %{path: "fresh"}}
      assert gap >= 5_000
    end

    test "waits out only what is left of the window", %{meta: meta} do
      marked = System.monotonic_time(:millisecond) - 1_700
      {elapsed_us, held} = :timer.tc(fn -> FloorSettle.hold(marked, meta, 2_000) end)

      assert held in 1..300
      assert elapsed_us >= held * 1_000
      assert elapsed_us < 1_000_000
      assert_received {:settle, %{held_ms: ^held, gap_ms: gap}, _}
      assert gap + held >= 2_000
    end

    test "no mark (another provider) holds nothing and says nothing", %{meta: meta} do
      assert FloorSettle.hold(nil, meta, 2_000) == 0
      refute_received {:settle, _, _}
    end
  end
end
