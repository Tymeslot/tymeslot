defmodule Tymeslot.Availability.TimeOffConflictsTest do
  @moduledoc """
  Covers `TimeOff.conflicting_meetings/1`: the bookings that already sit inside
  a period, which the dashboard names rather than acts on.

  Time off takes days out of future availability and leaves the diary alone, so
  a host entering a holiday over three confirmed bookings has to be told. The
  whole answer turns on the interval the period covers, so the cases below are
  the ones a comparison of dates against stored UTC start times gets wrong.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :availability

  import Tymeslot.Factory

  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Availability.TimeOffPeriodSchema

  describe "conflicting_meetings/1" do
    test "names the owner's bookings inside the period, read in the owner's timezone" do
      # Berlin is two hours ahead in September, so the period runs from
      # 09-09 22:00Z to 09-12 22:00Z. Both bookings fall on the 9th in UTC and
      # only the later one is inside the time off: a comparison of the stored
      # start times against the period's dates would get both of them wrong.
      profile = insert(:profile, timezone: "Europe/Berlin")
      period = period_for(profile, ~D[2026-09-10], ~D[2026-09-12])

      inside = booking(profile, ~U[2026-09-09 22:30:00Z], title: "Design review")
      booking(profile, ~U[2026-09-09 21:00:00Z], title: "Still the 9th in Berlin")
      booking(profile, ~U[2026-09-12 22:30:00Z], title: "Back at work")

      assert Enum.map(TimeOff.conflicting_meetings(period), & &1.id) == [inside.id]
    end

    test "leaves out bookings that no longer hold their slot, and other hosts'" do
      profile = insert(:profile, timezone: "Etc/UTC")
      period = period_for(profile, ~D[2026-09-10], ~D[2026-09-12])

      booking(profile, ~U[2026-09-10 09:00:00Z], status: "cancelled")

      booking(profile, ~U[2026-09-10 10:00:00Z],
        reschedule_requested_at: ~U[2026-09-01 08:00:00Z]
      )

      booking(insert(:profile), ~U[2026-09-10 11:00:00Z])

      assert TimeOff.conflicting_meetings(period) == []
    end

    test "takes in the whole of an open-ended last day" do
      # The last second of the last day is still time off: the period runs to
      # midnight after `ends_on`, not to 23:59:59 on it, and a booking starting
      # on that second is one the host has to be told about.
      profile = insert(:profile, timezone: "Etc/UTC")
      period = period_for(profile, ~D[2026-09-10], ~D[2026-09-12])

      last_second = booking(profile, ~U[2026-09-12 23:59:59Z])
      booking(profile, ~U[2026-09-13 00:00:00Z])

      assert Enum.map(TimeOff.conflicting_meetings(period), & &1.id) == [last_second.id]
    end

    test "answers for an edit from the period as it will be, not as it is stored" do
      profile = insert(:profile, timezone: "Etc/UTC")
      period = period_for(profile, ~D[2026-09-10], ~D[2026-09-12])
      swallowed = booking(profile, ~U[2026-09-15 09:00:00Z], title: "Client call")

      assert TimeOff.conflicting_meetings(period) == []

      changeset =
        TimeOff.validate(period, %{"ends_on" => "2026-09-16"}, today: ~D[2026-09-01])

      assert Enum.map(TimeOff.conflicting_meetings(changeset), & &1.id) == [swallowed.id]
    end

    test "counts nothing for a period the changeset has already rejected" do
      profile = insert(:profile, timezone: "Etc/UTC")
      booking(profile, ~U[2026-09-10 09:00:00Z])

      changeset =
        TimeOff.validate(
          profile.id,
          %{"starts_on" => "2026-09-12", "ends_on" => "2026-09-09"},
          today: ~D[2026-09-01]
        )

      refute changeset.valid?
      assert TimeOff.conflicting_meetings(changeset) == []
    end

    test "counts nothing before both dates have been chosen" do
      profile = insert(:profile, timezone: "Etc/UTC")
      booking(profile, ~U[2026-09-10 09:00:00Z])

      changeset =
        TimeOff.validate(profile.id, %{"starts_on" => "2026-09-10"}, today: ~D[2026-09-01])

      assert TimeOff.conflicting_meetings(changeset) == []
      assert TimeOff.conflicting_meetings(%TimeOffPeriodSchema{profile_id: profile.id}) == []
    end
  end

  defp booking(profile, start_time, attrs \\ []) do
    insert(
      :meeting,
      Keyword.merge(
        [
          organizer_user_id: profile.user_id,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute)
        ],
        attrs
      )
    )
  end

  defp period_for(profile, starts_on, ends_on) do
    insert(:time_off_period, profile: profile, starts_on: starts_on, ends_on: ends_on)
  end
end
