defmodule TymeslotWeb.Integration.EmbedPipelineTest do
  @moduledoc """
  Integration tests that verify the embedding security configuration is correctly
  wired through the HTTP request pipeline — not just the plug in isolation.

  These tests catch regressions where the SecurityHeadersPlug is accidentally
  removed from the :theme_browser pipeline or misconfigured.
  """

  use TymeslotWeb.ConnCase, async: true
  @moduletag :integration
  @moduletag :security

  import Tymeslot.Factory

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
      assert get_resp_header(conn, "x-frame-options") == ["ALLOW-FROM https://trusted-site.com"]
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
end
