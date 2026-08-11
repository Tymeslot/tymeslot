defmodule TymeslotWeb.PrivateBookingTest do
  @moduledoc """
  End-to-end coverage for private/direct booking links: booking a private type
  through its direct `/:username/:slug` link, the private type being hidden from
  the public overview, and the back-to-overview control being suppressed on
  direct entry.
  """
  use TymeslotWeb.LiveCase, async: false
  @moduletag :scheduling

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

  @timezone "America/New_York"

  @tag :capture_log
  test "visitor books a private meeting type through its direct link", %{conn: conn} do
    %{user: user, profile: profile} = bookable_host("privatehost")

    insert(:meeting_type,
      user: user,
      duration_minutes: 30,
      name: "Investor Call",
      is_active: true,
      is_private: true
    )

    {:ok, view, _html} =
      live(conn, ~p"/#{profile.username}/investor-call?timezone=#{@timezone}")

    # Direct entry: the booker cannot navigate back to the organiser's other types.
    refute has_element?(view, "[data-testid='back-step']")

    attendee_email = "investor@example.com"
    book_selected_slot(view, attendee_email)

    wait_until(fn -> render(view) =~ "Meeting Confirmed!" end)

    meeting =
      Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: attendee_email)

    assert meeting.status == "confirmed"
    assert meeting.meeting_type_id
  end

  @tag :capture_log
  test "private type is hidden from the public overview but reachable by its link", %{conn: conn} do
    %{user: user, profile: profile} = bookable_host("mixedhost")

    insert(:meeting_type, user: user, name: "Public Chat", is_active: true, is_private: false)
    insert(:meeting_type, user: user, name: "Secret Chat", is_active: true, is_private: true)

    {:ok, overview, overview_html} = live(conn, ~p"/#{profile.username}?timezone=#{@timezone}")

    assert overview_html =~ "Public Chat"
    refute overview_html =~ "Secret Chat"
    refute has_element?(overview, "button[phx-value-duration='secret-chat']")

    # The hidden type still resolves through its direct link: the direct entry
    # lands on the schedule step (calendar present), not redirected to overview.
    {:ok, direct, _html} =
      live(conn, ~p"/#{profile.username}/secret-chat?timezone=#{@timezone}")

    assert has_element?(direct, "button[phx-click='next_month']")
    refute has_element?(direct, "button[phx-value-duration='secret-chat']")
  end

  @tag :capture_log
  test "back-to-overview shows when browsing in, hidden on direct slug entry", %{conn: conn} do
    %{profile: profile} = bookable_host("backhost", with_type: "Open Chat")

    # Direct entry at the slug: no back control.
    {:ok, direct, _html} = live(conn, ~p"/#{profile.username}/open-chat?timezone=#{@timezone}")
    refute has_element?(direct, "[data-testid='back-step']")

    # Browsing in from the overview: back control is present on the schedule step.
    {:ok, overview, _html} = live(conn, ~p"/#{profile.username}?timezone=#{@timezone}")

    overview
    |> element("button[phx-value-duration='open-chat']")
    |> render_click()

    overview
    |> element("button[phx-click='next_step']")
    |> render_click()

    assert has_element?(overview, "[data-testid='back-step']")
  end

  # --- helpers -------------------------------------------------------------

  defp bookable_host(username, opts \\ []) do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: username,
        booking_theme: "1",
        timezone: @timezone
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
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

    if name = opts[:with_type] do
      insert(:meeting_type, user: user, name: name, is_active: true, duration_minutes: 30)
    end

    %{user: user, profile: profile}
  end

  # Drives the schedule step from a selected slug entry through to submission.
  defp book_selected_slot(view, attendee_email) do
    today = @timezone |> DateTime.now!() |> DateTime.to_date()
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

  defp maybe_advance_calendar_to_month(view, today, target_date) do
    if {target_date.year, target_date.month} != {today.year, today.month} do
      view
      |> element("button[phx-click='next_month']")
      |> render_click()
    end

    target_date
  end
end
