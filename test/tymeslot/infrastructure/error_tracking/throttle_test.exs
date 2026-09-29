defmodule Tymeslot.Infrastructure.ErrorTracking.ThrottleTest do
  # async: false: the throttle's counters and settings, and ErrorTracker's
  # `enabled` switch, are global.
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  import Ecto.Query
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias ErrorTracker.Occurrence
  alias Tymeslot.Infrastructure.ErrorTracking.Throttle
  alias Tymeslot.Test.LogCapture

  # A window far longer than any test, so a boundary never falls inside one.
  @window_seconds 1_000_000_000

  setup do
    with_config(:tymeslot, :error_tracking_throttle,
      max_per_window: 3,
      window_seconds: @window_seconds
    )

    :ok
  end

  defp fingerprint, do: :crypto.strong_rand_bytes(32)

  describe "allow?/1" do
    test "lets the first max_per_window reports of a fingerprint through, then drops" do
      fingerprint = fingerprint()

      assert Enum.map(1..5, fn _n -> Throttle.allow?(fingerprint) end) ==
               [true, true, true, false, false]
    end

    test "counts each fingerprint separately" do
      noisy = fingerprint()
      for _n <- 1..5, do: Throttle.allow?(noisy)

      assert Throttle.allow?(fingerprint())
    end

    test "lets everything through when switched off" do
      with_config(:tymeslot, :error_tracking_throttle, max_per_window: nil)
      fingerprint = fingerprint()

      assert Enum.all?(1..10, fn _n -> Throttle.allow?(fingerprint) end)
    end

    test "lets a report without a fingerprint through" do
      assert Throttle.allow?(nil)
    end
  end

  describe "sweep/0" do
    test "starts a fresh window and logs how many occurrences were dropped" do
      fingerprint = fingerprint()
      for _n <- 1..5, do: Throttle.allow?(fingerprint)
      refute Throttle.allow?(fingerprint)

      # Moving to one-second windows puts the counters above in the past.
      with_config(:tymeslot, :error_tracking_throttle, max_per_window: 3, window_seconds: 1)
      LogCapture.attach()
      :ok = Throttle.sweep()

      # Other tests' counters are swept too, so wait for this one's line.
      event = await_throttled(binary_part(Base.encode16(fingerprint, case: :lower), 0, 16))
      assert event.meta.dropped == 3
      assert event.meta.stored == 3

      assert Throttle.allow?(fingerprint)
    end
  end

  describe "in front of ErrorTracker" do
    setup do
      with_config(:error_tracker, enabled: true)
      :ok
    end

    test "stores at most max_per_window occurrences of one error per window" do
      for _n <- 1..6, do: report_boom()

      assert [%Error{id: error_id}] = Repo.all(Error)
      assert Repo.aggregate(from(o in Occurrence, where: o.error_id == ^error_id), :count) == 3
    end
  end

  defp await_throttled(fingerprint) do
    event = LogCapture.await_log("ErrorTracker occurrences throttled")
    if event.meta.fingerprint == fingerprint, do: event, else: await_throttled(fingerprint)
  end

  # Raised from one line, so every report shares a fingerprint.
  defp report_boom do
    raise "throttled boom"
  rescue
    exception -> ErrorTracker.report(exception, __STACKTRACE__)
  end
end
