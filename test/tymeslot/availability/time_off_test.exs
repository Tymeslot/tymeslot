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
  import Tymeslot.Test.ClockHelpers

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
    # The fixtures below sit in September 2026; pinning "today" before them
    # keeps the past-date rule from rejecting them as the calendar moves on.
    setup do
      freeze_clock(~U[2026-09-01 12:00:00Z])
    end

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

    test "rejects an end date far enough out to be a mistyped year" do
      # 2226 instead of 2026 saves a period two centuries long, which is a
      # perfectly valid row: every reader honours it and the booking page
      # offers nothing, for ever, without naming a cause.
      profile = insert(:profile)

      assert {:error, changeset} =
               TimeOff.create(profile.id, %{starts_on: ~D[2026-09-10], ends_on: ~D[2226-09-10]})

      assert "must be within 2 years" in errors_on(changeset).ends_on
      assert TimeOff.list(profile.id) == []
    end

    test "places the bound two years from today, to the day" do
      profile = insert(:profile)

      assert {:ok, _period} =
               TimeOff.create(profile.id, %{starts_on: ~D[2026-09-10], ends_on: ~D[2028-09-01]})

      assert {:error, changeset} =
               TimeOff.create(profile.id, %{starts_on: ~D[2026-09-10], ends_on: ~D[2028-09-02]})

      assert "must be within 2 years" in errors_on(changeset).ends_on
    end

    test "measures the bound from the owner's today rather than from UTC" do
      # 23:30 UTC on the 1st is already the 2nd in Tallinn, so the bound the
      # host's own picker offers is a day past the one UTC would compute.
      freeze_clock(~U[2026-09-01 23:30:00Z])
      profile = insert(:profile, timezone: "Europe/Tallinn")

      assert {:ok, period} =
               TimeOff.create(profile.id, %{starts_on: ~D[2026-09-10], ends_on: ~D[2028-09-02]})

      assert period.ends_on == ~D[2028-09-02]
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

    test "rejects a single day that is back at midnight, since it would block nothing" do
      # "All day" to begin with reads as 00:00, so a return at 00:00 the same
      # day is an empty window that would still be listed as time off.
      profile = insert(:profile)

      assert {:error, changeset} =
               TimeOff.create(profile.id, %{
                 starts_on: ~D[2026-09-10],
                 ends_on: ~D[2026-09-10],
                 start_time: nil,
                 end_time: ~T[00:00:00]
               })

      assert "must be after the start time" in errors_on(changeset).end_time
    end

    test "accepts a single day away from the start of the day until a set time" do
      profile = insert(:profile)

      assert {:ok, period} =
               TimeOff.create(profile.id, %{
                 starts_on: ~D[2026-09-10],
                 ends_on: ~D[2026-09-10],
                 start_time: nil,
                 end_time: ~T[09:00:00]
               })

      assert TimeOff.blocked_window(period, ~D[2026-09-10]) == {~T[00:00:00], ~T[09:00:00]}
    end

    test "strips null bytes from the note instead of failing the insert" do
      profile = insert(:profile)

      assert {:ok, period} =
               TimeOff.create(profile.id, %{
                 starts_on: ~D[2026-09-10],
                 ends_on: ~D[2026-09-10],
                 label: "Port\x00ugal"
               })

      assert period.label == "Portugal"
    end

    test "measures the note in codepoints, the unit the column is limited in" do
      # Nine family emoji are nine graphemes but 63 codepoints: counted as
      # graphemes the note would pass and then overflow the column on insert.
      profile = insert(:profile)
      family = "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}"

      assert {:error, changeset} =
               TimeOff.create(profile.id, %{
                 starts_on: ~D[2026-09-10],
                 ends_on: ~D[2026-09-10],
                 label: String.duplicate(family, 9)
               })

      assert errors_on(changeset).label != []
      assert TimeOff.list(profile.id) == []
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

    test "rejects a period starting before today" do
      profile = insert(:profile, timezone: "Etc/UTC")

      assert {:error, changeset} =
               TimeOff.create(profile.id, %{starts_on: ~D[2026-08-31], ends_on: ~D[2026-09-03]})

      assert "must not be in the past" in errors_on(changeset).starts_on
      assert TimeOff.list(profile.id) == []
    end

    test "accepts a period starting today" do
      profile = insert(:profile, timezone: "Etc/UTC")

      assert {:ok, _period} =
               TimeOff.create(profile.id, %{starts_on: ~D[2026-09-01], ends_on: ~D[2026-09-01]})
    end

    test "reads today in the owner's timezone, not the server's" do
      # 23:30 UTC on 1 September is already 2 September in Tokyo and still
      # 1 September in New York, so the same date is past for one owner only.
      freeze_clock(~U[2026-09-01 23:30:00Z])
      tokyo = insert(:profile, timezone: "Asia/Tokyo")
      new_york = insert(:profile, timezone: "America/New_York")
      attrs = %{starts_on: ~D[2026-09-01], ends_on: ~D[2026-09-01]}

      assert {:error, changeset} = TimeOff.create(tokyo.id, attrs)
      assert "must not be in the past" in errors_on(changeset).starts_on
      assert {:ok, _period} = TimeOff.create(new_york.id, attrs)
    end

    test "refuses to exceed the per-profile limit" do
      profile = insert(:profile)

      for offset <- 0..(TimeOff.max_periods() - 1) do
        date = Date.add(~D[2026-09-01], offset)
        insert(:time_off_period, profile: profile, starts_on: date, ends_on: date)
      end

      assert {:error, :limit_reached} =
               TimeOff.create(profile.id, %{starts_on: ~D[2027-01-01], ends_on: ~D[2027-01-01]})

      refute TimeOff.can_create?(profile.id)
    end

    test "periods that have already ended do not count towards the limit" do
      profile = insert(:profile, timezone: "Etc/UTC")

      for offset <- 1..TimeOff.max_periods() do
        date = Date.add(~D[2026-09-01], -offset)
        insert(:time_off_period, profile: profile, starts_on: date, ends_on: date)
      end

      assert TimeOff.can_create?(profile.id)

      assert {:ok, _period} =
               TimeOff.create(profile.id, %{starts_on: ~D[2026-09-02], ends_on: ~D[2026-09-02]})
    end
  end

  describe "list_by_status/1" do
    setup do
      freeze_clock(~U[2026-09-01 12:00:00Z])
      %{profile: insert(:profile, timezone: "Etc/UTC")}
    end

    test "separates finished periods from current ones", %{profile: profile} do
      under_way = period_for(profile, ~D[2026-08-28], ~D[2026-09-01])
      upcoming = period_for(profile, ~D[2026-09-10], ~D[2026-09-12])
      ended_yesterday = period_for(profile, ~D[2026-08-25], ~D[2026-08-31])

      assert %{current: current, past: past} = TimeOff.list_by_status(profile.id)
      assert Enum.map(current, & &1.id) == [under_way.id, upcoming.id]
      assert Enum.map(past, & &1.id) == [ended_yesterday.id]
    end

    test "lists finished periods most recently ended first, back 30 days only", %{
      profile: profile
    } do
      oldest_shown = period_for(profile, ~D[2026-07-30], ~D[2026-08-02])
      recent = period_for(profile, ~D[2026-08-20], ~D[2026-08-21])
      _too_old = period_for(profile, ~D[2026-07-20], ~D[2026-08-01])

      assert %{past: past} = TimeOff.list_by_status(profile.id)
      assert Enum.map(past, & &1.id) == [recent.id, oldest_shown.id]
    end
  end

  describe "update/2 and delete/1" do
    setup do
      freeze_clock(~U[2026-09-01 12:00:00Z])
    end

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

    test "a period already under way can still be edited" do
      # Its first day is in the past, but the edit does not change it, so the
      # past-date rule must not stand in the way of moving the last day.
      period =
        insert(:time_off_period,
          profile: build(:profile, timezone: "Etc/UTC"),
          starts_on: ~D[2026-08-28],
          ends_on: ~D[2026-09-04]
        )

      assert {:ok, updated} =
               TimeOff.update(period, %{
                 "starts_on" => "2026-08-28",
                 "ends_on" => "2026-09-08",
                 "label" => "Longer"
               })

      assert updated.ends_on == ~D[2026-09-08]
    end

    test "update refuses to move the last day into the past" do
      period =
        insert(:time_off_period,
          profile: build(:profile, timezone: "Etc/UTC"),
          starts_on: ~D[2026-08-28],
          ends_on: ~D[2026-09-04]
        )

      assert {:error, changeset} = TimeOff.update(period, %{ends_on: ~D[2026-08-30]})
      assert "must not be in the past" in errors_on(changeset).ends_on
    end

    test "a stored period reaching past the bound keeps its note editable" do
      # Rows written before the bound existed, and rows written under a looser
      # one, must not become unsaveable: the check only judges a last day the
      # submission actually moves.
      period =
        insert(:time_off_period,
          profile: build(:profile, timezone: "Etc/UTC"),
          starts_on: ~D[2026-09-10],
          ends_on: ~D[2099-01-10]
        )

      assert {:ok, updated} = TimeOff.update(period, %{"label" => "Sabbatical"})
      assert updated.label == "Sabbatical"
      assert updated.ends_on == ~D[2099-01-10]

      assert {:error, changeset} = TimeOff.update(period, %{ends_on: ~D[2099-01-11]})
      assert "must be within 2 years" in errors_on(changeset).ends_on
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

    test "update cannot move a period onto another profile" do
      period = insert(:time_off_period, starts_on: ~D[2026-09-10], ends_on: ~D[2026-09-12])
      other = insert(:profile)

      assert {:ok, updated} =
               TimeOff.update(period, %{"profile_id" => other.id, "label" => "Moved?"})

      assert updated.profile_id == period.profile_id
      assert TimeOff.list(other.id) == []
    end

    test "delete removes the row" do
      period = insert(:time_off_period)

      assert {:ok, _deleted} = TimeOff.delete(period)
      assert TimeOff.list(period.profile_id) == []
    end
  end

  describe "validate/3" do
    setup do
      freeze_clock(~U[2026-09-01 12:00:00Z])
    end

    test "reports a past date for a new period without storing anything" do
      profile = insert(:profile, timezone: "Etc/UTC")

      changeset =
        TimeOff.validate(profile.id, %{"starts_on" => "2026-08-20", "ends_on" => "2026-09-02"})

      assert changeset.action == :validate
      assert "must not be in the past" in errors_on(changeset).starts_on
      assert TimeOff.list(profile.id) == []
    end

    test "judges an edit against the stored period" do
      period =
        insert(:time_off_period,
          profile: build(:profile, timezone: "Etc/UTC"),
          starts_on: ~D[2026-08-28],
          ends_on: ~D[2026-09-04]
        )

      assert TimeOff.validate(period, %{"starts_on" => "2026-08-28"}).valid?
      refute TimeOff.validate(period, %{"starts_on" => "2026-08-27"}).valid?
    end

    test "judges past dates against a supplied today instead of reading the profile" do
      profile = insert(:profile, timezone: "Etc/UTC")
      attrs = %{"starts_on" => "2026-08-20", "ends_on" => "2026-08-21"}

      refute TimeOff.validate(profile.id, attrs).valid?
      assert TimeOff.validate(profile.id, attrs, today: ~D[2026-08-01]).valid?
    end
  end

  defp period_for(profile, starts_on, ends_on) do
    insert(:time_off_period, profile: profile, starts_on: starts_on, ends_on: ends_on)
  end

  describe "busy_intervals/4" do
    @window_start ~U[2026-09-01 00:00:00Z]
    @window_end ~U[2026-12-01 00:00:00Z]

    test "publishes a whole-day period from its first midnight to the midnight after it" do
      profile = insert(:profile)
      period_for(profile, ~D[2026-09-10], ~D[2026-09-12])

      assert TimeOff.busy_intervals(profile.id, "Europe/Berlin", @window_start, @window_end) ==
               [{~U[2026-09-09 22:00:00Z], ~U[2026-09-12 22:00:00Z]}]
    end

    test "publishes a part-day period as one interval between its two times" do
      profile = insert(:profile)

      insert(:time_off_period,
        profile: profile,
        starts_on: ~D[2026-09-11],
        ends_on: ~D[2026-09-14],
        start_time: ~T[14:00:00],
        end_time: ~T[09:00:00]
      )

      assert TimeOff.busy_intervals(profile.id, "Europe/Berlin", @window_start, @window_end) ==
               [{~U[2026-09-11 12:00:00Z], ~U[2026-09-14 07:00:00Z]}]
    end

    test "reads each end in the offset in force on its own date" do
      # Berlin leaves summer time on 25 October: the period starts at UTC+2 and
      # ends at UTC+1.
      profile = insert(:profile)
      period_for(profile, ~D[2026-10-24], ~D[2026-10-25])

      assert TimeOff.busy_intervals(profile.id, "Europe/Berlin", @window_start, @window_end) ==
               [{~U[2026-10-23 22:00:00Z], ~U[2026-10-25 23:00:00Z]}]
    end

    test "falls back to UTC for a profile without a timezone" do
      profile = insert(:profile)
      period_for(profile, ~D[2026-09-10], ~D[2026-09-10])

      assert TimeOff.busy_intervals(profile.id, nil, @window_start, @window_end) ==
               [{~U[2026-09-10 00:00:00Z], ~U[2026-09-11 00:00:00Z]}]
    end

    test "leaves out periods outside the window and other profiles' periods" do
      profile = insert(:profile)
      period_for(profile, ~D[2026-12-05], ~D[2026-12-06])
      insert(:time_off_period, starts_on: ~D[2026-09-10], ends_on: ~D[2026-09-10])

      assert TimeOff.busy_intervals(profile.id, "Etc/UTC", @window_start, @window_end) == []
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
