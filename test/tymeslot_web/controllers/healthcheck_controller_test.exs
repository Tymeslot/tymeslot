defmodule TymeslotWeb.HealthcheckControllerTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils

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
