defmodule TymeslotWeb.Plugs.SecurityHeadersPlugProdTest do
  # Not async: these tests flip the global `:tymeslot, :environment` to `:prod`,
  # which every other module reading that key would observe. Keeping them in a
  # separate serial module lets the rest of the plug's suite stay async.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :plugs
  @moduletag :security

  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Plugs.SecurityHeadersPlug
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  setup do
    setup_config(:tymeslot, :environment, :prod)
  end

  defp frame_ancestors(csp) do
    csp
    |> String.split("; ")
    |> Enum.find(&String.starts_with?(&1, "frame-ancestors "))
  end

  describe "production environment behavior" do
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
      refute frame_ancestors(csp) =~ "localhost"
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
      # The connect-src socket origin names the test endpoint's own host, which
      # is localhost; the embed allow-list is what must stay free of it.
      refute frame_ancestors(csp) =~ "localhost"
      refute frame_ancestors(csp) =~ "127.0.0.1"
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

  describe "Content-Security-Policy directives" do
    setup do
      setup_config(:tymeslot, :analytics_providers, [])

      original_keys =
        Map.new(~w(RECAPTCHA_SITE_KEY RECAPTCHA_SECRET_KEY), &{&1, System.get_env(&1)})

      on_exit(fn ->
        Enum.each(original_keys, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      # The test endpoint serves plain HTTP on localhost, at a port each
      # worktree may override; the socket origin follows it.
      %{socket_origin: "ws://localhost:#{Endpoint.config(:url)[:port]}"}
    end

    defp directives(conn) do
      conn = SecurityHeadersPlug.call(conn, [])
      [csp] = get_resp_header(conn, "content-security-policy")

      directives =
        csp
        |> String.split("; ")
        |> Map.new(fn directive ->
          [name | sources] = String.split(directive, " ", parts: 2)
          {name, Enum.join(sources, " ")}
        end)

      {directives, conn.assigns.csp_nonce}
    end

    defp enable_recaptcha(flags) do
      setup_config(:tymeslot, :recaptcha, flags)
      System.put_env("RECAPTCHA_SITE_KEY", "site-key")
      System.put_env("RECAPTCHA_SECRET_KEY", "secret-key")
    end

    test "allows no third-party origin while reCAPTCHA is off", %{
      conn: conn,
      socket_origin: socket_origin
    } do
      setup_config(:tymeslot, :recaptcha, booking_enabled: false, signup_enabled: false)

      {directives, nonce} = directives(conn)

      assert directives["script-src"] == "'self' 'nonce-#{nonce}'"
      assert directives["img-src"] == "'self' data:"
      assert directives["connect-src"] == "'self' #{socket_origin}"
      assert directives["frame-src"] == "'self'"

      assert directives["form-action"] ==
               "'self' https://billing.stripe.com https://checkout.stripe.com https://connect.stripe.com"
    end

    test "adds the reCAPTCHA origins while booking reCAPTCHA is active", %{
      conn: conn,
      socket_origin: socket_origin
    } do
      enable_recaptcha(booking_enabled: true, signup_enabled: false)

      {directives, nonce} = directives(conn)

      assert directives["script-src"] ==
               "'self' 'nonce-#{nonce}' https://www.google.com https://www.gstatic.com"

      assert directives["img-src"] == "'self' data:"
      assert directives["connect-src"] == "'self' #{socket_origin} https://www.google.com"
      assert directives["frame-src"] == "'self' https://www.google.com"
    end

    test "adds the reCAPTCHA origins while only signup reCAPTCHA is active", %{conn: conn} do
      enable_recaptcha(booking_enabled: false, signup_enabled: true)

      {directives, _nonce} = directives(conn)

      assert directives["frame-src"] == "'self' https://www.google.com"
    end

    test "leaves the reCAPTCHA origins out while it is enabled but has no keys", %{conn: conn} do
      setup_config(:tymeslot, :recaptcha, booking_enabled: true, signup_enabled: true)
      System.delete_env("RECAPTCHA_SITE_KEY")
      System.delete_env("RECAPTCHA_SECRET_KEY")

      {directives, _nonce} = directives(conn)

      assert directives["frame-src"] == "'self'"
    end
  end
end
