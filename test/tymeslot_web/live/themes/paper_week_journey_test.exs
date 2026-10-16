defmodule TymeslotWeb.Live.Themes.PaperWeekJourneyTest do
  @moduledoc """
  Paper with its calendar view set to a week, end to end through the real
  booking page: an organiser saves `calendar_view: "week"`, and a booker
  goes from the overview to the schedule screen, picks a time straight from
  the week, which opens the details below it, books it and lands on Paper's
  confirmation with that day and time; and a booker moves an existing
  meeting through the same week. The grid's `load_week` binding is sent by
  hand, since LiveViewTest runs no JS bindings.

  The load-bearing assertions are the meeting in the database, which starts
  at exactly the day and time clicked, and, for a reschedule, the organiser
  still having one meeting, not two. The page opens on a linked day nine
  days out, so the times clicked exist whatever the hour the suite runs at.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :bookings
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
  alias TymeslotWeb.BookingDriver.Page
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @theme_id "3"
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

  defp seed(username) do
    account = seed_booking_account(@theme_id, username, @timezone)

    insert(:theme_customization,
      profile: account.profile,
      theme_id: @theme_id,
      settings: %{"calendar_view" => "week"}
    )

    account
  end

  @tag :capture_log
  test "a booker books the time they click in Paper's week view", %{conn: conn} do
    %{user: user, profile: profile} = seed("paper-week-book")
    day = linked_day()

    view = open_week(conn, profile, day)

    assert has_element?(view, "[data-testid='paper-schedule'][data-calendar-view='week']")
    refute has_element?(view, "[data-testid='calendar-day']")
    assert has_element?(view, "[data-testid='paper-selection']", "Please select a time")

    pick(view, day, "10:00 AM")
    submit(view, "paper-week@example.com")

    wait_until(fn -> has_element?(view, "[data-testid='paper-confirmation']") end)

    assert has_element?(
             view,
             "[data-testid='paper-confirmation'] .paper-fact",
             LocalizationHelpers.format_date(day)
           )

    assert has_element?(view, "[data-testid='paper-confirmation'] .paper-fact", "10:00 AM")

    meeting =
      Repo.get_by!(MeetingSchema,
        organizer_user_id: user.id,
        attendee_email: "paper-week@example.com"
      )

    assert meeting.status == "confirmed"
    assert DateTime.compare(meeting.start_time, at(day, ~T[10:00:00])) == :eq
  end

  @tag :capture_log
  test "a booker moves their meeting to the time they click in Paper's week view",
       %{conn: conn} do
    %{user: user, profile: profile} = seed("paper-week-move")
    meeting_type = Repo.get_by!(MeetingTypeSchema, user_id: user.id)
    original_start = Date.utc_today() |> Date.add(7) |> at(~T[11:00:00])

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_name: "Paper Host",
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
    submit(view, "attendee@example.com")

    wait_until(fn -> Repo.get!(MeetingSchema, meeting.id).start_time != original_start end)
    wait_until(fn -> has_element?(view, "[data-testid='paper-confirmation']") end)

    moved = Repo.get!(MeetingSchema, meeting.id)

    assert DateTime.compare(moved.start_time, at(day, ~T[14:00:00])) == :eq
    assert moved.status == "confirmed"

    assert Repo.aggregate(
             from(m in MeetingSchema, where: m.organizer_user_id == ^user.id),
             :count
           ) == 1,
           "rescheduling through the week view must move the meeting, not book a second one"
  end

  @chip "[data-testid='paper-change-time']"

  test "Change time points at the pressed slot, and shows only while that week is on screen",
       %{conn: conn} do
    %{profile: profile} = seed("paper-week-chip")
    day = linked_day()

    view = open_week(conn, profile, day)
    refute has_element?(view, @chip)

    pick(view, day, "10:00 AM")

    assert has_element?(view, @chip)
    selector = Page.focus_target(view, @chip)
    assert selector =~ "#schedule-step"
    assert has_element?(view, selector)

    # Paging keeps the chosen time, but its slot leaves the page, so the
    # chip would focus nothing.
    page_week(view, "next")
    refute has_element?(view, @chip)
    assert has_element?(view, "form[data-testid='booking-form']")

    page_week(view, "prev")
    assert has_element?(view, @chip)
    assert has_element?(view, Page.focus_target(view, @chip))
  end

  defp page_week(view, direction) do
    view |> element("[data-testid='week-grid-#{direction}']") |> render_click()
    render_async(view)
  end

  # Nine days out: inside the host's 30-day window, and never today.
  defp linked_day, do: Date.add(Date.utc_today(), 9)

  defp at(date, time), do: DateTime.new!(date, time, @timezone)

  # Overview, schedule step, and the week the linked day is in, loaded as
  # the grid's phx-mounted binding would load it.
  defp open_week(conn, profile, day, extra_params \\ []) do
    query =
      URI.encode_query([{"timezone", @timezone}, {"date", Date.to_iso8601(day)} | extra_params])

    {:ok, view, _html} = live(conn, "/#{profile.username}?#{query}")

    assert has_element?(view, "[data-testid='paper-overview']")

    view |> element("[data-testid='duration-option']") |> render_click()

    assert has_element?(view, "[data-testid='paper-week'] [data-testid='week-grid']")

    view |> with_target("[data-testid='paper-schedule']") |> render_click("load_week", %{})
    render_async(view)

    view
  end

  defp pick(view, day, time) do
    view
    |> element(
      "[data-testid='week-slot'][data-date='#{Date.to_iso8601(day)}'][data-time='#{time}']"
    )
    |> render_click()

    assert has_element?(
             view,
             "[data-testid='paper-selection'] .paper-selection__date",
             LocalizationHelpers.format_full_date_label(day)
           )

    assert has_element?(view, "form[data-testid='booking-form']")
  end

  defp submit(view, email) do
    view
    |> form("form[data-testid='booking-form']", %{
      "booking" => %{
        "name" => "Week Booker",
        "email" => email,
        "message" => "Picked from Paper's week"
      }
    })
    |> render_submit()
  end
end
