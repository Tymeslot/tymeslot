defmodule Tymeslot.Auth.OAuth.ProvidersTest do
  use ExUnit.Case, async: false

  @moduletag :auth

  alias Tymeslot.Auth.OAuth.Providers

  setup do
    original = Application.get_env(:tymeslot, :oauth_provider)
    on_exit(fn -> Application.put_env(:tymeslot, :oauth_provider, original) end)
  end

  describe "config(:oauth)" do
    test "resolves relative endpoints against the provider's base URL" do
      put_sso_config(
        site: "https://idp.example.com/realms/main/",
        authorize_url: "protocol/auth",
        token_url: "https://other.example.com/token",
        userinfo_url: "/userinfo"
      )

      config = Providers.config(:oauth)

      assert config.authorize_url == "https://idp.example.com/realms/main/protocol/auth"
      assert config.token_url == "https://other.example.com/token"
      assert config.userinfo_url == "https://idp.example.com/userinfo"
    end

    test "needs no base URL when every endpoint is absolute" do
      put_sso_config(
        site: nil,
        authorize_url: "https://idp.example.com/auth",
        token_url: "https://idp.example.com/token",
        userinfo_url: "https://idp.example.com/userinfo"
      )

      assert Providers.config(:oauth).token_url == "https://idp.example.com/token"
    end

    test "raises naming a missing endpoint" do
      put_sso_config(
        authorize_url: "https://idp.example.com/auth",
        token_url: nil,
        userinfo_url: "/u"
      )

      assert_raise RuntimeError, ~r/:token_url/, fn -> Providers.config(:oauth) end
    end
  end

  describe "name/1" do
    test "names the generic provider after its configured name" do
      put_sso_config(name: "  Beaver Cloud ")

      assert Providers.name(:oauth) == "Beaver Cloud"
    end

    test "falls back to SSO when no name is configured" do
      put_sso_config(name: nil)
      assert Providers.name(:oauth) == "SSO"

      put_sso_config(name: "   ")
      assert Providers.name(:oauth) == "SSO"
    end

    test "leaves the named providers alone" do
      put_sso_config(name: "Beaver Cloud")

      assert Providers.name(:github) == "GitHub"
    end
  end

  defp put_sso_config(overrides) do
    Application.put_env(
      :tymeslot,
      :oauth_provider,
      Keyword.merge([client_id: "id", client_secret: "secret", scope: "openid"], overrides)
    )
  end
end
