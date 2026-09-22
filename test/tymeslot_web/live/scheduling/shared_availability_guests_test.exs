defmodule TymeslotWeb.Live.Scheduling.SharedAvailabilityGuestsTest do
  @moduledoc """
  The booking page side of `?with=`: the overview names the other users, only
  meeting types that allow guests are offered, and a link naming someone who
  cannot take part shows an error instead of the flow.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :scheduling

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Meetings.Guests

  setup do
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user, _start, _stop ->
      {:ok, []}
    end)

    host = insert(:user)
    insert(:profile, user: host, username: "marco")
    insert(:calendar_integration, user: host)
    insert(:meeting_type, user: host, name: "Team call", allow_guests: true)
    insert(:meeting_type, user: host, name: "Solo call", allow_guests: false)

    michael = insert(:user, name: "Michael Example")
    insert(:profile, user: michael, username: "michael", full_name: "Michael Example")
    insert(:calendar_integration, user: michael)
    insert(:meeting_type, user: michael)

    %{host: host, michael: michael}
  end

  test "names the other participants and offers only meeting types with guests", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/marco?with=michael")

    assert html =~ "Additional participants: Michael Example"
    assert html =~ "Team call"
    refute html =~ "Solo call"
  end

  test "shows an error for a participant who cannot be booked", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/marco?with=michael,nobody")

    # Shown on the booking page itself, not the generic error screen.
    assert html =~ "This booking link can’t be used"
    assert html =~ "One of the participants named in this link"
    refute html =~ "Theme Error"
    refute html =~ "Team call"
  end

  test "a reschedule names the guests who are Tymeslot users", %{
    conn: conn,
    host: host,
    michael: michael
  } do
    meeting =
      insert(:meeting,
        organizer_user_id: host.id,
        start_time: DateTime.add(DateTime.utc_now(), 3, :day),
        end_time: DateTime.add(DateTime.utc_now(), 3 * 86_400 + 1_800, :second)
      )

    {:ok, _guests} = Guests.create_for_meeting(meeting.id, [michael.email])

    {:ok, _view, html} = live(conn, "/marco?reschedule_meeting_uid=#{meeting.uid}")

    assert html =~ "Additional participants: Michael Example"
  end

  test "leaves the plain booking link unchanged", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/marco")

    refute html =~ "Additional participants"
    assert html =~ "Team call"
    assert html =~ "Solo call"
  end
end
