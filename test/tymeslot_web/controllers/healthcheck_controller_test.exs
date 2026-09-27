defmodule TymeslotWeb.HealthcheckControllerTest do
  # async: false: the rate-limit test clears the shared Hammer table, and the
  # degraded and unhealthy tests replace `Oban` and `HealthQueries` globally
  # with :meck.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :infrastructure
  @moduletag :controllers

  import ExUnit.CaptureLog

  alias Tymeslot.Infrastructure.HealthQueries
  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    :ok
  end

  defp with_mock(module, fun, impl, body) do
    :meck.new(module, [:passthrough])
    :meck.expect(module, fun, impl)

    try do
      body.()
    after
      :meck.unload(module)
    end
  end

  describe "GET /healthcheck" do
    test "returns status ok with healthy checks", %{conn: conn} do
      conn = get(conn, ~p"/healthcheck")
      body = json_response(conn, 200)

      assert body["status"] == "ok"

      # The timestamp must be a parseable ISO8601 instant
      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(body["timestamp"])

      # Verify checks are included
      assert body["checks"]["database"] == "ok"
      assert body["checks"]["oban"] == "ok"
    end

    test "returns 200 degraded when a job queue is paused", %{conn: conn} do
      # A paused queue is an operator's deliberate act and restarting the
      # container would not unpause it, so the orchestrator must keep the
      # instance up: 200, with the paused check named in the body.
      body =
        with_mock(Oban, :check_all_queues, fn -> [%{queue: "default", paused: true}] end, fn ->
          conn |> get(~p"/healthcheck") |> json_response(200)
        end)

      assert body["status"] == "degraded"
      assert body["checks"] == %{"database" => "ok", "oban" => "paused"}
    end

    test "returns 503 unhealthy when the database is unreachable", %{conn: conn} do
      body =
        with_mock(HealthQueries, :ping, fn -> {:error, :timeout} end, fn ->
          conn |> get(~p"/healthcheck") |> json_response(503)
        end)

      assert body["status"] == "unhealthy"
      assert body["checks"] == %{"database" => "unavailable", "oban" => "ok"}
    end

    test "returns 503 unhealthy when the Oban probe raises", %{conn: conn} do
      {body, _log} =
        with_log(fn ->
          with_mock(Oban, :check_all_queues, fn -> raise RuntimeError, "no oban" end, fn ->
            conn |> get(~p"/healthcheck") |> json_response(503)
          end)
        end)

      assert body["status"] == "unhealthy"
      assert body["checks"] == %{"database" => "ok", "oban" => "unavailable"}
    end

    test "is rate limited", %{conn: conn} do
      # Make 30 requests to reach the limit
      # The limit is 30 per 60s
      for _i <- 1..30 do
        get(conn, ~p"/healthcheck")
      end

      # 31st request should be denied
      conn = get(conn, ~p"/healthcheck")
      assert get_resp_header(conn, "retry-after") == ["60"]

      assert json_response(conn, 429) == %{
               "error" => "Too many requests",
               "message" => "Rate limit exceeded for healthcheck endpoint",
               "retry_after" => 60
             }
    end
  end
end
