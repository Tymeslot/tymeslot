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

    {:ok, _view, html} = live(conn, ~p"/dashboard")

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

    {:ok, _view, html} = live(conn, ~p"/dashboard")

    # The earliest is the cockpit's "next"; the later one fills the Tomorrow peek.
    assert html =~ "Tomorrow"
    assert html =~ "Team retro"
    assert html =~ "Roadmap review"
  end

  test "shows the empty state and connect-a-calendar nudge when nothing is scheduled",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Nothing on your plate today or tomorrow"
    assert html =~ "Connect a calendar to see your whole schedule here"
  end
end
