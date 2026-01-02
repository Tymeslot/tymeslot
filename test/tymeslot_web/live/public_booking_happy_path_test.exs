defmodule TymeslotWeb.PublicBookingHappyPathTest do
  use TymeslotWeb.LiveCase, async: false

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :verify_on_exit!

  setup do
    Mox.set_mox_global()
    ensure_rate_limiter_started()
    RateLimiter.clear_all()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:list_events_in_range, fn _start_dt, _end_dt -> {:ok, []} end)

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
        timezone: timezone,
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
        profile: profile,
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
    |> element("button[phx-value-duration='30min']")
    |> render_click()

    view
    |> element("button[phx-click='next_step']")
    |> render_click()

    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target_date = Date.add(today, 1)
    target_date = maybe_advance_calendar_to_month(view, today, target_date)
    date_str = Date.to_string(target_date)

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

    meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: attendee_email)
    assert meeting.status == "confirmed"
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

  defp wait_until(predicate, timeout_ms \\ 5_000, interval_ms \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(predicate, deadline, interval_ms)
  end

  defp do_wait_until(predicate, deadline, interval_ms) do
    if predicate.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Timed out waiting for UI condition")
      end

      Process.sleep(interval_ms)
      do_wait_until(predicate, deadline, interval_ms)
    end
  end

  defp ensure_rate_limiter_started do
    case Process.whereis(Tymeslot.Security.RateLimiter) do
      nil -> start_supervised!(Tymeslot.Security.RateLimiter)
      _pid -> :ok
    end
  end
end
