defmodule TymeslotWeb.EndpointTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :infrastructure

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Infrastructure.CorrelationId
  alias TymeslotWeb.Endpoint

  describe "request_log_level/1" do
    test "disables request logging for token-bearing paths" do
      for path_info <- [
            ["auth", "verify-complete", "secret-token"],
            ["auth", "reset-password", "secret-token"],
            ["email-change", "secret-token"],
            ["free-busy", "abc"]
          ] do
        conn = %Plug.Conn{path_info: path_info}
        assert Endpoint.request_log_level(conn) == false
      end
    end

    test "keeps :info logging for ordinary paths" do
      for path_info <- [[], ["dashboard"], ["auth", "login"], ["email-change"]] do
        conn = %Plug.Conn{path_info: path_info}
        assert Endpoint.request_log_level(conn) == :info
      end
    end
  end

  describe "correlation ID plug" do
    test "response includes x-correlation-id header", %{conn: conn} do
      conn = get(conn, ~p"/auth/login")

      assert [id] = get_resp_header(conn, "x-correlation-id")
      # CorrelationId.generate/0 hands out a v4 UUID.
      assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
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

    test "resolves an {otp_app, file} tuple in :robots_file", %{conn: conn} do
      # Safe in an async module: the tuple points at the same file the
      # string default resolves to, so concurrent readers see no difference.
      with_config(:tymeslot, :robots_file, {:tymeslot, "robots.core.txt"})

      conn = get(conn, "/robots.txt")

      assert conn.status == 200

      assert conn.resp_body ==
               File.read!(Path.join(:code.priv_dir(:tymeslot), "static/robots.core.txt"))
    end
  end

  describe "session cookie" do
    test "response sets _tymeslot_key cookie", %{conn: conn} do
      conn = get(conn, ~p"/auth/login")

      assert %{"_tymeslot_key" => cookie} = conn.resp_cookies

      # The session cookie must stay unreadable to scripts and same-site.
      assert cookie.http_only
      assert cookie.same_site == "Lax"
      assert byte_size(cookie.value) > 0
    end
  end
end
