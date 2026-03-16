defmodule TymeslotWeb.HealthcheckController do
  use TymeslotWeb, :controller

  require Logger
  alias Ecto.Adapters.SQL
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @db_check_timeout 5_000

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    # Rate limit healthcheck endpoint - 30 requests per minute per IP
    client_ip = ClientIP.get(conn)
    bucket_key = "healthcheck:#{client_ip}"

    case RateLimiter.check_rate(bucket_key, 60_000, 30) do
      {:allow, _count} ->
        checks = run_checks()

        {status, http_status} =
          cond do
            not essentials_healthy?(checks) -> {"unhealthy", 503}
            not all_healthy?(checks) -> {"degraded", 200}
            true -> {"ok", 200}
          end

        conn
        |> put_resp_content_type("application/json")
        |> put_status(http_status)
        |> json(%{status: status, timestamp: DateTime.utc_now(), checks: checks})

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

  defp run_checks do
    %{
      database: check_database(),
      oban: check_oban()
    }
  end

  defp check_database do
    case SQL.query(Tymeslot.Repo, "SELECT 1", [], timeout: @db_check_timeout) do
      {:ok, _result} -> "ok"
      {:error, _reason} -> "unavailable"
    end
  rescue
    _db_error -> "unavailable"
  end

  defp check_oban do
    case Oban.check_queue(queue: :default) do
      %{paused: false} -> "ok"
      %{paused: true} -> "paused"
      _not_running -> "unavailable"
    end
  rescue
    _oban_error -> "unavailable"
  end

  @essential_checks [:database, :oban]

  defp essentials_healthy?(checks) do
    @essential_checks
    |> Enum.all?(fn name -> checks[name] == "ok" end)
  end

  defp all_healthy?(checks) do
    Enum.all?(checks, fn {_name, status} -> status == "ok" end)
  end
end
