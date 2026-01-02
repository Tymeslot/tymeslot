defmodule TymeslotWeb.HealthcheckController do
  use TymeslotWeb, :controller

  require Logger
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    # Rate limit healthcheck endpoint - 30 requests per minute per IP
    client_ip = ClientIP.get(conn)
    bucket_key = "healthcheck:#{client_ip}"

    case RateLimiter.check_rate(bucket_key, 60_000, 30) do
      {:allow, _count} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_status(200)
        |> json(%{status: "ok", timestamp: DateTime.utc_now()})

      {:deny, _limit} ->
        Logger.warning("Health check rate limit exceeded")

        conn
        |> put_resp_content_type("application/json")
        |> put_status(429)
        |> put_resp_header("retry-after", "60")
        |> json(%{
          error: "Too many requests",
          message: "Rate limit exceeded for healthcheck endpoint",
          retry_after: 60
        })
    end
  end
end
