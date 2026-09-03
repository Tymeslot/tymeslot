defmodule Tymeslot.Availability.TimeOffTest do
  @moduledoc """
  Covers `Tymeslot.Availability.TimeOff`: the reading of a stored period as
  the window it blocks on a given date, and the create/update/delete API the
  dashboard drives.

  `blocked_window/2` is where the whole feature's semantics live — a period is
  one continuous interval, so its times trim only the first and last day —
  and every other module asks this one rather than comparing dates itself.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :availability

  import Tymeslot.Factory

  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Availability.TimeOffPeriodQueries

  describe "blocked_window/2" do
    test "a whole-day period blocks every date it covers, and nothing outside it" do
      period = %{
        starts_on: ~D[2026-09-10],
        ends_on: ~D[2026-09-12],
        start_time: nil,
        end_time: nil
      }

      assert TimeOff.blocked_window(period, ~D[2026-09-09]) == :none
      assert TimeOff.blocked_window(period, ~D[2026-09-10]) == :all_day
      assert TimeOff.blocked_window(period, ~D[2026-09-11]) == :all_day
      assert TimeOff.blocked_window(period, ~D[2026-09-12]) == :all_day
      assert TimeOff.blocked_window(period, ~D[2026-09-13]) == :none
    end

    test "times trim only the first and last day; the days between stay blocked in full" do
      # "Leaving Friday lunchtime, back Monday morning": the point of the
      # continuous-interval reading. Saturday and Sunday must not inherit the
      # 14:00 start, which is what a per-day reading of the same row would do.
      period = %{
        starts_on: ~D[2026-09-11],
        ends_on: ~D[2026-09-14],
        start_time: ~T[14:00:00],
        end_time: ~T[09:00:00]
      }

      assert TimeOff.blocked_window(period, ~D[2026-09-11]) == {~T[14:00:00], ~T[23:59:59]}
      assert TimeOff.blocked_window(period, ~D[2026-09-12]) == :all_day
      assert TimeOff.blocked_window(period, ~D[2026-09-13]) == :all_day
      assert TimeOff.blocked_window(period, ~D[2026-09-14]) == {~T[00:00:00], ~T[09:00:00]}
    end

    test "a single day with both times blocks only that window" do
      period = %{
        starts_on: ~D[2026-09-10],
        ends_on: ~D[2026-09-10],
        start_time: ~T[13:00:00],
        end_time: ~T[17:00:00]
      }

      assert TimeOff.blocked_window(period, ~D[2026-09-10]) == {~T[13:00:00], ~T[17:00:00]}
    end

    test "a single open-ended day blocks from its time to the end of the day" do
      period = %{
        starts_on: ~D[2026-09-10],
        ends_on: ~D[2026-09-10],
        start_time: ~T[13:00:00],
        end_time: nil
      }

      assert TimeOff.blocked_window(period, ~D[2026-09-10]) == {~T[13:00:00], ~T[23:59:59]}
    end

    test "a day covered from midnight to end of day reads as all-day, not as a window" do
      # Explicit midnight-to-midnight times must collapse to :all_day, or the
      # day would be handed to the slot filter as a break and the business-hours
      # refusal that keeps the date off the calendar grid would never fire.
      period = %{
        starts_on: ~D[2026-09-10],
        ends_on: ~D[2026-09-10],
        start_time: ~T[00:00:00],
        end_time: ~T[23:59:59]
      }

      assert TimeOff.blocked_window(period, ~D[2026-09-10]) == :all_day
    end

    test "a multi-day period whose end time precedes its start time blocks neither edge day fully" do
      # Friday 16:00 to Monday 09:00 leaves Friday morning and Monday afternoon
      # bookable; neither edge may be promoted to :all_day by the clock
      # comparison alone.
      period = %{
        starts_on: ~D[2026-09-11],
        ends_on: ~D[2026-09-14],
        start_time: ~T[16:00:00],
        end_time: ~T[09:00:00]
      }

      refute TimeOff.blocked_window(period, ~D[2026-09-11]) == :all_day
      refute TimeOff.blocked_window(period, ~D[2026-09-14]) == :all_day
    end

    test "a period with no dates blocks nothing" do
      assert TimeOff.blocked_window(%{starts_on: nil, ends_on: nil}, ~D[2026-09-10]) == :none
    end
  end

  describe "all_day? / windows_for_day" do
    test "separates whole days from the part-day windows the slot filter excludes" do
      whole_day = %{
        starts_on: ~D[2026-09-10],
        ends_on: ~D[2026-09-10],
        start_time: nil,
        end_time: nil
      }

      afternoon = %{
        starts_on: ~D[2026-09-11],
        ends_on: ~D[2026-09-11],
        start_time: ~T[13:00:00],
        end_time: ~T[17:00:00]
      }

      periods = [whole_day, afternoon]

      assert TimeOff.all_day?(periods, ~D[2026-09-10])
      refute TimeOff.all_day?(periods, ~D[2026-09-11])

      # A whole day contributes no window: it is refused before slot generation
      # rather than by removing every slot it produced.
      assert TimeOff.windows_for_day(periods, ~D[2026-09-10]) == []
      assert TimeOff.windows_for_day(periods, ~D[2026-09-11]) == [{~T[13:00:00], ~T[17:00:00]}]
      assert TimeOff.windows_for_day(periods, ~D[2026-09-12]) == []
    end

    test "overlapping part-day periods each contribute their own window" do
      periods = [
        %{
          starts_on: ~D[2026-09-11],
          ends_on: ~D[2026-09-11],
          start_time: ~T[09:00:00],
          end_time: ~T[11:00:00]
        },
        %{
          starts_on: ~D[2026-09-11],
          ends_on: ~D[2026-09-11],
          start_time: ~T[10:00:00],
          end_time: ~T[13:00:00]
        }
      ]

      assert TimeOff.windows_for_day(periods, ~D[2026-09-11]) == [
               {~T[09:00:00], ~T[11:00:00]},
               {~T[10:00:00], ~T[13:00:00]}
             ]
    end
  end

  describe "create/2" do
    test "stores a period against the profile and returns it" do
      profile = insert(:profile)

      assert {:ok, period} =
               TimeOff.create(profile.id, %{
                 "starts_on" => "2026-12-24",
                 "ends_on" => "2027-01-02",
                 "label" => "Portugal"
               })

      assert period.profile_id == profile.id
      assert period.starts_on == ~D[2026-12-24]
      assert period.ends_on == ~D[2027-01-02]
      assert period.label == "Portugal"
      assert [^period] = TimeOff.list(profile.id)
    end

    test "rejects an end date before the start date" do
      profile = insert(:profile)

      assert {:error, changeset} =
               TimeOff.create(profile.id, %{starts_on: ~D[2026-09-12], ends_on: ~D[2026-09-10]})

      assert "must not be before the start date" in errors_on(changeset).ends_on
      assert TimeOff.list(profile.id) == []
    end

    test "rejects an end time at or before the start time on a single day" do
      profile = insert(:profile)

      assert {:error, changeset} =
               TimeOff.create(profile.id, %{
                 starts_on: ~D[2026-09-10],
                 ends_on: ~D[2026-09-10],
                 start_time: ~T[17:00:00],
                 end_time: ~T[13:00:00]
               })

      assert "must be after the start time" in errors_on(changeset).end_time
    end

    test "accepts an end time before the start time when the period spans days" do
      profile = insert(:profile)

      assert {:ok, _period} =
               TimeOff.create(profile.id, %{
                 starts_on: ~D[2026-09-11],
                 ends_on: ~D[2026-09-14],
                 start_time: ~T[16:00:00],
                 end_time: ~T[09:00:00]
               })
    end

    test "refuses to exceed the per-profile limit" do
      profile = insert(:profile)

      for offset <- 0..(TimeOff.max_periods() - 1) do
        date = Date.add(~D[2026-01-01], offset)
        insert(:time_off_period, profile: profile, starts_on: date, ends_on: date)
      end

      assert {:error, :limit_reached} =
               TimeOff.create(profile.id, %{starts_on: ~D[2027-01-01], ends_on: ~D[2027-01-01]})

      refute TimeOff.can_create?(profile.id)
    end
  end

  describe "update/2 and delete/1" do
    test "update rewrites the stored dates" do
      period = insert(:time_off_period, starts_on: ~D[2026-09-10], ends_on: ~D[2026-09-12])

      assert {:ok, updated} = TimeOff.update(period, %{"ends_on" => "2026-09-20"})
      assert updated.ends_on == ~D[2026-09-20]

      assert TimeOffPeriodQueries.get_for_profile(period.profile_id, period.id).ends_on ==
               ~D[2026-09-20]
    end

    test "update rejects an invalid change and leaves the row alone" do
      period = insert(:time_off_period, starts_on: ~D[2026-09-10], ends_on: ~D[2026-09-12])

      assert {:error, _changeset} = TimeOff.update(period, %{ends_on: ~D[2026-09-01]})

      assert TimeOffPeriodQueries.get_for_profile(period.profile_id, period.id).ends_on ==
               ~D[2026-09-12]
    end

    test "clearing the times switches a part-day period back to whole days" do
      # The form submits "" for "All day". `cast/4` reads a blank as absent, so
      # without an explicit nil the stored times survive the edit and the period
      # silently stays a half-day.
      period =
        insert(:time_off_period,
          starts_on: ~D[2026-09-10],
          ends_on: ~D[2026-09-10],
          start_time: ~T[13:00:00],
          end_time: ~T[17:00:00]
        )

      assert {:ok, updated} =
               TimeOff.update(period, %{
                 "starts_on" => "2026-09-10",
                 "ends_on" => "2026-09-10",
                 "start_time" => "",
                 "end_time" => "",
                 "label" => ""
               })

      assert updated.start_time == nil
      assert updated.end_time == nil
      assert updated.label == nil
      assert TimeOff.blocked_window(updated, ~D[2026-09-10]) == :all_day
    end

    test "a whitespace-only note is stored as no note at all" do
      profile = insert(:profile)

      assert {:ok, period} =
               TimeOff.create(profile.id, %{
                 starts_on: ~D[2026-09-10],
                 ends_on: ~D[2026-09-10],
                 label: "   "
               })

      assert period.label == nil
    end

    test "delete removes the row" do
      period = insert(:time_off_period)

      assert {:ok, _deleted} = TimeOff.delete(period)
      assert TimeOff.list(period.profile_id) == []
    end
  end

  describe "fetch/2" do
    test "will not reach a period belonging to another profile" do
      mine = insert(:profile)
      theirs = insert(:time_off_period)

      assert {:error, :not_found} = TimeOff.fetch(mine.id, theirs.id)
      assert {:ok, _period} = TimeOff.fetch(theirs.profile_id, theirs.id)
    end
  end
end
