defmodule TymeslotWeb.Helpers.GraphWebhook do
  @moduledoc """
  Request handling shared by the two Microsoft Graph webhook endpoints.

  Graph validates the notification URL and the lifecycle URL with the same
  synchronous handshake, and delivers to both from the same pool of Microsoft
  addresses. Keeping the handshake response and the per-address limit here
  rather than in each controller is what stops the two drifting apart: they
  already had, with one of them keying its rate limit off a different source
  and skipping the limit entirely on the delivery path.
  """

  import Plug.Conn

  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @doc """
  Runs `fun` unless the source address has exhausted the calendar push bucket.

  A refused request gets 429, which Graph retries. The bucket is sized so that
  provider traffic never reaches it; see
  `Tymeslot.Security.RateLimiter.Calendar.check_push_endpoint/1`.
  """
  @spec with_rate_limit(Plug.Conn.t(), (-> Plug.Conn.t())) :: Plug.Conn.t()
  def with_rate_limit(conn, fun) do
    case RateLimiter.check_calendar_push_rate_limit(ClientIP.get(conn)) do
      :ok -> fun.()
      {:error, :rate_limited} -> conn |> send_resp(429, "") |> halt()
    end
  end

  @doc """
  Answers Graph's subscription-validation handshake.

  The token has to come back verbatim as plain text with 200 within seconds or
  Graph rejects the subscription. A token carrying non-printable bytes is
  refused with 400 rather than echoed.
  """
  @spec answer_validation_challenge(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def answer_validation_challenge(conn, token) do
    with_rate_limit(conn, fn ->
      if String.printable?(token) do
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, token)
        |> halt()
      else
        conn |> send_resp(400, "") |> halt()
      end
    end)
  end
end
