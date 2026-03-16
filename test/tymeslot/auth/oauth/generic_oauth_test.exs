defmodule Tymeslot.Auth.OAuth.GenericOAuthTest do
  use Tymeslot.DataCase, async: false
  @moduletag :auth

  alias Plug.Test, as: PlugTest
  alias Tymeslot.Auth.OAuth.GenericOAuth
  alias Tymeslot.Auth.OAuth.HelperMock
  import Mox
  import Tymeslot.AuthTestHelpers, only: [setup_oauth_authorize_url: 1]

  setup :verify_on_exit!

  setup do
    old_helper = Application.get_env(:tymeslot, :oauth_helper_module)
    Application.put_env(:tymeslot, :oauth_helper_module, HelperMock)

    old_config = Application.get_env(:tymeslot, :oauth_provider)

    Application.put_env(:tymeslot, :oauth_provider,
      client_id: "test-client-id",
      client_secret: "test-secret",
      site: "https://idp.example.com",
      authorize_url: "https://idp.example.com/authorize",
      token_url: "https://idp.example.com/token",
      userinfo_url: "https://idp.example.com/userinfo",
      scope: "openid email profile"
    )

    on_exit(fn ->
      if old_helper,
        do: Application.put_env(:tymeslot, :oauth_helper_module, old_helper),
        else: Application.delete_env(:tymeslot, :oauth_helper_module)

      if old_config,
        do: Application.put_env(:tymeslot, :oauth_provider, old_config),
        else: Application.delete_env(:tymeslot, :oauth_provider)
    end)

    :ok
  end

  describe "authorize_url/2" do
    test "generates state and builds client for generic OAuth" do
      conn = PlugTest.init_test_session(PlugTest.conn(:get, "/"), %{})
      {conn, redirect_uri} = setup_oauth_authorize_url(conn)

      expect(HelperMock, :build_oauth_client, fn :oauth, ^redirect_uri, "state123" ->
        %OAuth2.Client{
          client_id: "test-client-id",
          authorize_url: "https://idp.example.com/authorize",
          redirect_uri: redirect_uri,
          params: %{"state" => "state123"}
        }
      end)

      {_updated_conn, url} = GenericOAuth.authorize_url(conn, redirect_uri)
      assert url =~ "state=state123"
      assert url =~ "scope=openid"
    end
  end

  describe "get_callback_url/0" do
    test "returns generic OAuth callback path" do
      expect(HelperMock, :get_callback_url, fn :oauth -> "/auth/oauth/callback" end)

      assert GenericOAuth.get_callback_url() == "/auth/oauth/callback"
    end
  end
end
