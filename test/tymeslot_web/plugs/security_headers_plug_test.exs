defmodule TymeslotWeb.Plugs.SecurityHeadersPlugTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :utils

  alias TymeslotWeb.Plugs.SecurityHeadersPlug
  import Tymeslot.Factory

  describe "security headers without embedding" do
    test "sets default security headers", %{conn: conn} do
      conn = SecurityHeadersPlug.call(conn, [])

      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'none'"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]
      assert get_resp_header(conn, "strict-transport-security") != []
      assert get_resp_header(conn, "x-xss-protection") == ["1; mode=block"]
    end

    test "CSP header contains required directives", %{conn: conn} do
      conn = SecurityHeadersPlug.call(conn, [])
      [csp] = get_resp_header(conn, "content-security-policy")

      assert csp =~ "default-src 'self'"
      assert csp =~ "script-src"
      assert csp =~ "style-src"
      assert csp =~ "img-src"
      assert csp =~ "font-src"
      assert csp =~ "connect-src"
      assert csp =~ "frame-src"
      assert csp =~ "base-uri 'self'"
      assert csp =~ "form-action 'self'"
    end
  end

  describe "security headers with embedding enabled (configured domains)" do
    setup do
      user = insert(:user)

      profile =
        insert(:profile,
          user: user,
          username: "testuser",
          allowed_embed_domains: ["example.com", "my-site.net"]
        )

      {:ok, profile: profile}
    end

    test "sets frame-ancestors with allowed domains", %{conn: conn, profile: profile} do
      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      # X-Frame-Options should now allow embedding
      assert [x_frame_options] = get_resp_header(conn, "x-frame-options")
      assert x_frame_options =~ "ALLOW-FROM https://example.com"

      # CSP frame-ancestors should list allowed domains
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'self' https://example.com https://my-site.net"
    end

    test "builds HTTPS URLs for allowed domains", %{conn: conn, profile: profile} do
      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "https://example.com"
      assert csp =~ "https://my-site.net"
      refute csp =~ "http://example.com"
    end

    test "handles local development hosts with HTTP and port wildcards", %{conn: conn} do
      user = insert(:user)

      profile =
        insert(:profile,
          user: user,
          username: "devuser",
          allowed_embed_domains: ["localhost", "127.0.0.1", "::1"]
        )

      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'self' http://localhost:* http://127.0.0.1:* http://::1:*"

      assert [x_frame_options] = get_resp_header(conn, "x-frame-options")
      assert x_frame_options == "ALLOW-FROM http://localhost"
    end

    test "handles wildcard domains in CSP", %{conn: conn} do
      user = insert(:user)

      profile =
        insert(:profile,
          user: user,
          username: "wildcarduser",
          allowed_embed_domains: ["*.example.com", "other-site.net"]
        )

      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "https://*.example.com"
      assert csp =~ "https://other-site.net"
    end

    test "sets X-Frame-Options to first allowed domain", %{conn: conn, profile: profile} do
      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [x_frame_options] = get_resp_header(conn, "x-frame-options")
      # Should use the first domain in the list
      assert x_frame_options == "ALLOW-FROM https://example.com"
    end

    test "omits X-Frame-Options when first domain is a wildcard", %{conn: conn} do
      user = insert(:user)

      profile =
        insert(:profile,
          user: user,
          username: "wildcardxframe",
          allowed_embed_domains: ["*.example.com"]
        )

      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "https://*.example.com"

      # X-Frame-Options should be omitted because it doesn't support wildcards
      assert get_resp_header(conn, "x-frame-options") == []
    end
  end

  describe "security headers with embedding enabled (permissive)" do
    test "blocks all embeds when no domains are configured (default deny)", %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "openuser", allowed_embed_domains: [])

      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert get_resp_header(conn, "x-frame-options") == ["DENY"]

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'none'"
    end

    test "handles nil allowed_embed_domains (default deny)", %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "niluser", allowed_embed_domains: nil)

      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'none'"

      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "blocks all embeds when no username is in path", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/demo/test")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'none'"

      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "falls back to blocking when profile not found", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/nonexistentuser")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'none'"

      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "doesn't extract username from reserved paths and blocks embedding", %{conn: conn} do
      reserved_paths = [
        "/auth/login",
        "/dashboard",
        "/api/endpoint",
        "/assets/app.js",
        "/docs/embed",
        "/embed.js"
      ]

      for path <- reserved_paths do
        conn =
          conn
          |> Map.put(:request_path, path)
          |> SecurityHeadersPlug.call(allow_embedding: true)

        assert [csp] = get_resp_header(conn, "content-security-policy")
        assert csp =~ "frame-ancestors 'none'"
      end
    end

    test "allows SAMEORIGIN framing when preview=true is passed", %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "previewuser", allowed_embed_domains: [])

      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> Map.put(:query_params, %{"preview" => "true"})
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'self'"
    end
  end

  describe "username extraction" do
    test "extracts username from root path", %{conn: conn} do
      user = insert(:user)
      _profile = insert(:profile, user: user, username: "john", allowed_embed_domains: [])

      conn =
        conn
        |> Map.put(:request_path, "/john")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      # Should find the profile and use its settings
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors"
    end

    test "extracts username from nested paths", %{conn: conn} do
      user = insert(:user)

      _profile =
        insert(:profile, user: user, username: "sarah", allowed_embed_domains: ["example.com"])

      conn =
        conn
        |> Map.put(:request_path, "/sarah/30")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "https://example.com"
    end
  end

  describe "security header combinations" do
    test "all security headers are present together", %{conn: conn} do
      conn = SecurityHeadersPlug.call(conn, allow_embedding: false)

      # Verify all important security headers are present
      assert get_resp_header(conn, "content-security-policy") != []
      assert get_resp_header(conn, "x-content-type-options") != []
      assert get_resp_header(conn, "referrer-policy") != []
      assert get_resp_header(conn, "permissions-policy") != []
      assert get_resp_header(conn, "strict-transport-security") != []
      assert get_resp_header(conn, "x-xss-protection") != []
      assert get_resp_header(conn, "expect-ct") != []
      assert get_resp_header(conn, "x-frame-options") != []
    end

    test "CSP and X-Frame-Options work together for restricted embedding", %{conn: conn} do
      user = insert(:user)

      profile =
        insert(:profile,
          user: user,
          username: "restricted",
          allowed_embed_domains: ["trusted.com"]
        )

      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      # Both should restrict to the allowed domain
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'self' https://trusted.com"

      assert [x_frame_options] = get_resp_header(conn, "x-frame-options")
      assert x_frame_options == "ALLOW-FROM https://trusted.com"
    end
  end
end
