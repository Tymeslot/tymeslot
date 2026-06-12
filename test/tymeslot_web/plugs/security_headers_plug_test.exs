defmodule TymeslotWeb.Plugs.SecurityHeadersPlugTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs
  @moduletag :security

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

    test "sets frame-ancestors with allowed domains and their www variants", %{
      conn: conn,
      profile: profile
    } do
      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      # X-Frame-Options is omitted — frame-ancestors is the authority and browsers
      # log a warning when both are present
      assert get_resp_header(conn, "x-frame-options") == []

      # CSP frame-ancestors should list allowed domains plus www variants
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "https://example.com"
      assert csp =~ "https://www.example.com"
      assert csp =~ "https://my-site.net"
      assert csp =~ "https://www.my-site.net"
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

      assert get_resp_header(conn, "x-frame-options") == []
    end

    test "does not expand www for wildcard domains", %{conn: conn} do
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "wildcardwww",
        allowed_embed_domains: ["*.example.com"]
      )

      conn =
        conn
        |> Map.put(:request_path, "/wildcardwww")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "https://*.example.com"
      # Wildcard already covers www, so no www.*.example.com should appear
      refute csp =~ "www.*.example.com"
    end

    test "expands www.example.com to include bare domain in CSP", %{conn: conn} do
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "wwwuser",
        allowed_embed_domains: ["www.mysite.com"]
      )

      conn =
        conn
        |> Map.put(:request_path, "/wwwuser")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "https://www.mysite.com"
      assert csp =~ "https://mysite.com"
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

    test "omits X-Frame-Options for embed-allowed pages", %{conn: conn, profile: profile} do
      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      # X-Frame-Options is omitted entirely when frame-ancestors is present — browsers
      # log a warning when both headers are set
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

    test "preview=true does NOT open framing to a disallowed third-party origin", %{conn: conn} do
      # Defense-in-depth regression: EmbedAuthHook skips the application-level
      # allowlist check on a preview render, so CSP frame-ancestors is the ONLY
      # thing stopping a disallowed origin from framing a preview URL. This test
      # locks that in — preview=true must keep frame-ancestors at 'self' (same
      # origin only) and must NOT echo any arbitrary cross-origin host. A
      # disallowed embedder (https://evil.com) therefore cannot frame the page
      # at all, regardless of the hook's preview exemption.
      user = insert(:user)
      profile = insert(:profile, user: user, username: "previewguard", allowed_embed_domains: [])

      conn =
        conn
        |> Map.put(:request_path, "/#{profile.username}")
        |> Map.put(:query_params, %{"preview" => "true"})
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      refute csp =~ "evil.com"

      # Isolate the frame-ancestors directive — other directives (script-src,
      # etc.) legitimately carry https origins, so the assertion must target
      # only the framing directive.
      [frame_ancestors] =
        csp
        |> String.split("; ")
        |> Enum.filter(&String.starts_with?(&1, "frame-ancestors"))

      # 'self' is the whole allowance — no third-party origin is permitted.
      assert frame_ancestors == "frame-ancestors 'self'"
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

  describe "production environment behavior" do
    setup do
      original_env = Application.get_env(:tymeslot, :environment)
      Application.put_env(:tymeslot, :environment, :prod)
      on_exit(fn -> Application.put_env(:tymeslot, :environment, original_env) end)
      :ok
    end

    test "blocks all embeds in production when profile has no allowed domains", %{conn: conn} do
      user = insert(:user)
      insert(:profile, user: user, username: "produser", allowed_embed_domains: [])

      conn =
        conn
        |> Map.put(:request_path, "/produser")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'none'"
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "blocks all embeds in production when allowed_embed_domains is nil", %{conn: conn} do
      user = insert(:user)
      insert(:profile, user: user, username: "prodniluser", allowed_embed_domains: nil)

      conn =
        conn
        |> Map.put(:request_path, "/prodniluser")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'none'"
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "blocks all embeds in production with [\"none\"] sentinel", %{conn: conn} do
      user = insert(:user)
      insert(:profile, user: user, username: "prodnoneuser", allowed_embed_domains: ["none"])

      conn =
        conn
        |> Map.put(:request_path, "/prodnoneuser")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'none'"
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "still allows configured domains in production", %{conn: conn} do
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "prodallowed",
        allowed_embed_domains: ["trusted.com"]
      )

      conn =
        conn
        |> Map.put(:request_path, "/prodallowed")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'self' https://trusted.com"
      refute csp =~ "localhost"
    end

    test "does not append localhost suffix to configured domains in production", %{conn: conn} do
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "prodnolocalhost",
        allowed_embed_domains: ["example.com"]
      )

      conn =
        conn
        |> Map.put(:request_path, "/prodnolocalhost")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      refute csp =~ "localhost"
      refute csp =~ "127.0.0.1"
    end

    test "localhost in allowed_embed_domains gets HTTPS in production", %{conn: conn} do
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "prodlocalhost",
        allowed_embed_domains: ["localhost"]
      )

      conn =
        conn
        |> Map.put(:request_path, "/prodlocalhost")
        |> SecurityHeadersPlug.call(allow_embedding: true)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "https://localhost"
      refute csp =~ "http://localhost"
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

    test "CSP frame-ancestors is the sole embedding authority for configured domains", %{
      conn: conn
    } do
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

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'self' https://trusted.com"

      # X-Frame-Options is omitted — browsers warn when both are present
      assert get_resp_header(conn, "x-frame-options") == []
    end
  end
end
