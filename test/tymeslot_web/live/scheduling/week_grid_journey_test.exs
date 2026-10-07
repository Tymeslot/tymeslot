defmodule TymeslotWeb.Live.Scheduling.WeekGridJourneyTest do
  @moduledoc """
  The two journeys a week view exists for, end to end through a real booking
  page: booking a meeting, and moving one, with the time picked straight from
  the week grid. The fixture theme (`test/support/fixture_theme/`) renders the
  shared `WeekGrid` on its schedule step and a plain booking form on its
  booking step; the page is walked through `TymeslotWeb.BookingDriver`, which
  sends the grid's `load_week` binding as a browser would.

  The load-bearing assertions are in the database: the meeting booked, or the
  meeting moved, starts at exactly the day and time clicked, and a reschedule
  leaves the organiser with one meeting, not two. The page opens on a linked
  day nine days out, so the times clicked exist whatever the hour the suite
  runs at.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :scheduling
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @fixture_theme_id "99"
  @timezone "Etc/UTC"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  @tag :capture_log
  test "a visitor books the time they click on the week grid", %{conn: conn} do
    %{user: user, profile: profile} =
      seed_booking_account(@fixture_theme_id, "week-book", @timezone)

    day = linked_day()

    view = open_week(conn, profile, day)
    pick(view, day, "10:00 AM")
    submit_attendee(view, "week-booker@example.com")

    wait_until(fn -> has_element?(view, "[data-testid='fixture-confirmation']") end)

    meeting =
      Repo.get_by!(MeetingSchema,
        organizer_user_id: user.id,
        attendee_email: "week-booker@example.com"
      )

    assert meeting.status == "confirmed"
    assert DateTime.compare(meeting.start_time, at(day, ~T[10:00:00])) == :eq
  end

  @tag :capture_log
  test "a booker moves their meeting to the time they click on the week grid", %{conn: conn} do
    %{user: user, profile: profile} =
      seed_booking_account(@fixture_theme_id, "week-move", @timezone)

    meeting_type = Repo.get_by!(MeetingTypeSchema, user_id: user.id)
    original_start = Date.utc_today() |> Date.add(7) |> at(~T[11:00:00])

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_name: "Week Host",
        meeting_type_id: meeting_type.id,
        attendee_name: "Test Attendee",
        attendee_email: "attendee@example.com",
        attendee_timezone: @timezone,
        start_time: original_start,
        end_time: DateTime.add(original_start, 30, :minute),
        duration: 30,
        status: "confirmed"
      )

    day = linked_day()

    view = open_week(conn, profile, day, [{"reschedule_meeting_uid", meeting.uid}])
    pick(view, day, "2:00 PM")
    submit_attendee(view, "attendee@example.com")

    wait_until(fn -> Repo.get!(MeetingSchema, meeting.id).start_time != original_start end)
    wait_until(fn -> has_element?(view, "[data-testid='fixture-confirmation']") end)

    moved = Repo.get!(MeetingSchema, meeting.id)

    assert DateTime.compare(moved.start_time, at(day, ~T[14:00:00])) == :eq
    assert moved.status == "confirmed"

    assert Repo.aggregate(
             from(m in MeetingSchema, where: m.organizer_user_id == ^user.id),
             :count
           ) ==
             1,
           "rescheduling through the week grid must move the meeting, not book a second one"
  end

  # Nine days out: inside the host's 30-day window, and never today.
  defp linked_day, do: Date.add(Date.utc_today(), 9)

  defp at(date, time), do: DateTime.new!(date, time, @timezone)

  # Overview, then the schedule step, on a page linked to `day`.
  defp open_week(conn, profile, day, extra_params \\ []) do
    query =
      URI.encode_query([{"timezone", @timezone}, {"date", Date.to_iso8601(day)} | extra_params])

    {:ok, view, _html} = live(conn, "/#{profile.username}?#{query}")

    BookingDriver.choose_meeting_type(view, "quick-chat")
    BookingDriver.continue(view)
    view
  end

  defp pick(view, day, time) do
    BookingDriver.pick_slot(view, Date.to_iso8601(day), time)
    BookingDriver.continue(view)

    assert has_element?(view, "form[data-fact='attendee']")
  end

  defp submit_attendee(view, email) do
    BookingDriver.submit(view, %{
      name: "Week Booker",
      email: email,
      message: "Picked from the week grid"
    })
  end
end
