defmodule TymeslotWeb.Integration.EmbedPipelineTest do
  @moduledoc """
  Integration tests that verify the embedding security configuration is correctly
  wired through the HTTP request pipeline — not just the plug in isolation.

  These tests catch regressions where the SecurityHeadersPlug is accidentally
  removed from the :theme_browser pipeline or misconfigured, and verify that
  the embed token flows correctly from HTTP request through to LiveView mount.
  """

  use TymeslotWeb.ConnCase, async: true
  @moduletag :integration
  @moduletag :security

  import Tymeslot.Factory

  alias Tymeslot.Embed.Token
  alias TymeslotWeb.Router

  describe "CSP headers on public scheduling pages" do
    test "a scheduling page allows localhost embedding when the profile has no allowed domains (dev/test env)",
         %{conn: conn} do
      user = insert(:user)
      insert(:profile, user: user, username: "scheduser", allowed_embed_domains: [])

      conn = get(conn, "/scheduser")

      csp = conn |> get_resp_header("content-security-policy") |> List.first()
      assert csp =~ "frame-ancestors 'self' http://localhost:* http://127.0.0.1:*"
      assert get_resp_header(conn, "x-frame-options") == []
    end

    test "a scheduling page allows embedding from configured domains", %{conn: conn} do
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "embeduser",
        allowed_embed_domains: ["trusted-site.com"]
      )

      conn = get(conn, "/embeduser")

      csp = conn |> get_resp_header("content-security-policy") |> List.first()
      assert csp =~ "frame-ancestors 'self' https://trusted-site.com"
      # X-Frame-Options ALLOW-FROM is deprecated; CSP frame-ancestors is the sole authority
      # for modern browsers, so the plug intentionally omits X-Frame-Options when domains
      # are configured.
      assert get_resp_header(conn, "x-frame-options") == []
    end

    test "?preview=true on a scheduling page permits same-origin framing for the dashboard", %{
      conn: conn
    } do
      user = insert(:user)
      insert(:profile, user: user, username: "prevuser", allowed_embed_domains: [])

      conn = get(conn, "/prevuser?preview=true")

      csp = conn |> get_resp_header("content-security-policy") |> List.first()
      assert csp =~ "frame-ancestors 'self'"
      assert get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]
    end

    test "?preview=true with [\"none\"] domains still permits same-origin framing", %{conn: conn} do
      # Even when the user has explicitly disabled external embedding, the dashboard's
      # live preview iframe (same origin) must still work.
      user = insert(:user)
      insert(:profile, user: user, username: "nonepreview", allowed_embed_domains: ["none"])

      conn = get(conn, "/nonepreview?preview=true")

      csp = conn |> get_resp_header("content-security-policy") |> List.first()
      assert csp =~ "frame-ancestors 'self'"
      assert get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]
    end
  end

  describe "embed token flow through HTTP pipeline" do
    test "?embed=1 generates a token that appears in the scheduling session", %{conn: conn} do
      user = insert(:user)
      insert(:profile, user: user, username: "tokenflow", allowed_embed_domains: ["example.com"])

      # GET request through the full :theme_browser pipeline with ?embed=1
      conn = get(conn, "/tokenflow?embed=1")

      # The EmbedTokenPlug should have set the embed_token assign
      assert conn.assigns[:embed_token]

      # The token should be valid and contain the right username
      assert {:ok, {"tokenflow", _parent_origin}} = Token.verify(conn.assigns.embed_token)
    end

    test "request without ?embed=1 does not generate an embed token", %{conn: conn} do
      user = insert(:user)
      insert(:profile, user: user, username: "notoken", allowed_embed_domains: [])

      conn = get(conn, "/notoken")

      refute conn.assigns[:embed_token]
    end

    test "?embed=1 and CSP headers are both set in the same response", %{conn: conn} do
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "bothflow",
        allowed_embed_domains: ["trusted.com"]
      )

      conn = get(conn, "/bothflow?embed=1")

      # Token was generated
      assert conn.assigns[:embed_token]

      # CSP allows the configured domain
      csp = conn |> get_resp_header("content-security-policy") |> List.first()
      assert csp =~ "frame-ancestors 'self' https://trusted.com"
    end

    test "scheduling_session/1 passes embed_token from conn.assigns to session map", %{
      conn: conn
    } do
      user = insert(:user)
      insert(:profile, user: user, username: "sessionflow", allowed_embed_domains: [])

      conn = get(conn, "/sessionflow?embed=1")

      # Simulate what the router does: call the session function with the conn
      session = Router.scheduling_session(conn)

      assert {:ok, {"sessionflow", _parent_origin}} = Token.verify(session["embed_token"])
    end

    test "scheduling_session/1 returns nil embed_token for non-embed requests", %{conn: conn} do
      user = insert(:user)
      insert(:profile, user: user, username: "nosession", allowed_embed_domains: [])

      conn = get(conn, "/nosession")

      session = Router.scheduling_session(conn)

      assert session["embed_token"] == nil
    end
  end

  describe "embed.js static file serving" do
    test "digested embed.js URL is not mistaken for a username route", %{conn: conn} do
      # Regression test: digested embed filenames like embed-<hash>.js
      # were not matched by Plug.Static's `only` filter and fell through
      # to the router, where they were treated as /:username routes and
      # returned a 302 redirect instead of serving the JS file.
      conn = get(conn, "/embed-77f8e1a81d47c7a5f0ed947d3d44a0e7.js")

      # Should NOT be a 302 redirect (the old broken behavior).
      # It may be 200 (if the digested file exists) or 404 (if it doesn't),
      # but never a 302 to the homepage.
      refute conn.status == 302,
             "Digested embed.js URL should not redirect — it was being treated as a username"
    end
  end

  describe "full embed LiveView mount" do
    test "?embed=1 request renders a successful scheduling page (static render)", %{conn: conn} do
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "embedmount",
        allowed_embed_domains: ["example.com"],
        booking_theme: "1"
      )

      insert(:meeting_type, user: user, is_active: true)

      # The static render (disconnected) should succeed — EmbedAuthHook defers
      # origin verification to the WebSocket phase on disconnected render.
      conn = get(conn, "/embedmount?embed=1")

      assert conn.status == 200

      # The page should include the iframe_embed.js script for embedded context
      assert conn.resp_body =~ "iframe_embed.js"
    end

    test "non-embed request to the same page also renders successfully", %{conn: conn} do
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "normalmount",
        allowed_embed_domains: ["example.com"],
        booking_theme: "1"
      )

      insert(:meeting_type, user: user, is_active: true)

      conn = get(conn, "/normalmount")

      assert conn.status == 200

      # Non-embed requests also get iframe_embed.js (it no-ops when not in iframe)
      assert conn.resp_body =~ "iframe_embed.js"
    end

    test "?embed=1 with disabled embedding (sentinel) still renders static page", %{conn: conn} do
      # On static render, EmbedAuthHook does NOT check domains — it defers
      # to the WebSocket phase. So even with ["none"], the static page renders.
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "disabledmount",
        allowed_embed_domains: ["none"],
        booking_theme: "1"
      )

      insert(:meeting_type, user: user, is_active: true)

      conn = get(conn, "/disabledmount?embed=1")

      # Static render succeeds (origin check happens on WebSocket connect)
      assert conn.status == 200

      # The sentinel resolves through `dev_local_or_deny/0`, which in dev/test
      # allows the local origins instead of denying outright ('none' + DENY is
      # the production result). Assert the value that is actually served.
      csp = conn |> get_resp_header("content-security-policy") |> List.first()

      assert csp =~ "frame-ancestors 'self' http://localhost:* http://127.0.0.1:*;"
      refute csp =~ "frame-ancestors 'none'"

      # With frame-ancestors present, X-Frame-Options is deliberately omitted.
      assert get_resp_header(conn, "x-frame-options") == []
    end

    test "?embed=1 without a layout sets data-embed-layout=\"default\" (back-compat)", %{
      conn: conn
    } do
      # Legacy snippets carry no data-layout, so embed.js sends ?embed=1 with no
      # ?layout=. The server must keep the centred :default layout for these so
      # already-deployed embeds don't silently flip to the wide column layout on
      # upgrade. Column is opt-in via ?layout=column (see the next two tests).
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "layoutembed",
        allowed_embed_domains: ["example.com"],
        booking_theme: "1"
      )

      insert(:meeting_type, user: user, is_active: true)

      response = conn |> get("/layoutembed?embed=1") |> html_response(200)

      assert response =~ ~s(data-embed-layout="default")
    end

    test "?embed=1&layout=default sets data-embed-layout=\"default\"", %{conn: conn} do
      # An explicit ?layout=default resolves to the centred view, same as the
      # no-layout default.
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "layoutdefault",
        allowed_embed_domains: ["example.com"],
        booking_theme: "1"
      )

      insert(:meeting_type, user: user, is_active: true)

      response = conn |> get("/layoutdefault?embed=1&layout=default") |> html_response(200)

      assert response =~ ~s(data-embed-layout="default")
    end

    test "?embed=1&layout=column is idempotent — data-embed-layout stays \"column\"", %{
      conn: conn
    } do
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "layoutcolumn",
        allowed_embed_domains: ["example.com"],
        booking_theme: "1"
      )

      insert(:meeting_type, user: user, is_active: true)

      response = conn |> get("/layoutcolumn?embed=1&layout=column") |> html_response(200)

      assert response =~ ~s(data-embed-layout="column")
    end
  end
end
