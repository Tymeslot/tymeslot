defmodule TymeslotWeb.PublicBookingHappyPathTest do
  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()

    TestMocks.setup_all_mocks()

    :ok
  end

  @tag :capture_log
  test "visitor can book a meeting end-to-end (public link)", %{conn: conn} do
    timezone = "America/New_York"
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "booker1",
        booking_theme: "1",
        timezone: timezone
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    _meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Quick Chat",
        is_active: true
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    _integration =
      insert(:calendar_integration,
        user: user,
        is_active: true
      )

    {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=#{timezone}")

    view
    |> element("button[phx-value-duration='quick-chat']")
    |> render_click()

    view
    |> element("button[phx-click='next_step']")
    |> render_click()

    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target_date = Date.add(today, 1)
    target_date = maybe_advance_calendar_to_month(view, today, target_date)
    date_str = Date.to_string(target_date)

    wait_until(fn ->
      has_element?(view, "button.calendar-day[phx-value-date='#{date_str}']:not([disabled])")
    end)

    view
    |> element("button.calendar-day[phx-value-date='#{date_str}']")
    |> render_click()

    wait_until(fn -> has_element?(view, "button.time-slot-button") end)

    slot =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("button.time-slot-button", "phx-value-time")
      |> List.first() ||
        flunk("Expected at least one available time slot button after selecting a date")

    view
    |> element("button.time-slot-button[phx-value-time='#{slot}']")
    |> render_click()

    view
    |> element("button[phx-click='next_step']")
    |> render_click()

    attendee_email = "attendee@example.com"

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{
        "name" => "Test Attendee",
        "email" => attendee_email,
        "message" => "Hello!"
      }
    })
    |> render_submit()

    wait_until(fn -> render(view) =~ "Meeting Confirmed!" end)

    assert render(view) =~ attendee_email

    meeting =
      Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: attendee_email)

    assert meeting.status == "confirmed"
  end

  @tag :capture_log
  test "booking respects meeting type duration (regression: issue #17)", %{conn: conn} do
    timezone = "America/New_York"
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "booker2",
        booking_theme: "1",
        timezone: timezone
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    _meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 60,
        name: "60 Minutes",
        is_active: true
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    _integration =
      insert(:calendar_integration,
        user: user,
        is_active: true
      )

    {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=#{timezone}")

    view
    |> element("button[phx-value-duration='60-minutes']")
    |> render_click()

    view
    |> element("button[phx-click='next_step']")
    |> render_click()

    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target_date = Date.add(today, 1)
    target_date = maybe_advance_calendar_to_month(view, today, target_date)
    date_str = Date.to_string(target_date)

    wait_until(fn ->
      has_element?(view, "button.calendar-day[phx-value-date='#{date_str}']:not([disabled])")
    end)

    view
    |> element("button.calendar-day[phx-value-date='#{date_str}']")
    |> render_click()

    wait_until(fn -> has_element?(view, "button.time-slot-button") end)

    slot =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("button.time-slot-button", "phx-value-time")
      |> List.first() ||
        flunk("Expected at least one available time slot button after selecting a date")

    view
    |> element("button.time-slot-button[phx-value-time='#{slot}']")
    |> render_click()

    view
    |> element("button[phx-click='next_step']")
    |> render_click()

    attendee_email = "attendee60@example.com"

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{
        "name" => "Test Attendee",
        "email" => attendee_email,
        "message" => "Hello!"
      }
    })
    |> render_submit()

    wait_until(fn -> render(view) =~ "Meeting Confirmed!" end)

    meeting =
      Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: attendee_email)

    assert meeting.status == "confirmed"
    assert meeting.duration == 60, "Expected 60-minute duration but got #{meeting.duration}"
  end

  defp maybe_advance_calendar_to_month(view, today, target_date) do
    # The schedule view starts at the current month in the user's timezone. If the
    # next-day date rolled into the next month, advance once so the date is selectable.
    if {target_date.year, target_date.month} != {today.year, today.month} do
      view
      |> element("button[phx-click='next_month']")
      |> render_click()
    end

    target_date
  end
end
