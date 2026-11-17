defmodule Tymeslot.Availability.OpeningTest do
  @moduledoc """
  "Open for booking": a slot the organiser picked becomes bookable for a
  meeting type, once (that date's hours widen through an override) or every
  week (the weekday's hours widen), and `restore/2` puts the schedule back.
  Each case is checked where a guest sees it, on the booking page.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.AvailabilityActions
  alias Tymeslot.Availability.DateOverrides
  alias Tymeslot.Availability.Opening
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Test.ClockHelpers
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()

    host = create_bookable_profile(days: [1, 2, 3, 4, 5])
    meeting_type = insert(:meeting_type, user: host.user, duration_minutes: 30)
    date = next_bookable_weekday()
    saturday = date |> Date.beginning_of_week(:monday) |> Date.add(5)

    Map.merge(host, %{meeting_type: meeting_type, date: date, saturday: saturday})
  end

  defp at(date, time, timezone \\ "Etc/UTC"), do: DateTime.new!(date, time, timezone)

  defp page(host, date), do: offered(host.profile, date, 30, meeting_type: host.meeting_type)

  describe "open_once/4" do
    test "widens that date's hours to take in the slot", host do
      refute "6:00 PM" in page(host, host.date)

      assert {:ok, result} =
               Opening.open_once(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.date, ~T[18:00:00]),
                 at(host.date, ~T[19:00:00])
               )

      assert %{
               kind: :once,
               date: date,
               start_time: ~T[11:00:00],
               end_time: ~T[19:00:00],
               ends_next_day: false,
               previous: nil
             } = result

      assert date == host.date
      assert "6:00 PM" in page(host, host.date)
      assert "3:00 PM" in page(host, host.date)
      refute "6:00 PM" in page(host, Date.add(host.date, 7))
    end

    test "opens a closed day on exactly the slot", host do
      assert {:ok, %{start_time: ~T[18:00:00], end_time: ~T[19:00:00]}} =
               Opening.open_once(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.saturday, ~T[18:00:00]),
                 at(host.saturday, ~T[19:00:00])
               )

      assert page(host, host.saturday) == ["6:00 PM", "6:30 PM"]
    end

    test "an unavailable day is replaced by exactly the slot, and restore closes it again",
         host do
      insert(:availability_override,
        schedule: host.schedule,
        date: host.date,
        override_type: :unavailable
      )

      assert {:ok, result} =
               Opening.open_once(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.date, ~T[18:00:00]),
                 at(host.date, ~T[19:00:00])
               )

      assert %{start_time: ~T[18:00:00], previous: %{override_type: :unavailable}} = result
      assert page(host, host.date) == ["6:00 PM", "6:30 PM"]

      assert :ok = Opening.restore(host.user.id, result)
      assert page(host, host.date) == []

      assert {:ok, %{override_type: :unavailable}} =
               DateOverrides.get(host.profile_id, host.schedule_id, host.date)
    end

    test "restore removes the override it added", host do
      {:ok, result} =
        Opening.open_once(
          host.user.id,
          host.meeting_type.id,
          at(host.date, ~T[18:00:00]),
          at(host.date, ~T[19:00:00])
        )

      assert :ok = Opening.restore(host.user.id, result)
      assert {:ok, nil} = DateOverrides.get(host.profile_id, host.schedule_id, host.date)
      refute "6:00 PM" in page(host, host.date)
    end

    test "reads the slot on the organiser's clock" do
      host = create_bookable_profile(timezone: "Europe/Berlin", days: [1, 2, 3, 4, 5])
      meeting_type = insert(:meeting_type, user: host.user, duration_minutes: 30)
      date = next_bookable_weekday()

      assert {:ok, %{date: ^date, start_time: ~T[11:00:00], end_time: ~T[19:00:00]}} =
               Opening.open_once(
                 host.user.id,
                 meeting_type.id,
                 at(date, ~T[18:00:00], "Europe/Berlin"),
                 at(date, ~T[19:00:00], "Europe/Berlin")
               )
    end

    test "reads the slot on the zone the caller names, when it names one", host do
      assert {:ok, %{start_time: ~T[11:00:00], end_time: ~T[19:00:00]}} =
               Opening.open_once(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.date, ~T[18:00:00], "America/New_York"),
                 at(host.date, ~T[19:00:00], "America/New_York"),
                 timezone: "America/New_York"
               )

      assert {:ok, %{start_time: ~T[11:00:00], end_time: ~T[19:00:00]}} =
               DateOverrides.get(host.profile_id, host.schedule_id, host.date)
    end

    test "restore puts back a widened override's exact hours and reason", host do
      insert(:availability_override,
        schedule: host.schedule,
        date: host.date,
        override_type: :custom_hours,
        start_time: ~T[10:00:00],
        end_time: ~T[12:00:00],
        reason: "Dentist"
      )

      {:ok, result} =
        Opening.open_once(
          host.user.id,
          host.meeting_type.id,
          at(host.date, ~T[18:00:00]),
          at(host.date, ~T[19:00:00])
        )

      assert %{start_time: ~T[10:00:00], end_time: ~T[19:00:00]} = result
      assert :ok = Opening.restore(host.user.id, result)

      assert {:ok,
              %{
                override_type: :custom_hours,
                start_time: ~T[10:00:00],
                end_time: ~T[12:00:00],
                reason: "Dentist"
              }} = DateOverrides.get(host.profile_id, host.schedule_id, host.date)
    end

    test "an undo after midnight still puts the old override back", host do
      insert(:availability_override,
        schedule: host.schedule,
        date: host.date,
        override_type: :custom_hours,
        start_time: ~T[10:00:00],
        end_time: ~T[12:00:00]
      )

      ClockHelpers.freeze_clock(at(host.date, ~T[22:00:00]))

      {:ok, result} =
        Opening.open_once(
          host.user.id,
          host.meeting_type.id,
          at(host.date, ~T[23:00:00]),
          at(host.date, ~T[23:30:00])
        )

      assert %{end_time: ~T[23:30:00]} = result
      ClockHelpers.freeze_clock(at(Date.add(host.date, 1), ~T[00:30:00]))

      assert :ok = Opening.restore(host.user.id, result)

      assert {:ok, %{start_time: ~T[10:00:00], end_time: ~T[12:00:00]}} =
               DateOverrides.get(host.profile_id, host.schedule_id, host.date)
    end

    test "a slot running past midnight makes an overnight window", host do
      assert {:ok, %{start_time: ~T[11:00:00], end_time: ~T[01:00:00], ends_next_day: true}} =
               Opening.open_once(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.date, ~T[23:00:00]),
                 at(Date.add(host.date, 1), ~T[01:00:00])
               )
    end

    test "refuses a slot over 24 hours, and a widened day over 24 hours", host do
      assert {:error, :widened_too_long} =
               Opening.open_once(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.date, ~T[23:00:00]),
                 at(Date.add(host.date, 1), ~T[12:00:00])
               )

      assert {:error, :too_long} =
               Opening.open_once(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.date, ~T[10:00:00]),
                 at(Date.add(host.date, 1), ~T[11:00:00])
               )
    end

    test "refuses a slot already over, or one that ends before it starts", host do
      yesterday = Date.add(Date.utc_today(), -1)

      assert {:error, :in_past} =
               Opening.open_once(
                 host.user.id,
                 host.meeting_type.id,
                 at(yesterday, ~T[18:00:00]),
                 at(yesterday, ~T[19:00:00])
               )

      assert {:error, :invalid_range} =
               Opening.open_once(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.date, ~T[19:00:00]),
                 at(host.date, ~T[18:00:00])
               )
    end

    test "refuses another user's, an archived or an inactive meeting type", host do
      archived = insert(:meeting_type, user: host.user, is_archived: true)
      inactive = insert(:meeting_type, user: host.user, is_active: false)

      for meeting_type <- [insert(:meeting_type), archived, inactive] do
        assert {:error, :not_found} =
                 Opening.open_once(
                   host.user.id,
                   meeting_type.id,
                   at(host.date, ~T[18:00:00]),
                   at(host.date, ~T[19:00:00])
                 )
      end

      assert {:ok, nil} = DateOverrides.get(host.profile_id, host.schedule_id, host.date)
    end
  end

  describe "open_weekly/4" do
    test "widens that weekday's hours every week, and restore narrows them back", host do
      day = Date.day_of_week(host.date)

      assert {:ok, result} =
               Opening.open_weekly(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.date, ~T[18:00:00]),
                 at(host.date, ~T[19:00:00])
               )

      assert %{
               kind: :weekly,
               day_of_week: ^day,
               start_time: ~T[11:00:00],
               end_time: ~T[19:00:00],
               previous: %{is_available: true, start_time: ~T[11:00:00], end_time: ~T[17:00:00]}
             } = result

      assert "6:00 PM" in page(host, Date.add(host.date, 7))

      assert :ok = Opening.restore(host.user.id, result)
      refute "6:00 PM" in page(host, Date.add(host.date, 7))
      assert "4:00 PM" in page(host, Date.add(host.date, 7))
    end

    test "opens a closed weekday, and restore closes it", host do
      assert {:ok, result} =
               Opening.open_weekly(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.saturday, ~T[18:00:00]),
                 at(host.saturday, ~T[19:00:00])
               )

      assert %{previous: %{is_available: false}} = result
      assert page(host, Date.add(host.saturday, 7)) == ["6:00 PM", "6:30 PM"]

      assert :ok = Opening.restore(host.user.id, result)
      assert page(host, Date.add(host.saturday, 7)) == []
      assert %{is_available: false} = WeeklySchedule.get_day_availability(host.schedule_id, 6)
    end

    test "restore closes a day again with its stored hours and breaks intact", host do
      row =
        insert(:weekly_availability,
          schedule: host.schedule,
          day_of_week: 6,
          is_available: false,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        )

      insert(:availability_break,
        weekly_availability: row,
        start_time: ~T[12:30:00],
        end_time: ~T[13:00:00]
      )

      {:ok, result} =
        Opening.open_weekly(
          host.user.id,
          host.meeting_type.id,
          at(host.saturday, ~T[12:00:00]),
          at(host.saturday, ~T[14:00:00])
        )

      assert :ok = Opening.restore(host.user.id, result)

      assert %{
               is_available: false,
               start_time: ~T[09:00:00],
               end_time: ~T[17:00:00],
               breaks: [%{start_time: ~T[12:30:00], end_time: ~T[13:00:00]}]
             } = WeeklySchedule.get_day_availability(host.schedule_id, 6)
    end

    test "also opens this week's date when it has an override, and restore undoes both",
         host do
      insert(:availability_override,
        schedule: host.schedule,
        date: host.date,
        override_type: :custom_hours,
        start_time: ~T[10:00:00],
        end_time: ~T[12:00:00]
      )

      refute "6:00 PM" in page(host, host.date)

      assert {:ok, result} =
               Opening.open_weekly(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.date, ~T[18:00:00]),
                 at(host.date, ~T[19:00:00])
               )

      assert %{previous: %{override: %{date: date, was: %{end_time: ~T[12:00:00]}}}} = result
      assert date == host.date
      assert "6:00 PM" in page(host, host.date)
      assert "6:00 PM" in page(host, Date.add(host.date, 7))

      assert :ok = Opening.restore(host.user.id, result)
      refute "6:00 PM" in page(host, Date.add(host.date, 7))

      assert {:ok, %{start_time: ~T[10:00:00], end_time: ~T[12:00:00]}} =
               DateOverrides.get(host.profile_id, host.schedule_id, host.date)
    end

    test "refuses to strand a break the closed day still holds", host do
      row =
        insert(:weekly_availability,
          schedule: host.schedule,
          day_of_week: 6,
          is_available: false
        )

      insert(:availability_break,
        weekly_availability: row,
        start_time: ~T[12:00:00],
        end_time: ~T[13:00:00]
      )

      assert {:error, :breaks_outside_hours} =
               Opening.open_weekly(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.saturday, ~T[18:00:00]),
                 at(host.saturday, ~T[19:00:00])
               )
    end

    test "a date write refused after the weekday widened leaves the weekday as it was",
         host do
      wednesday = Date.add(host.saturday, -3)
      yesterday = Date.add(wednesday, -1)

      insert(:availability_override,
        schedule: host.schedule,
        date: yesterday,
        override_type: :custom_hours,
        start_time: ~T[10:00:00],
        end_time: ~T[12:00:00]
      )

      # Just past midnight, a slot starting late yesterday still runs, but
      # yesterday's override can no longer be written.
      ClockHelpers.freeze_clock(at(wednesday, ~T[00:10:00]))

      assert {:error, :in_past} =
               Opening.open_weekly(
                 host.user.id,
                 host.meeting_type.id,
                 at(yesterday, ~T[23:30:00]),
                 at(wednesday, ~T[00:30:00])
               )

      assert %{start_time: ~T[11:00:00], end_time: ~T[17:00:00], ends_next_day: false} =
               WeeklySchedule.get_day_availability(host.schedule_id, Date.day_of_week(yesterday))
    end
  end

  describe "restore/2" do
    test "a weekly restore whose date part fails leaves the weekday as the opening left it",
         host do
      day = Date.day_of_week(host.date)

      insert(:availability_override,
        schedule: host.schedule,
        date: host.date,
        override_type: :custom_hours,
        start_time: ~T[10:00:00],
        end_time: ~T[12:00:00]
      )

      {:ok, result} =
        Opening.open_weekly(
          host.user.id,
          host.meeting_type.id,
          at(host.date, ~T[18:00:00]),
          at(host.date, ~T[19:00:00])
        )

      # An override that cannot be saved, so putting the date back fails
      # after the weekday was put back.
      broken = put_in(result, [:previous, :override, :was, :override_type], "unknown")

      assert {:error, :invalid_hours} = Opening.restore(host.user.id, broken)

      assert %{start_time: ~T[11:00:00], end_time: ~T[19:00:00]} =
               WeeklySchedule.get_day_availability(host.schedule_id, day)

      assert {:ok, %{start_time: ~T[10:00:00], end_time: ~T[19:00:00]}} =
               DateOverrides.get(host.profile_id, host.schedule_id, host.date)
    end

    test "refuses a weekly restore that would strand a break added since", host do
      day = Date.day_of_week(host.date)

      {:ok, result} =
        Opening.open_weekly(
          host.user.id,
          host.meeting_type.id,
          at(host.date, ~T[18:00:00]),
          at(host.date, ~T[19:00:00])
        )

      row = WeeklySchedule.get_day_availability(host.schedule_id, day)

      {:ok, _break} =
        AvailabilityActions.add_break(host.profile_id, row.id, "17:30", "18:00", "")

      assert {:error, :changed} = Opening.restore(host.user.id, result)

      assert %{
               start_time: ~T[11:00:00],
               end_time: ~T[19:00:00],
               breaks: [%{start_time: ~T[17:30:00], end_time: ~T[18:00:00]}]
             } = WeeklySchedule.get_day_availability(host.schedule_id, day)
    end

    test "refuses once the date's hours changed since, and leaves them", host do
      {:ok, result} =
        Opening.open_once(
          host.user.id,
          host.meeting_type.id,
          at(host.date, ~T[18:00:00]),
          at(host.date, ~T[19:00:00])
        )

      {:ok, _override} =
        DateOverrides.upsert(host.profile_id, host.schedule_id, %{
          date: host.date,
          override_type: :custom_hours,
          start_time: ~T[08:00:00],
          end_time: ~T[19:00:00]
        })

      assert {:error, :changed} = Opening.restore(host.user.id, result)

      assert {:ok, %{start_time: ~T[08:00:00], end_time: ~T[19:00:00]}} =
               DateOverrides.get(host.profile_id, host.schedule_id, host.date)
    end

    test "refuses once the date's override was removed since", host do
      {:ok, result} =
        Opening.open_once(
          host.user.id,
          host.meeting_type.id,
          at(host.date, ~T[18:00:00]),
          at(host.date, ~T[19:00:00])
        )

      :ok = DateOverrides.delete(host.profile_id, host.schedule_id, host.date)

      assert {:error, :changed} = Opening.restore(host.user.id, result)
      assert {:ok, nil} = DateOverrides.get(host.profile_id, host.schedule_id, host.date)
    end

    test "refuses once the weekday's hours changed since, and leaves them", host do
      day = Date.day_of_week(host.date)

      {:ok, result} =
        Opening.open_weekly(
          host.user.id,
          host.meeting_type.id,
          at(host.date, ~T[18:00:00]),
          at(host.date, ~T[19:00:00])
        )

      {:ok, _row} =
        AvailabilityActions.update_day_hours(
          host.profile_id,
          host.schedule_id,
          day,
          "09:00",
          "19:00"
        )

      assert {:error, :changed} = Opening.restore(host.user.id, result)

      assert %{start_time: ~T[09:00:00], end_time: ~T[19:00:00]} =
               WeeklySchedule.get_day_availability(host.schedule_id, day)
    end

    test "refuses a weekly opening whose widened date changed since, writing nothing", host do
      day = Date.day_of_week(host.date)

      insert(:availability_override,
        schedule: host.schedule,
        date: host.date,
        override_type: :custom_hours,
        start_time: ~T[10:00:00],
        end_time: ~T[12:00:00]
      )

      {:ok, result} =
        Opening.open_weekly(
          host.user.id,
          host.meeting_type.id,
          at(host.date, ~T[18:00:00]),
          at(host.date, ~T[19:00:00])
        )

      :ok = DateOverrides.delete(host.profile_id, host.schedule_id, host.date)

      assert {:error, :changed} = Opening.restore(host.user.id, result)

      assert %{start_time: ~T[11:00:00], end_time: ~T[19:00:00]} =
               WeeklySchedule.get_day_availability(host.schedule_id, day)
    end

    test "does nothing for another user", host do
      {:ok, result} =
        Opening.open_once(
          host.user.id,
          host.meeting_type.id,
          at(host.date, ~T[18:00:00]),
          at(host.date, ~T[19:00:00])
        )

      %{user: other} = create_bookable_profile()

      assert {:error, :not_found} = Opening.restore(other.id, result)
      assert "6:00 PM" in page(host, host.date)
    end
  end
end
