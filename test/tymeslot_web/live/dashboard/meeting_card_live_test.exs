defmodule TymeslotWeb.Dashboard.MeetingCardLiveTest do
  @moduledoc """
  Covers what a booking card on the Meetings page tells the organiser: which
  meeting type was booked, and a time range that reads on one line per end.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :meetings
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  test "names the meeting type on the booking card", %{conn: conn, user: user} do
    insert(:meeting,
      organizer_user: user,
      organizer_email: user.email,
      attendee_name: "John Doe",
      meeting_type: "Discovery call"
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    assert has_element?(view, ~s([data-testid="meeting-type"]), "Discovery call")
  end

  test "keeps each end of the booking's time range on one line", %{conn: conn, user: user} do
    start = DateTime.new!(Date.add(Date.utc_today(), 3), ~T[11:00:00], "Etc/UTC")

    insert(:meeting,
      organizer_user: user,
      organizer_email: user.email,
      start_time: start,
      end_time: DateTime.add(start, 15 * 60, :second)
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    # Non-breaking spaces inside each time and before the dash: the card used
    # to wrap as "11:00 AM - 11:15 / AM".
    assert render(view) =~ "11:00\u00A0AM\u00A0– 11:15\u00A0AM"
  end
end
