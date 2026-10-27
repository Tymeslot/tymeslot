defmodule Tymeslot.Integrations.Calendar.TimingChangeTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.TimingChange
  alias Tymeslot.Meetings.MeetingSchema

  @start ~U[2030-03-04 10:00:00Z]
  @booked_end ~U[2030-03-04 10:30:00Z]
  @later ~U[2030-03-04 11:30:00Z]

  defp meeting(seen),
    do: %MeetingSchema{start_time: @start, end_time: @booked_end, seen_calendar_end_time: seen}

  defp timed(start_at, end_at) do
    %CalendarEvent{
      uid: "evt",
      calendar_integration_id: 1,
      provider: "google",
      provider_calendar_id: "primary",
      all_day: false,
      start_at: start_at,
      end_at: end_at,
      synced_at: @start
    }
  end

  describe "classify/3 for a timed event" do
    test "a moved start is a move, whatever the end did" do
      assert TimingChange.classify(
               meeting(@booked_end),
               timed(~U[2030-03-04 09:00:00Z], @booked_end),
               nil
             ) ==
               :moved
    end

    test "an end matching the meeting's is no change" do
      assert TimingChange.classify(meeting(@later), timed(@start, @booked_end), nil) == :none
    end

    test "an end the calendar changed since it was last in step is followed" do
      assert TimingChange.classify(meeting(@booked_end), timed(@start, @later), nil) ==
               {:end_moved, @later}
    end

    test "an end the calendar has shown all along is no change" do
      assert TimingChange.classify(meeting(@later), timed(@start, @later), nil) == :none
    end

    test "a different end on a meeting with no seen end is taken as the starting point" do
      assert TimingChange.classify(meeting(nil), timed(@start, @later), nil) == :none
    end

    test "a calendar end changed again after one was accepted is followed" do
      changed_again = ~U[2030-03-04 12:00:00Z]

      assert TimingChange.classify(meeting(@later), timed(@start, changed_again), nil) ==
               {:end_moved, changed_again}
    end

    test "sub-second noise is no change, and the end followed is whole seconds" do
      noisy = DateTime.add(@later, 400_000, :microsecond)

      assert TimingChange.classify(meeting(@later), timed(@start, noisy), nil) == :none

      assert TimingChange.classify(meeting(@booked_end), timed(@start, noisy), nil) ==
               {:end_moved, @later}
    end

    test "an event with no end is no change" do
      assert TimingChange.classify(meeting(@booked_end), timed(@start, nil), nil) == :none
    end
  end

  describe "seen_end/1" do
    test "is a timed event's end to the second" do
      assert TimingChange.seen_end(timed(@start, DateTime.add(@later, 5, :microsecond))) == @later
    end

    test "is nil for an all-day event" do
      event = %{
        timed(nil, nil)
        | all_day: true,
          start_date: ~D[2030-03-04],
          end_date: ~D[2030-03-05]
      }

      assert TimingChange.seen_end(event) == nil
    end
  end
end
