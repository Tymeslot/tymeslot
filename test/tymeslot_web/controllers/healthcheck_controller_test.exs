defmodule TymeslotWeb.HealthcheckControllerTest do
  # async: false: the rate-limit test clears the shared Hammer table, and the
  # unhealthy test replaces `Oban` globally with :meck.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :infrastructure
  @moduletag :controllers

  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    :ok
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

    test "returns 503 unhealthy when the job queues are paused", %{conn: conn} do
      # Every check is essential: a paused Oban queue means bookings stop
      # sending mail and syncing calendars, so the orchestrator must see a
      # failing probe rather than a 200.
      :meck.new(Oban, [:passthrough])
      :meck.expect(Oban, :check_all_queues, fn -> [%{queue: "default", paused: true}] end)

      body =
        try do
          conn |> get(~p"/healthcheck") |> json_response(503)
        after
          :meck.unload(Oban)
        end

      assert body["status"] == "unhealthy"
      assert body["checks"] == %{"database" => "ok", "oban" => "paused"}
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
