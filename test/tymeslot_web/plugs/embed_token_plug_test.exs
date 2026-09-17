defmodule TymeslotWeb.Plugs.EmbedTokenPlugTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs
  @moduletag :security

  alias Plug.Session
  alias Tymeslot.Embed.Token
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Plugs.EmbedTokenPlug

  @session_key "_tymeslot_key"
  @session_opts Session.init(
                  store: :cookie,
                  key: @session_key,
                  signing_salt: "embed_token_plug_test",
                  same_site: "Lax"
                )

  describe "call/2" do
    test "assigns embed_token when ?embed=1 and valid username in path", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1")
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, {"sarah", nil}} = Token.verify(conn.assigns.embed_token)
    end

    test "writes no session cookie for embed requests", %{conn: conn} do
      # The browser would reject one anyway (SameSite=Lax in a cross-site
      # iframe), and embedded pages authenticate with the embed token instead.
      response =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1")
        |> run_session_pipeline()

      refute Map.has_key?(response.resp_cookies, @session_key)
    end

    test "an embed request leaves the caller's existing session intact", %{conn: conn} do
      # Regression for issue #96. `configure_session(drop: true)` reads like
      # "write nothing" but means "delete what the caller sent". The live
      # preview's iframe is same-origin with the dashboard, so the organiser's
      # cookie rode along with the request and came back deleted site-wide;
      # their next navigation bounced to the login page.
      session_cookie = establish_session(conn)

      response =
        conn
        |> put_req_cookie(@session_key, session_cookie)
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1")
        |> run_session_pipeline()

      # A deletion would appear here as `_tymeslot_key=` with a 1970 expiry.
      refute Map.has_key?(response.resp_cookies, @session_key)

      # And the cookie still resolves to the same logged-in session afterwards.
      assert replay_session(conn, session_cookie) == "a-real-session-token"
    end

    test "preserves session for non-embed requests", %{conn: conn} do
      session_cookie = establish_session(conn)

      response =
        conn
        |> put_req_cookie(@session_key, session_cookie)
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "")
        |> run_session_pipeline()

      refute Map.has_key?(response.resp_cookies, @session_key)
      assert replay_session(conn, session_cookie) == "a-real-session-token"
    end

    test "uses Referer header as parent_origin when present", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1")
        |> put_req_header("referer", "https://mysite.com/page")
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, {"sarah", "https://mysite.com"}} = Token.verify(conn.assigns.embed_token)
    end

    test "Referer header takes precedence over parent-origin query param", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1&parent-origin=https://spoofed.com")
        |> put_req_header("referer", "https://real-site.com/embed-page")
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, {"sarah", "https://real-site.com"}} = Token.verify(conn.assigns.embed_token)
    end

    test "falls back to parent-origin param when Referer is absent", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1&parent-origin=https://mysite.com")
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, {"sarah", "https://mysite.com"}} = Token.verify(conn.assigns.embed_token)
    end

    test "assigns embed_token for nested username paths", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah/30-min-meeting")
        |> Map.put(:query_string, "embed=1")
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, {"sarah", nil}} = Token.verify(conn.assigns.embed_token)
    end

    test "does not assign embed_token when embed param is absent", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "")
        |> EmbedTokenPlug.call([])

      refute conn.assigns[:embed_token]
    end

    test "does not assign embed_token for reserved paths", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/dashboard")
        |> Map.put(:query_string, "embed=1")
        |> EmbedTokenPlug.call([])

      refute conn.assigns[:embed_token]
    end

    test "does not assign embed_token when embed param is 0", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=0")
        |> EmbedTokenPlug.call([])

      refute conn.assigns[:embed_token]
    end

    test "does not assign embed_token when embed param is true (only '1' triggers)", %{
      conn: conn
    } do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=true")
        |> EmbedTokenPlug.call([])

      refute conn.assigns[:embed_token]
    end

    test "does not assign embed_token when embed param is yes", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=yes")
        |> EmbedTokenPlug.call([])

      refute conn.assigns[:embed_token]
    end

    test "handles extra query params alongside embed=1", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "theme=2&embed=1&locale=de")
        |> put_req_header("referer", "https://example.com/page")
        |> EmbedTokenPlug.call([])

      assert conn.assigns[:embed_token]
      assert {:ok, {"sarah", "https://example.com"}} = Token.verify(conn.assigns.embed_token)
    end
  end

  # The `:drop` vs `:ignore` difference only materialises in Plug.Session's
  # before_send callback, so these run the request through the real session
  # plug and assert on the response cookies rather than on conn internals.

  defp run_session_pipeline(conn) do
    conn
    |> start_session()
    |> EmbedTokenPlug.call([])
    |> send_resp(200, "ok")
  end

  # A logged-in caller's cookie, minted the way logging in mints one.
  defp establish_session(conn) do
    conn
    |> start_session()
    |> put_session(:user_token, "a-real-session-token")
    |> send_resp(200, "ok")
    |> Map.fetch!(:resp_cookies)
    |> Map.fetch!(@session_key)
    |> Map.fetch!(:value)
  end

  defp replay_session(conn, session_cookie) do
    conn
    |> put_req_cookie(@session_key, session_cookie)
    |> start_session()
    |> get_session(:user_token)
  end

  defp start_session(conn) do
    conn
    |> put_private(:phoenix_endpoint, Endpoint)
    |> Map.put(:secret_key_base, Endpoint.config(:secret_key_base))
    |> Session.call(@session_opts)
    |> fetch_session()
  end
end
