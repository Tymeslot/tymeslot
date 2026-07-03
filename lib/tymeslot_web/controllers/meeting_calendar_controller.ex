defmodule TymeslotWeb.MeetingCalendarController do
  @moduledoc """
  Serves a single booked meeting as a downloadable iCalendar (`.ics`) file so
  attendees can add the appointment to their own calendar straight from the
  booking confirmation screen.

  Access is scoped by the organiser's `:username` combined with the unguessable
  meeting `:uid` — the same IDOR-safe lookup the cancel/reschedule routes use.
  An unknown username or a UID that doesn't belong to that organiser returns
  404 so the endpoint reveals nothing about which meetings exist. Responses are
  rate-limited per client IP.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.Integrations.Calendar.IcsGenerator
  alias Tymeslot.Meetings
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @rate_window_ms 60_000
  @rate_limit 60

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"username" => username, "meeting_uid" => uid}) do
    bucket_key = "meeting_ics:#{ClientIP.get(conn)}"

    case RateLimiter.check_rate(bucket_key, @rate_window_ms, @rate_limit) do
      {:allow, _count} -> serve(conn, username, uid)
      {:deny, _limit} -> send_status(conn, 429)
    end
  end

  defp serve(conn, username, uid) do
    with %{user_id: organizer_user_id} <- Profiles.get_profile_by_username(username),
         {:ok, meeting} <- Meetings.get_meeting_by_uid_for_organizer(uid, organizer_user_id) do
      ics = IcsGenerator.generate_ics(calendar_details(meeting), meeting.attendee_locale)

      conn
      |> put_resp_content_type("text/calendar")
      |> put_resp_header("content-disposition", ~s(attachment; filename="meeting-#{uid}.ics"))
      |> send_resp(200, ics)
    else
      _not_found -> send_status(conn, 404)
    end
  end

  # The attendee is downloading their own event, so prefer their personal join
  # link over the generic meeting URL — matching the `.ics` they received by
  # email.
  defp calendar_details(meeting) do
    %{meeting | meeting_url: meeting.attendee_video_url || meeting.meeting_url}
  end

  defp send_status(conn, status) do
    conn |> put_resp_content_type("text/plain") |> send_resp(status, "")
  end
end
