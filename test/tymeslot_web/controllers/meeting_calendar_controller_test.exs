defmodule TymeslotWeb.MeetingCalendarControllerTest do
  @moduledoc """
  Covers the public per-meeting `.ics` download served from the booking
  confirmation screen: the happy-path attachment, the IDOR guard (a UID only
  resolves under its own organiser's username), unknown-resource 404s,
  cancelled-meeting 404s, `.ics` body content correctness, and the per-IP
  rate limit.
  """
  # async: false — the rate-limit test relies on the shared Hammer ETS
  # bucket, which other async tests clear via RateLimiter's test-only reset.
  # Matches the convention of the other rate-limited controller tests
  # (freebusy, session, guest_rsvp).
  use TymeslotWeb.ConnCase, async: false

  @moduletag :controllers
  @moduletag :meetings

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Security.RateLimiter

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

    test "404s for a cancelled meeting so a stale public link can't confirm a booking existed",
         %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "cancelledhost")
      meeting = confirmed_meeting(organizer_user: user, status: "cancelled")

      conn = get(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/calendar.ics")

      assert conn.status == 404
    end

    test "404s for a confirmed meeting with a pending reschedule request, since the slot is void",
         %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "pendingreschedulehost")

      meeting =
        confirmed_meeting(
          organizer_user: user,
          reschedule_requested_at: DateTime.utc_now(:second)
        )

      conn = get(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/calendar.ics")

      assert conn.status == 404
    end

    test "404s for an awaiting-payment meeting that never became a real booking", %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "unpaidhost")
      meeting = confirmed_meeting(organizer_user: user, status: "awaiting_payment")

      conn = get(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/calendar.ics")

      assert conn.status == 404
    end

    test "still exports a pending meeting, matching the active-booking definition used elsewhere",
         %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "pendinghost")
      meeting = confirmed_meeting(organizer_user: user, status: "pending")

      conn = get(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/calendar.ics")

      assert conn.status == 200
      assert conn.resp_body =~ "BEGIN:VEVENT"
    end

    test "attendee_video_url takes precedence over the generic meeting_url, and description plus custom answers reach the .ics body",
         %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "detailhost")

      meeting =
        confirmed_meeting(
          organizer_user: user,
          attendee_message: nil,
          attendee_video_url: "https://video.tymeslot.test/room-xyz789",
          meeting_url: "https://organizer-calendar.example.com/generic-link",
          description: "Bring your laptop and the signed contract.",
          custom_fields_snapshot: [
            %{"id" => "f1", "type" => "short_text", "label" => "Company name"}
          ],
          custom_field_answers: %{"f1" => "Acme Corp"}
        )

      conn = get(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/calendar.ics")

      assert conn.status == 200

      # Unfold RFC 5545 line-continuations (CRLF + single space) so
      # assertions don't depend on where a long property value happens to
      # wrap.
      body = String.replace(conn.resp_body, "\r\n ", "")

      assert body =~ "https://video.tymeslot.test/room-xyz789"
      refute body =~ "https://organizer-calendar.example.com/generic-link"
      assert body =~ "Bring your laptop and the signed contract."
      assert body =~ "Company name: Acme Corp"
    end

    test "returns 429 when the per-IP rate limit is exceeded", %{conn: conn} do
      # Pin a dedicated remote IP so the bucket is isolated from the other
      # tests in this file (which use the default 127.0.0.1). `Plug.RemoteIp`
      # leaves an explicitly-set `remote_ip` untouched when no trusted
      # forwarded headers are present, so `ClientIP.get/1` resolves to exactly
      # this address — matching the bucket we pre-fill here.
      rate_limit_ip = {203, 0, 113, 9}
      bucket_key = "meeting_ics:203.0.113.9"
      for _i <- 1..60, do: RateLimiter.check_rate(bucket_key, 60_000, 60)

      profile = insert(:profile, user: insert(:user), username: "throttledhost")

      conn =
        get(
          %{conn | remote_ip: rate_limit_ip},
          ~p"/#{profile.username}/meeting/#{UUID.generate()}/calendar.ics"
        )

      assert response(conn, 429)
    end
  end
end
