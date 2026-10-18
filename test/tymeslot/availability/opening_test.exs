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

  alias Tymeslot.Availability.DateOverrides
  alias Tymeslot.Availability.Opening
  alias Tymeslot.Availability.WeeklySchedule
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
        override_type: "unavailable"
      )

      assert {:ok, result} =
               Opening.open_once(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.date, ~T[18:00:00]),
                 at(host.date, ~T[19:00:00])
               )

      assert %{start_time: ~T[18:00:00], previous: %{override_type: "unavailable"}} = result
      assert page(host, host.date) == ["6:00 PM", "6:30 PM"]

      assert :ok = Opening.restore(host.user.id, result)
      assert page(host, host.date) == []

      assert {:ok, %{override_type: "unavailable"}} =
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

    test "a slot running past midnight makes an overnight window", host do
      assert {:ok, %{start_time: ~T[11:00:00], end_time: ~T[01:00:00], ends_next_day: true}} =
               Opening.open_once(
                 host.user.id,
                 host.meeting_type.id,
                 at(host.date, ~T[23:00:00]),
                 at(Date.add(host.date, 1), ~T[01:00:00])
               )
    end

    test "refuses a window that would pass 24 hours", host do
      assert {:error, :too_long} =
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
  end

  describe "restore/2" do
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
