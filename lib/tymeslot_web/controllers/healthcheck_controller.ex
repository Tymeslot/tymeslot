defmodule TymeslotWeb.HealthcheckController do
  @moduledoc """
  Serves `GET /healthcheck`, the probe container orchestrators poll.

  Answers 200 with `"status": "ok"` when every check in
  `Tymeslot.Infrastructure.Health` passes, and 503 with
  `"status": "unhealthy"` otherwise; the per-check results are in `checks`.
  Rate-limited per client IP.
  """

  use TymeslotWeb, :controller

  require Logger

  alias Tymeslot.Infrastructure.Health
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @retry_after_seconds 60

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    case RateLimiter.check_healthcheck_rate_limit(ClientIP.get(conn)) do
      :ok ->
        %{status: status, checks: checks} = Health.check()

        conn
        |> put_status(if status == :ok, do: 200, else: 503)
        |> json(%{status: status, timestamp: DateTime.utc_now(), checks: checks})

      {:error, :rate_limited} ->
        Logger.warning("Health check rate limit exceeded")

        conn
        |> put_status(429)
        |> put_resp_header("retry-after", to_string(@retry_after_seconds))
        |> json(%{
          error: "Too many requests",
          message: "Rate limit exceeded for healthcheck endpoint",
          retry_after: @retry_after_seconds
        })
    end
  end
end
