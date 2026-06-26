defmodule TymeslotWeb.FreebusyController do
  @moduledoc """
  Serves a profile's public free/busy feed as iCalendar `VFREEBUSY`.

  The route is unauthenticated — access is gated solely by the unguessable
  per-profile token in the URL. Responses are rate-limited per client IP. An
  unknown or disabled token returns 404 so the endpoint reveals nothing about
  which tokens exist.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.FreeBusy
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @rate_window_ms 60_000
  @rate_limit 60

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"token" => token}) do
    bucket_key = "freebusy:#{ClientIP.get(conn)}"

    case RateLimiter.check_rate(bucket_key, @rate_window_ms, @rate_limit) do
      {:allow, _count} -> serve(conn, token)
      {:deny, _limit} -> conn |> put_resp_content_type("text/plain") |> send_resp(429, "")
    end
  end

  defp serve(conn, token) do
    case FreeBusy.get_profile_by_token(token) do
      {:ok, profile} ->
        conn
        |> put_resp_content_type("text/calendar")
        |> send_resp(200, FreeBusy.feed(profile))

      {:error, :not_found} ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "")
    end
  end
end
