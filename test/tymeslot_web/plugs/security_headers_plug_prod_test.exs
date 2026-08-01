defmodule TymeslotWeb.Plugs.SecurityHeadersPlugProdTest do
  # Not async: these tests flip the global `:tymeslot, :environment` to `:prod`,
  # which every other module reading that key would observe. Keeping them in a
  # separate serial module lets the rest of the plug's suite stay async.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :plugs
  @moduletag :security

  alias TymeslotWeb.Plugs.SecurityHeadersPlug
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  setup do
    setup_config(:tymeslot, :environment, :prod)
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
end
