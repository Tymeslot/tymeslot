defmodule Tymeslot.Auth.OAuth.GenericOAuthTest do
  use Tymeslot.DataCase, async: false
  @moduletag :auth

  alias Plug.Test, as: PlugTest
  alias Tymeslot.Auth.OAuth.GenericOAuth
  alias Tymeslot.Auth.OAuth.HelperMock
  import Mox

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
      redirect_uri = "http://callback"

      expect(HelperMock, :generate_and_store_state, fn ^conn -> {conn, "state123"} end)

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

  describe "process_user/1" do
    test "delegates to helper with :oauth provider" do
      user_info = %{"sub" => "user-123", "email" => "test@example.com", "name" => "Test"}

      expect(HelperMock, :process_user, fn :oauth, ^user_info ->
        {:ok, %{email: "test@example.com", provider_uid: "user-123", name: "Test"}}
      end)

      assert {:ok, user} = GenericOAuth.process_user(user_info)
      assert user.provider_uid == "user-123"
    end
  end

  describe "registration_complete?/1" do
    test "delegates to helper with :oauth provider" do
      user = %{email: "test@example.com", provider_uid: "user-123"}

      expect(HelperMock, :registration_complete?, fn :oauth, ^user -> true end)

      assert GenericOAuth.registration_complete?(user)
    end
  end

  describe "handle_callback/4" do
    test "delegates to helper with :oauth provider" do
      conn = PlugTest.init_test_session(PlugTest.conn(:get, "/"), %{})
      code = "code123"
      state = "state123"

      expect(HelperMock, :handle_oauth_callback, fn _conn,
                                                    %{
                                                      code: ^code,
                                                      state: ^state,
                                                      provider: :oauth
                                                    } ->
        {:ok, conn, %{"sub" => "user-123"}}
      end)

      assert {:ok, _updated_conn, %{"sub" => "user-123"}} =
               GenericOAuth.handle_callback(conn, code, state, "http://callback")
    end
  end
end
