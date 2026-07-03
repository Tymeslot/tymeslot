defmodule Tymeslot.ClockTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Clock

  describe "utc_now/0" do
    test "returns the system time when not frozen" do
      before = DateTime.utc_now()
      now = Clock.utc_now()
      later = DateTime.utc_now()

      assert DateTime.compare(now, before) in [:gt, :eq]
      assert DateTime.compare(now, later) in [:lt, :eq]
    end

    test "returns the frozen instant while frozen" do
      frozen = ~U[2026-03-29 01:30:00Z]

      freeze_clock(frozen)
      assert Clock.utc_now() == frozen

      unfreeze_clock()
      refute Clock.utc_now() == frozen
    end

    test "with_frozen_clock/2 restores the real clock afterwards" do
      frozen = ~U[2020-01-01 00:00:00Z]

      assert with_frozen_clock(frozen, fn -> Clock.utc_now() end) == frozen
      # A past instant proves the real clock resumed.
      assert DateTime.compare(Clock.utc_now(), frozen) == :gt
    end
  end

  describe "utc_today/0" do
    test "honours a frozen clock across the midnight boundary" do
      with_frozen_clock(~U[2026-07-03 23:59:00Z], fn ->
        assert Clock.utc_today() == ~D[2026-07-03]
      end)

      with_frozen_clock(~U[2026-07-04 00:01:00Z], fn ->
        assert Clock.utc_today() == ~D[2026-07-04]
      end)
    end
  end
end
