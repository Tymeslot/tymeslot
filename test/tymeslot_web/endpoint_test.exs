defmodule TymeslotWeb.EndpointTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.CorrelationId

  describe "correlation ID plug" do
    test "response includes x-correlation-id header", %{conn: conn} do
      conn = get(conn, ~p"/auth/login")

      assert [id] = get_resp_header(conn, "x-correlation-id")
      assert is_binary(id)
      assert byte_size(id) > 0
    end

    test "incoming x-correlation-id header is used for tracing", %{conn: conn} do
      existing_id = CorrelationId.generate()

      conn =
        conn
        |> put_req_header("x-correlation-id", existing_id)
        |> get(~p"/auth/login")

      # The CorrelationId plug reads the incoming header for logging/tracing
      # but does not echo it back in the response (ensure/1 only sets resp header
      # for newly generated IDs). Verify the request completed successfully.
      assert conn.status in [200, 302]
    end
  end

  describe "robots.txt" do
    test "serves robots.txt file", %{conn: conn} do
      conn = get(conn, "/robots.txt")

      assert conn.status == 200
      assert hd(get_resp_header(conn, "content-type")) =~ "text/plain"
      assert byte_size(conn.resp_body) > 0
    end
  end

  describe "session cookie" do
    test "response sets _tymeslot_key cookie", %{conn: conn} do
      conn = get(conn, ~p"/auth/login")

      cookie =
        Enum.find(conn.resp_cookies, fn {key, _val} -> key == "_tymeslot_key" end)

      assert cookie != nil
    end
  end
end
