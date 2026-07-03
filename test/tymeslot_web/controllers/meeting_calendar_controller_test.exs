defmodule TymeslotWeb.MeetingCalendarControllerTest do
  @moduledoc """
  Covers the public per-meeting `.ics` download served from the booking
  confirmation screen: the happy-path attachment, the IDOR guard (a UID only
  resolves under its own organiser's username), and unknown-resource 404s.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :controllers
  @moduletag :meetings

  import Tymeslot.Factory

  alias Ecto.UUID

  defp confirmed_meeting(attrs) do
    start_time = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
    end_time = DateTime.add(start_time, 3600)

    insert(
      :meeting,
      Keyword.merge(
        [status: "confirmed", start_time: start_time, end_time: end_time],
        attrs
      )
    )
  end

  describe "GET /:username/meeting/:meeting_uid/calendar.ics" do
    test "returns a downloadable iCalendar for the organiser's own meeting", %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "hostname")
      meeting = confirmed_meeting(organizer_user: user, title: "Strategy Session")

      conn = get(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/calendar.ics")

      assert conn.status == 200
      assert conn |> get_resp_header("content-type") |> List.first() =~ "text/calendar"

      assert conn |> get_resp_header("content-disposition") |> List.first() =~
               ~s(attachment; filename="meeting-#{meeting.uid}.ics")

      assert conn.resp_body =~ "BEGIN:VCALENDAR"
      assert conn.resp_body =~ "BEGIN:VEVENT"
      assert conn.resp_body =~ "SUMMARY"
      assert conn.resp_body =~ "Strategy Session"
      assert conn.resp_body =~ "UID:#{meeting.uid}@"
    end

    test "404s when the meeting belongs to a different organiser (IDOR guard)", %{conn: conn} do
      attacker = insert(:user)
      attacker_profile = insert(:profile, user: attacker, username: "attacker")

      victim = insert(:user)
      victim_meeting = confirmed_meeting(organizer_user: victim)

      conn =
        get(conn, ~p"/#{attacker_profile.username}/meeting/#{victim_meeting.uid}/calendar.ics")

      assert conn.status == 404
    end

    test "404s for an unknown meeting UID under a real username", %{conn: conn} do
      profile = insert(:profile, user: insert(:user), username: "realhost")

      conn = get(conn, ~p"/#{profile.username}/meeting/#{UUID.generate()}/calendar.ics")

      assert conn.status == 404
    end

    test "404s for an unknown username", %{conn: conn} do
      meeting = confirmed_meeting(organizer_user: insert(:user))

      conn = get(conn, ~p"/nobody/meeting/#{meeting.uid}/calendar.ics")

      assert conn.status == 404
    end
  end
end
