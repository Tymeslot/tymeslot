defmodule TymeslotWeb.BookingPageBookingTest do
  use TymeslotWeb.LiveCase, async: false
  @moduletag :bookings
  @moduletag :scheduling

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.BookingTestHelpers
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

  @timezone "America/New_York"

  setup do
    user = insert(:user)

    profile =
      insert(:profile, user: user, username: "joern", booking_theme: "1", timezone: @timezone)

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
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

    insert(:calendar_integration, user: user, is_active: true)
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    audit = insert(:meeting_type, user: user, name: "ISO audit", duration_minutes: 30)
    :ok = BookingPages.set_meeting_type(page, audit.id, true)

    %{user: user, page: page}
  end

  @tag :capture_log
  test "a booking made under a page records the page", %{conn: conn, user: user, page: page} do
    {:ok, view, _html} = live(conn, ~p"/einfachiso/iso-audit?timezone=#{@timezone}")
    book_first_slot(view, "page-booker@example.com")
    wait_until(fn -> render(view) =~ "Meeting Confirmed!" end)

    meeting =
      Repo.get_by!(MeetingSchema,
        organizer_user_id: user.id,
        attendee_email: "page-booker@example.com"
      )

    assert meeting.booking_page_id == page.id
  end

  @tag :capture_log
  test "a booking made under the username records no page", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/joern/iso-audit?timezone=#{@timezone}")
    book_first_slot(view, "username-booker@example.com")
    wait_until(fn -> render(view) =~ "Meeting Confirmed!" end)

    meeting =
      Repo.get_by!(MeetingSchema,
        organizer_user_id: user.id,
        attendee_email: "username-booker@example.com"
      )

    assert meeting.booking_page_id == nil
  end

  # Same driver as `TymeslotWeb.PrivateBookingTest`.
  defp book_first_slot(view, attendee_email) do
    target_date = @timezone |> DateTime.now!() |> DateTime.to_date() |> Date.add(1)
    BookingTestHelpers.show_month(view, target_date)
    date_str = Date.to_string(target_date)

    wait_until(fn ->
      has_element?(view, "button.calendar-day[phx-value-date='#{date_str}']:not([disabled])")
    end)

    view |> element("button.calendar-day[phx-value-date='#{date_str}']") |> render_click()
    wait_until(fn -> has_element?(view, "button.time-slot-button") end)

    slot =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("button.time-slot-button", "phx-value-time")
      |> List.first()

    view |> element("button.time-slot-button[phx-value-time='#{slot}']") |> render_click()
    view |> element("button[phx-click='next_step']") |> render_click()

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{
        "name" => "Test Attendee",
        "email" => attendee_email,
        "message" => "Looking forward to our chat!"
      }
    })
    |> render_submit()
  end
end
