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

  # `config/test.exs` sets `:clock_follows_callers`; see the moduledoc.
  describe "a process spawned by the test" do
    test "reads the test's frozen clock through its $callers" do
      freeze_clock(~U[2026-07-03 12:00:00Z])

      assert Task.await(Task.async(&Clock.utc_now/0)) == ~U[2026-07-03 12:00:00Z]
    end

    test "prefers its own freeze to its caller's" do
      freeze_clock(~U[2026-07-03 12:00:00Z])

      own =
        Task.async(fn ->
          freeze_clock(~U[2030-01-01 00:00:00Z])
          Clock.utc_now()
        end)

      assert Task.await(own) == ~U[2030-01-01 00:00:00Z]
    end

    test "skips a caller that has exited" do
      gone = spawn(fn -> :ok end)
      ref = Process.monitor(gone)
      assert_receive {:DOWN, ^ref, :process, ^gone, _reason}
      freeze_clock(~U[2026-07-03 12:00:00Z])
      test_pid = self()

      task =
        Task.async(fn ->
          Process.put(:"$callers", [gone, test_pid])
          Clock.utc_now()
        end)

      assert Task.await(task) == ~U[2026-07-03 12:00:00Z]
    end
  end
end
