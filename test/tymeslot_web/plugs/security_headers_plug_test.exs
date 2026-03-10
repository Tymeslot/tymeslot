defmodule TymeslotWeb.Plugs.SecurityHeadersPlugTest do
  use TymeslotWeb.ConnCase, async: true

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

    test "preview=true still uses configured domains when they are set", %{
      conn: conn,
      profile: profile
    } do
      # When a profile has allowed domains, 'self' is always included in
      # frame-ancestors, so the same-origin dashboard Live Preview works without
      # any special handling. preview=true only changes behaviour for profiles
      # that have no configured domains (disabled state).
      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> Map.put(:query_params, %{"preview" => "true"})
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      # 'self' is always in frame-ancestors when domains are configured, so the
      # dashboard (same-origin) can embed the preview iframe regardless.
      assert csp =~ "frame-ancestors 'self'"
      assert csp =~ "https://example.com"
    end
  end

  describe "security headers with embedding enabled (permissive)" do
    test "allows localhost embedding when no domains are configured (dev/test env)", %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "openuser", allowed_embed_domains: [])

      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      # X-Frame-Options is omitted — CSP frame-ancestors is the authority
      assert get_resp_header(conn, "x-frame-options") == []

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'self' http://localhost:* http://127.0.0.1:*"
    end

    test "allows localhost embedding when allowed_embed_domains is nil (dev/test env)", %{
      conn: conn
    } do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "niluser", allowed_embed_domains: nil)

      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'self' http://localhost:* http://127.0.0.1:*"

      assert get_resp_header(conn, "x-frame-options") == []
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

  describe "analytics provider script-src origins" do
    setup do
      original = Application.get_env(:tymeslot, :analytics_providers)
      on_exit(fn -> Application.put_env(:tymeslot, :analytics_providers, original) end)
      :ok
    end

    test "includes analytics script origin in script-src when a provider is configured", %{
      conn: conn
    } do
      Application.put_env(:tymeslot, :analytics_providers, [
        %{
          provider: :umami,
          script_url: "https://umami.example.com/script.js",
          website_id: "abc123"
        }
      ])

      conn = SecurityHeadersPlug.call(conn, [])
      [csp] = get_resp_header(conn, "content-security-policy")

      [script_src_directive] =
        Enum.filter(String.split(csp, "; "), &String.starts_with?(&1, "script-src"))

      assert script_src_directive =~ "https://umami.example.com"
    end

    test "does not add extra origins to script-src when no providers are configured", %{
      conn: conn
    } do
      Application.put_env(:tymeslot, :analytics_providers, [])

      conn = SecurityHeadersPlug.call(conn, [])
      [csp] = get_resp_header(conn, "content-security-policy")

      [script_src_directive] =
        Enum.filter(String.split(csp, "; "), &String.starts_with?(&1, "script-src"))

      assert script_src_directive ==
               "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://www.google.com https://www.gstatic.com https://js.stripe.com"
    end

    test "deduplicates origins when two providers share the same host", %{conn: conn} do
      Application.put_env(:tymeslot, :analytics_providers, [
        %{
          provider: :umami,
          script_url: "https://analytics.example.com/script.js",
          website_id: "abc"
        },
        %{
          provider: :umami,
          script_url: "https://analytics.example.com/alt.js",
          website_id: "def"
        }
      ])

      conn = SecurityHeadersPlug.call(conn, [])
      [csp] = get_resp_header(conn, "content-security-policy")

      [script_src_directive] =
        Enum.filter(String.split(csp, "; "), &String.starts_with?(&1, "script-src"))

      origin_count =
        script_src_directive
        |> String.split(" ")
        |> Enum.count(&(&1 == "https://analytics.example.com"))

      assert origin_count == 1
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
