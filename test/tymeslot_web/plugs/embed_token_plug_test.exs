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

    test "a Referer from this site defers to the parent-origin param", %{conn: conn} do
      # A navigation the framed page makes itself (the language switcher's
      # redirect) arrives with the booking page as its Referer. That names
      # this site, not the embedder, and would fail the allowlist check.
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1&parent-origin=https://mysite.com")
        |> put_req_header("referer", "http://#{conn.host}/sarah?embed=1")
        |> EmbedTokenPlug.call([])

      assert {:ok, {"sarah", "https://mysite.com"}} = Token.verify(conn.assigns.embed_token)
    end

    test "a Referer from this site is kept when there is no parent-origin param",
         %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1")
        |> put_req_header("referer", "http://#{conn.host}/dashboard")
        |> EmbedTokenPlug.call([])

      expected = "http://#{conn.host}"
      assert {:ok, {"sarah", ^expected}} = Token.verify(conn.assigns.embed_token)
    end

    test "keeps a non-default port in the Referer origin", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1")
        |> put_req_header("referer", "http://embedder.test:8080/page")
        |> EmbedTokenPlug.call([])

      assert {:ok, {"sarah", "http://embedder.test:8080"}} =
               Token.verify(conn.assigns.embed_token)
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

    test "a top-level navigation (Sec-Fetch-Dest: document) is served as a normal page", %{
      conn: conn
    } do
      # The embed URL opened in its own tab connects over /live, which needs the
      # session's CSRF state; ignoring the session write left it reloading for ever.
      response =
        conn
        |> put_req_header("sec-fetch-dest", "document")
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1")
        |> run_session_pipeline(csrf_state: "fresh-csrf-state")

      refute response.assigns[:embed_token]
      assert Map.has_key?(response.resp_cookies, @session_key)
    end

    test "an iframe request (Sec-Fetch-Dest: iframe) is still embedded", %{conn: conn} do
      response =
        conn
        |> put_req_header("sec-fetch-dest", "iframe")
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1")
        |> run_session_pipeline(csrf_state: "fresh-csrf-state")

      assert {:ok, {"sarah", nil}} = Token.verify(response.assigns.embed_token)
      refute Map.has_key?(response.resp_cookies, @session_key)
    end

    test "a request without Sec-Fetch-Dest is still embedded", %{conn: conn} do
      # Browsers without Fetch Metadata send no header; a real iframe must keep working.
      response =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "embed=1")
        |> run_session_pipeline(csrf_state: "fresh-csrf-state")

      assert {:ok, {"sarah", nil}} = Token.verify(response.assigns.embed_token)
      refute Map.has_key?(response.resp_cookies, @session_key)
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

  # A copied embed URL opened in its own tab used to be treated as an embed,
  # so the CSRF state its page generated was never written back. The page
  # connects to the session socket when it is not framed, found no session
  # there and reloaded for ever. `Sec-Fetch-Dest` tells the two apart.
  describe "Sec-Fetch-Dest" do
    test "a top-level visit (document) is served as an ordinary page", %{conn: conn} do
      response = embed_request_writing_session(conn, "document")

      refute response.assigns[:embed_token]
      assert Map.has_key?(response.resp_cookies, @session_key)
    end

    test "a framed request (iframe) keeps the embed behaviour", %{conn: conn} do
      response = embed_request_writing_session(conn, "iframe")

      assert {:ok, {"sarah", nil}} = Token.verify(response.assigns.embed_token)
      refute Map.has_key?(response.resp_cookies, @session_key)
    end

    test "a request without the header keeps the embed behaviour", %{conn: conn} do
      response = embed_request_writing_session(conn, nil)

      assert {:ok, {"sarah", nil}} = Token.verify(response.assigns.embed_token)
      refute Map.has_key?(response.resp_cookies, @session_key)
    end

    test "an embed path naming no organiser keeps its session", %{conn: conn} do
      # No token means no marker, so the page would connect to the session
      # socket; it must then have its session.
      response = embed_request_writing_session(conn, nil, "/dashboard")

      refute response.assigns[:embed_token]
      assert Map.has_key?(response.resp_cookies, @session_key)
    end

    test "every embed response varies on the header", %{conn: conn} do
      # A shared cache must not hand a framed visitor the top-level response,
      # or the reverse.
      for sec_fetch_dest <- ["document", "iframe", nil] do
        response = embed_request_writing_session(conn, sec_fetch_dest)
        assert "sec-fetch-dest" in get_resp_header(response, "vary")
      end
    end

    test "a non-embed response does not vary on it", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/sarah")
        |> Map.put(:query_string, "")
        |> EmbedTokenPlug.call([])

      assert get_resp_header(conn, "vary") == []
    end
  end

  # An `?embed=1` request whose page then writes session state, as rendering
  # the CSRF token does.
  defp embed_request_writing_session(conn, sec_fetch_dest, path \\ "/sarah") do
    conn =
      if sec_fetch_dest, do: put_req_header(conn, "sec-fetch-dest", sec_fetch_dest), else: conn

    conn
    |> Map.put(:request_path, path)
    |> Map.put(:query_string, "embed=1")
    |> start_session()
    |> EmbedTokenPlug.call([])
    |> put_session(:csrf_state, "generated-by-the-page")
    |> send_resp(200, "ok")
  end

  # The `:drop` vs `:ignore` difference only materialises in Plug.Session's
  # before_send callback, so these run the request through the real session
  # plug and assert on the response cookies rather than on conn internals.

  # `:csrf_state` stands in for the CSRF token the root layout generates after
  # this plug has run, which is what the session cookie must carry.
  defp run_session_pipeline(conn, opts \\ []) do
    conn
    |> start_session()
    |> EmbedTokenPlug.call([])
    |> then(fn conn ->
      case opts[:csrf_state] do
        nil -> conn
        state -> put_session(conn, "_csrf_token", state)
      end
    end)
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
