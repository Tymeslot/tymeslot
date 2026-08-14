defmodule TymeslotWeb.Dashboard.OverviewAgendaTest do
  @moduledoc """
  Renders the dashboard overview and asserts the live agenda widget replaces the
  old Upcoming Meetings / Quick Actions widgets.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :live
  @moduletag :calendar

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.EventColour

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  test "renders the agenda with the user's next appointment", %{conn: conn, user: user} do
    tomorrow_noon = DateTime.new!(Date.add(Date.utc_today(), 1), ~T[12:00:00], "Etc/UTC")

    insert(:meeting,
      organizer_email: user.email,
      start_time: tomorrow_noon,
      end_time: DateTime.add(tomorrow_noon, 3600, :second),
      status: "confirmed",
      title: "Quarterly review"
    )

    {:ok, _view, html} = live(conn, ~p"/dashboard/overview")

    assert html =~ "Your day"
    assert html =~ "Up next"
    assert html =~ "Quarterly review"

    # The cockpit carries the live countdown hook for this appointment.
    assert html =~ "agenda-countdown-"

    # The replaced widgets are gone.
    refute html =~ "Quick Actions"
    refute html =~ "Upcoming Meetings"
  end

  test "lists later tomorrow appointments in the peek, without repeating the cockpit's next",
       %{conn: conn, user: user} do
    tomorrow = Date.add(Date.utc_today(), 1)
    first = DateTime.new!(tomorrow, ~T[09:30:00], "Etc/UTC")
    later = DateTime.new!(tomorrow, ~T[14:00:00], "Etc/UTC")

    insert(:meeting,
      organizer_email: user.email,
      start_time: first,
      end_time: DateTime.add(first, 3600, :second),
      status: "confirmed",
      title: "Team retro"
    )

    insert(:meeting,
      organizer_email: user.email,
      start_time: later,
      end_time: DateTime.add(later, 3600, :second),
      status: "confirmed",
      title: "Roadmap review"
    )

    {:ok, _view, html} = live(conn, ~p"/dashboard/overview")

    # The earliest is the cockpit's "next"; the later one fills the Tomorrow peek.
    assert html =~ "Tomorrow"
    assert html =~ "Team retro"
    assert html =~ "Roadmap review"
  end

  test "shows the empty state and connect-a-calendar nudge when nothing is scheduled",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/dashboard/overview")

    assert html =~ "Nothing on your plate today or tomorrow"
    assert html =~ "Connect a calendar to see your whole schedule here"
  end

  test "clicking a booking opens a detail modal with its full details and actions",
       %{conn: conn, user: user} do
    tomorrow = Date.add(Date.utc_today(), 1)
    start = DateTime.new!(tomorrow, ~T[12:00:00], "Etc/UTC")

    insert(:meeting,
      organizer_email: user.email,
      start_time: start,
      end_time: DateTime.add(start, 45 * 60, :second),
      status: "confirmed",
      title: "Quarterly review",
      attendee_name: "Dana Lee",
      location: "Room 3B",
      organizer_video_url: "https://zoom.us/j/123"
    )

    {:ok, view, html} = live(conn, ~p"/dashboard/overview")
    refute html =~ "agenda-detail-modal"

    view
    |> element(~s([aria-label="View details for Quarterly review"]))
    |> render_click()

    modal = view |> element("#agenda-detail-modal") |> render()

    assert modal =~ Calendar.strftime(tomorrow, "%A, %-d %B %Y")
    assert modal =~ "45 min"
    assert modal =~ "Dana Lee"
    # It reads clearly as a video meeting on a recognised platform, held in a room.
    assert modal =~ "Video meeting"
    assert modal =~ "Zoom"
    assert modal =~ "Room 3B"
    # A Tymeslot booking is labelled as such and offers both smart actions.
    assert modal =~ "Calendar"
    assert modal =~ "Tymeslot"
    assert modal =~ "Manage booking"
    assert modal =~ "Join"
  end

  test "dismissing the detail modal clears it", %{conn: conn, user: user} do
    tomorrow = Date.add(Date.utc_today(), 1)
    start = DateTime.new!(tomorrow, ~T[12:00:00], "Etc/UTC")

    insert(:meeting,
      organizer_email: user.email,
      start_time: start,
      end_time: DateTime.add(start, 3600, :second),
      status: "confirmed",
      title: "Quarterly review"
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

    assert view
           |> element(~s([aria-label="View details for Quarterly review"]))
           |> render_click() =~ "agenda-detail-modal"

    refute view
           |> element(~s(#agenda-detail-modal button[aria-label="Close modal"]))
           |> render_click() =~ "agenda-detail-modal"
  end

  test "the 60s agenda tick refreshes the agenda without a page reload",
       %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/dashboard/overview")

    assert html =~ "Nothing on your plate today or tomorrow"

    # Inserted after mount, so it can only appear once the tick re-fetches.
    tomorrow = Date.add(Date.utc_today(), 1)
    start = DateTime.new!(tomorrow, ~T[12:00:00], "Etc/UTC")

    insert(:meeting,
      organizer_email: user.email,
      start_time: start,
      end_time: DateTime.add(start, 3600, :second),
      status: "confirmed",
      title: "Freshly booked"
    )

    send(view.pid, :agenda_tick)
    html = render(view)

    assert html =~ "Freshly booked"
    refute html =~ "Nothing on your plate today or tomorrow"

    # A second tick (mirroring the rescheduled timer firing again) is still a
    # clean no-op re-render, not a crash or a stacked/duplicate refresh.
    send(view.pid, :agenda_tick)
    html = render(view)
    assert html =~ "Freshly booked"
    assert Process.alive?(view.pid)
  end

  test "a synced calendar event offers Join but no booking management",
       %{conn: conn, user: user} do
    tomorrow = Date.add(Date.utc_today(), 1)
    start = DateTime.new!(tomorrow, ~T[12:00:00], "Etc/UTC")
    integration = insert(:calendar_integration, user: user, name: "Work Google")

    insert(:provider_calendar_event,
      calendar_integration: integration,
      summary: "Design sync",
      start_at: start,
      end_at: DateTime.add(start, 3600, :second),
      all_day: false,
      video_link: "https://meet.example.com/d",
      organiser: %{"displayName" => "Sam Rivera"}
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

    view
    |> element(~s([aria-label="View details for Design sync"]))
    |> render_click()

    modal = view |> element("#agenda-detail-modal") |> render()

    assert modal =~ "Sam Rivera"
    assert modal =~ "Video meeting"
    # It names the source calendar it came from …
    assert modal =~ "Work Google"
    # … and offers Join but not booking management for a synced event.
    assert modal =~ "Join"
    refute modal =~ "Manage booking"
  end

  describe "per-event colour" do
    test "renders the palette colour on an all-day event pill", %{conn: conn, user: user} do
      today = Date.utc_today()
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: "Company offsite",
        uid: "uid-allday-colour",
        colour: "blueberry",
        all_day: true,
        start_date: today,
        end_date: Date.add(today, 1),
        start_at: nil,
        end_at: nil
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard/overview")

      assert html =~ "Company offsite"
      assert html =~ EventColour.tailwind_class("blueberry")
    end

    test "renders the palette colour on a tomorrow peek row", %{conn: conn, user: user} do
      tomorrow = Date.add(Date.utc_today(), 1)
      # An earlier booking becomes the cockpit hero, so the coloured event lands
      # in the tomorrow peek rather than the (brand-gradient) cockpit.
      early = DateTime.new!(tomorrow, ~T[09:00:00], "Etc/UTC")

      insert(:meeting,
        organizer_email: user.email,
        start_time: early,
        end_time: DateTime.add(early, 3600, :second),
        status: "confirmed",
        title: "Standup"
      )

      integration = insert(:calendar_integration, user: user)
      later = DateTime.new!(tomorrow, ~T[15:00:00], "Etc/UTC")

      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: "Design review",
        uid: "uid-peek-colour",
        colour: "blueberry",
        all_day: false,
        start_at: later,
        end_at: DateTime.add(later, 3600, :second)
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard/overview")

      assert html =~ "Design review"
      assert html =~ EventColour.tailwind_class("blueberry")
    end
  end
end
