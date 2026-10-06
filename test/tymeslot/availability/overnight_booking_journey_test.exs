defmodule Tymeslot.Availability.OvernightBookingJourneyTest do
  @moduledoc """
  A booker sees a slot that crosses midnight and books it; the meeting lands
  on the instant offered and the booking page then stops offering it.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :availability
  @moduletag :bookings
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Bookings.{Create, Reschedule}
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    :ok
  end

  defp book(host, date, time, duration, timezone) do
    Create.execute(
      %{
        date: date,
        time: time,
        duration: "#{duration}min",
        user_timezone: timezone,
        organizer_user_id: host.user.id,
        meeting_type_id: nil
      },
      %{
        "name" => "Night Owl",
        "email" => "owl-#{System.unique_integer([:positive])}@example.com",
        "message" => ""
      }
    )
  end

  test "a 24/7 host can be booked for 24 hours" do
    host =
      create_bookable_profile(
        timezone: "Europe/Berlin",
        days: Enum.to_list(1..7),
        hours: %{
          is_available: true,
          start_time: ~T[00:00:00],
          end_time: ~T[00:00:00],
          ends_next_day: true
        }
      )

    date = next_bookable_weekday()

    assert offered(host.profile, date, 1440) == ["12:00 AM"]

    assert {:ok, %MeetingSchema{} = meeting} = book(host, date, "12:00 AM", 1440, "Europe/Berlin")
    assert DateTime.diff(meeting.end_time, meeting.start_time, :minute) == 1440

    assert DateTime.shift_zone!(meeting.start_time, "Europe/Berlin") ==
             DateTime.new!(date, ~T[00:00:00], "Europe/Berlin")

    # The day is now taken, and so is every 24-hour start that would overlap it.
    assert offered(host.profile, date, 1440) == []
    assert offered(host.profile, Date.add(date, 1), 1440) == []
  end

  test "a slot after midnight is listed under the date it starts on and books there" do
    weekday = next_bookable_weekday()

    host =
      create_bookable_profile(
        timezone: "Europe/London",
        days: [Date.day_of_week(weekday)],
        hours: %{
          is_available: true,
          start_time: ~T[22:00:00],
          end_time: ~T[02:00:00],
          ends_next_day: true
        }
      )

    next_day = Date.add(weekday, 1)

    assert offered(host.profile, weekday, 60) == ["10:00 PM", "11:00 PM"]
    assert offered(host.profile, next_day, 60) == ["12:00 AM", "1:00 AM"]

    assert {:ok, meeting} = book(host, next_day, "1:00 AM", 60, "Europe/London")

    assert DateTime.shift_zone!(meeting.start_time, "Europe/London") ==
             DateTime.new!(next_day, ~T[01:00:00], "Europe/London")

    # The same label under the previous date is not on offer and is refused.
    assert {:error, :slot_taken} = book(host, weekday, "1:00 AM", 60, "Europe/London")

    # Rescheduling back across midnight goes through the same rule, and lands
    # on the evening before.
    assert {:ok, %MeetingSchema{} = moved} =
             Reschedule.execute(
               meeting.uid,
               %{
                 date: Date.to_string(weekday),
                 time: "11:00 PM",
                 duration: "60min",
                 user_timezone: "Europe/London"
               },
               %{},
               meeting.organizer_user_id
             )

    assert moved.id == meeting.id

    assert DateTime.compare(
             moved.start_time,
             DateTime.new!(weekday, ~T[23:00:00], "Europe/London")
           ) == :eq

    assert DateTime.diff(moved.end_time, moved.start_time, :minute) == 60
  end

  test "the hour repeated when London's clocks go back is offered and booked once" do
    # Sat 2026-10-24 22:00 BST to Sun 03:00 GMT: 01:00 to 02:00 happens twice.
    freeze_clock(~U[2026-10-14 12:00:00Z])
    sunday = ~D[2026-10-25]

    host =
      create_bookable_profile(
        timezone: "Europe/London",
        days: [6],
        hours: %{
          is_available: true,
          start_time: ~T[22:00:00],
          end_time: ~T[03:00:00],
          ends_next_day: true
        }
      )

    assert offered(host.profile, sunday, 60) == ["12:00 AM", "1:00 AM", "2:00 AM"]

    # The label means the first pass, in summer time, and runs a real hour.
    assert {:ok, meeting} = book(host, sunday, "1:00 AM", 60, "Europe/London")
    assert meeting.start_time == ~U[2026-10-25 00:00:00Z]
    assert DateTime.diff(meeting.end_time, meeting.start_time, :minute) == 60

    # The schedule's default 15-minute buffers take 12:00 AM, which ends as
    # the booking starts. 2:00 AM survives: the repeated hour, 01:00 GMT, sits
    # between it and the booking, and is not a second chance at the label.
    assert offered(host.profile, sunday, 60) == ["2:00 AM"]
    assert {:error, :slot_taken} = book(host, sunday, "1:00 AM", 60, "Europe/London")

    assert {:ok, last} = book(host, sunday, "2:00 AM", 60, "Europe/London")
    assert last.start_time == ~U[2026-10-25 02:00:00Z]
    assert last.end_time == ~U[2026-10-25 03:00:00Z]
  end

  test "a booker far east of the host can book the slot ending at their midnight" do
    weekday = next_bookable_weekday()

    host =
      create_bookable_profile(
        timezone: "Europe/London",
        days: [Date.day_of_week(weekday)],
        hours: %{is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00]}
      )

    tokyo_date = weekday
    assert "11:00 PM" in offered(host.profile, tokyo_date, 60, timezone: "Asia/Tokyo")
    assert {:ok, _meeting} = book(host, tokyo_date, "11:00 PM", 60, "Asia/Tokyo")
  end
end
