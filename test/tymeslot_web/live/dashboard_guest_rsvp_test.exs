defmodule TymeslotWeb.DashboardGuestRsvpTest do
  @moduledoc """
  A guest answering their invitation reaches the organiser's open calendar
  page: the domain broadcasts after writing the RSVP, and the dashboard is
  subscribed to the same topic.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :meetings
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Guests

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    _integration = insert(:calendar_integration, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  test "the calendar page receives a guest's RSVP", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user: user)
    {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    :erlang.trace(lv.pid, true, [:receive])

    {:ok, _guest} = Meetings.record_guest_rsvp(guest.rsvp_token, "accepted")

    meeting_id = meeting.id
    assert_receive {:trace, _pid, :receive, {:guest_rsvp_updated, ^meeting_id}}
    # The refresh it triggers leaves the grid standing.
    assert has_element?(lv, "#calendar-grid")
  end
end
