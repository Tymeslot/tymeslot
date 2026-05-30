defmodule TymeslotWeb.PrivateBookingHappyPathTest do
  @moduledoc """
  End-to-end test for private booking links (/b/:token).
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes
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
  test "visitor can book a meeting via a private booking link", %{conn: conn} do
    timezone = "America/New_York"
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "privatehost",
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
        name: "Private Chat",
        is_active: true,
        is_private: true
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

    # Get the private meeting type directly (list_active_meeting_types excludes private ones)
    all_types = MeetingTypes.get_all_meeting_types(user.id)
    mt = Enum.find(all_types, &(&1.is_private == true))

    token = Tymeslot.MeetingTypes.generate_private_link_token(mt)

    {:ok, view, _html} = live(conn, ~p"/b/#{token}?timezone=#{timezone}")

    # The schedule step should be shown (not overview for private booking)
    # Select a date
    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target_date = Date.add(today, 1)
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

    attendee_email = "private-attendee@example.com"

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{
        "name" => "Private Attendee",
        "email" => attendee_email,
        "message" => "Hello from private booking!"
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
  test "visitor can book via private link even when meeting type is inactive (is_active: false)", %{conn: conn} do
    timezone = "America/New_York"
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "privatehost2",
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
        name: "Inactive Private Chat",
        is_active: false,
        is_private: true
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

    all_types = MeetingTypes.get_all_meeting_types(user.id)
    mt = Enum.find(all_types, &(&1.is_private == true))
    token = MeetingTypes.generate_private_link_token(mt)

    {:ok, view, _html} = live(conn, ~p"/b/#{token}?timezone=#{timezone}")

    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target_date = Date.add(today, 1)
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

    attendee_email = "inactive-private-attendee@example.com"

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{
        "name" => "Private Attendee",
        "email" => attendee_email,
        "message" => "Hello from private booking!"
      }
    })
    |> render_submit()

    wait_until(fn -> render(view) =~ "Meeting Confirmed!" end)

    meeting =
      Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: attendee_email)

    assert meeting.status == "confirmed"
  end

end
