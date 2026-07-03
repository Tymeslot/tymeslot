defmodule Tymeslot.Bookings.PolicyClockTest do
  @moduledoc """
  Demonstrates the payoff of routing `Tymeslot.Bookings.Policy` through
  `Tymeslot.Clock`: its "is this meeting past / current?" cut-offs can be pinned
  to a fixed instant and their boundaries exercised deterministically, instead of
  depending on the wall clock at the moment the test happens to run.
  """

  use ExUnit.Case, async: true

  @moduletag :bookings

  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Bookings.Policy

  @now ~U[2026-07-03 12:00:00Z]

  describe "meeting_is_past?/1 relative to a frozen now" do
    test "true one minute before now, false one minute after" do
      with_frozen_clock(@now, fn ->
        assert Policy.meeting_is_past?(%{end_time: ~U[2026-07-03 11:59:00Z]})
        refute Policy.meeting_is_past?(%{end_time: ~U[2026-07-03 12:01:00Z]})
      end)
    end
  end

  describe "meeting_is_current?/1 relative to a frozen now" do
    test "true while now falls inside the meeting window" do
      with_frozen_clock(@now, fn ->
        assert Policy.meeting_is_current?(%{
                 start_time: ~U[2026-07-03 11:30:00Z],
                 end_time: ~U[2026-07-03 12:30:00Z]
               })
      end)
    end

    test "false for a meeting that starts after now" do
      with_frozen_clock(@now, fn ->
        refute Policy.meeting_is_current?(%{
                 start_time: ~U[2026-07-03 12:30:00Z],
                 end_time: ~U[2026-07-03 13:00:00Z]
               })
      end)
    end
  end
end
