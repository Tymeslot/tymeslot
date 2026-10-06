defmodule TymeslotWeb.Dashboard.Availability.BufferBookingJourneyTest do
  @moduledoc """
  The organiser sets a buffer before and a buffer after on the availability
  page, and a visitor on the public booking page is offered exactly the times
  those two values allow around an existing booking, then books one of them.

  The values are deliberately lopsided (30 before, none after) so the journey
  fails if any step applies a buffer on the wrong side: swapped, the time that
  ends as the booking starts would be hidden, and the time that starts as it
  ends would be offered.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :availability
  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Utils.DateTimeUtils.Display

  @timezone "America/New_York"

  setup :verify_on_exit!

  setup %{conn: conn} = tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())

    profile =
      insert(:profile,
        user: user,
        username: "buffers#{System.unique_integer([:positive])}",
        booking_theme: "1",
        timezone: @timezone
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        # Both clicks below change a value: before 0 -> 30, after 15 -> 0.
        buffer_before_minutes: 0,
        buffer_after_minutes: 15
      )

    for day_of_week <- 1..7 do
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end

    insert(:calendar_integration, user: user, is_active: true)
    insert(:meeting_type, user: user, name: "Quick Chat", duration_minutes: 30, is_active: true)

    date = @timezone |> DateTime.now!() |> DateTime.to_date() |> Date.add(1)
    booked_start = DateTime.new!(date, ~T[12:00:00], @timezone)

    insert(:meeting,
      organizer_user_id: user.id,
      start_time: booked_start,
      end_time: DateTime.add(booked_start, 30, :minute)
    )

    owner_conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    %{owner_conn: owner_conn, user: user, profile: profile, schedule: schedule, date: date}
  end

  @tag :capture_log
  test "the buffers set on the availability page decide which times a visitor can book",
       %{owner_conn: owner_conn, user: user, profile: profile, schedule: schedule, date: date} do
    {:ok, dashboard, _html} = live(owner_conn, ~p"/dashboard/availability")

    dashboard
    |> element("[phx-click='update_buffer_before_minutes'][phx-value-buffer_before_minutes='30']")
    |> render_click()

    dashboard
    |> element("[phx-click='update_buffer_after_minutes'][phx-value-buffer_after_minutes='0']")
    |> render_click()

    schedule = Repo.reload!(schedule)
    assert {schedule.buffer_before_minutes, schedule.buffer_after_minutes} == {30, 0}

    view = open_day(build_conn(), profile, date)
    offered = rendered_times(view)

    # 11:30-12:00 ends as the booking starts, and nothing is wanted after it
    # any more (the starting 15-minute after-buffer would have hidden it).
    assert time(~T[11:30:00]) in offered
    # 12:30 starts as the booking ends, inside the 30-minute before-buffer.
    refute time(~T[12:30:00]) in offered
    # 13:00 clears it.
    assert time(~T[13:00:00]) in offered

    attendee_email = "buffer-journey@example.com"
    book(view, time(~T[11:30:00]), attendee_email)

    meeting =
      Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: attendee_email)

    assert meeting.status == "confirmed"

    assert DateTime.compare(meeting.start_time, DateTime.new!(date, ~T[11:30:00], @timezone)) ==
             :eq
  end

  defp open_day(conn, profile, date) do
    {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=#{@timezone}")

    view |> element("button[phx-value-duration='quick-chat']") |> render_click()
    view |> element("button[phx-click='next_step']") |> render_click()

    BookingTestHelpers.show_month(view, date)
    date_str = Date.to_string(date)

    wait_until(fn ->
      has_element?(view, "button.calendar-day[phx-value-date='#{date_str}']:not([disabled])")
    end)

    view |> element("button.calendar-day[phx-value-date='#{date_str}']") |> render_click()
    wait_until(fn -> has_element?(view, "button.time-slot-button") end)

    view
  end

  defp rendered_times(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute("button.time-slot-button", "phx-value-time")
  end

  defp time(time), do: Display.format_time_for_display(time)

  defp book(view, slot, email) do
    view |> element("button.time-slot-button[phx-value-time='#{slot}']") |> render_click()
    view |> element("button[phx-click='next_step']") |> render_click()

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{
        "name" => "Buffer Journey",
        "email" => email,
        "message" => "Booked right next to an existing meeting"
      }
    })
    |> render_submit()

    wait_until(fn -> render(view) =~ "Meeting Confirmed!" end)
  end
end
