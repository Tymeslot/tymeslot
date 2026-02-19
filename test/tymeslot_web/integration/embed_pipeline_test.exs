defmodule TymeslotWeb.Integration.EmbedPipelineTest do
  @moduledoc """
  Integration tests that verify the embedding security configuration is correctly
  wired through the HTTP request pipeline — not just the plug in isolation.

  These tests catch regressions where the SecurityHeadersPlug is accidentally
  removed from the :theme_browser pipeline or misconfigured.
  """

  use TymeslotWeb.ConnCase, async: true
  @moduletag :integration

  import Tymeslot.Factory

  describe "CSP headers on public scheduling pages" do
    test "a scheduling page blocks embedding when the profile has no allowed domains", %{
      conn: conn
    } do
      user = insert(:user)
      insert(:profile, user: user, username: "scheduser", allowed_embed_domains: [])

      conn = get(conn, "/scheduser")

      csp = conn |> get_resp_header("content-security-policy") |> List.first()
      assert csp =~ "frame-ancestors 'none'"
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
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
end
