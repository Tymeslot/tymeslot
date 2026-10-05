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

  A seat on a group meeting is downloaded under its management token
  instead (`seat/2`): the file is the participant's own calendar entry, the
  one their emails invite them to, and a token naming no live seat is a 404.
  The group meeting's own uid exports nothing.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.Meetings
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"username" => username, "meeting_uid" => uid}) do
    case RateLimiter.check_meeting_calendar_feed_rate_limit(ClientIP.get(conn)) do
      :ok -> serve(conn, username, uid)
      {:error, :rate_limited} -> send_status(conn, 429)
    end
  end

  @spec seat(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def seat(conn, %{"token" => token}) do
    case RateLimiter.check_meeting_calendar_feed_rate_limit(ClientIP.get(conn)) do
      :ok -> serve_seat(conn, token)
      {:error, :rate_limited} -> send_status(conn, 429)
    end
  end

  defp serve_seat(conn, token) do
    case Meetings.seat_calendar_export(token) do
      {:ok, ics} -> send_ics(conn, ics, "meeting.ics")
      {:error, :not_found} -> send_status(conn, 404)
    end
  end

  defp serve(conn, username, uid) do
    with %{user_id: organizer_user_id} <- Profiles.get_profile_by_username(username),
         {:ok, ics} <- Meetings.calendar_export(uid, organizer_user_id) do
      send_ics(conn, ics, "meeting-#{uid}.ics")
    else
      _not_found -> send_status(conn, 404)
    end
  end

  defp send_ics(conn, ics, filename) do
    conn
    |> put_resp_content_type("text/calendar")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, ics)
  end

  defp send_status(conn, status) do
    conn |> put_resp_content_type("text/plain") |> send_resp(status, "")
  end
end
