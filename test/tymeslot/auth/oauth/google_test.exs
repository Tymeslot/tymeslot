defmodule Tymeslot.Auth.OAuth.GoogleTest do
  use Tymeslot.DataCase, async: false
  @moduletag :auth

  alias Plug.Test, as: PlugTest
  alias Tymeslot.Auth.OAuth.Google
  alias Tymeslot.Auth.OAuth.HelperMock
  import Mox

  setup :verify_on_exit!

  setup do
    old_helper = Application.get_env(:tymeslot, :oauth_helper_module)
    Application.put_env(:tymeslot, :oauth_helper_module, HelperMock)

    on_exit(fn ->
      if old_helper,
        do: Application.put_env(:tymeslot, :oauth_helper_module, old_helper),
        else: Application.delete_env(:tymeslot, :oauth_helper_module)
    end)

    :ok
  end

  test "authorize_url/2 generates state and builds client" do
    conn = PlugTest.init_test_session(PlugTest.conn(:get, "/"), %{})
    redirect_uri = "http://callback"

    expect(HelperMock, :generate_and_store_state, fn ^conn -> {conn, "state456"} end)

    expect(HelperMock, :build_oauth_client, fn :google, ^redirect_uri, "state456" ->
      %OAuth2.Client{
        client_id: "test",
        authorize_url: "https://accounts.google.com/oauth/authorize",
        redirect_uri: redirect_uri,
        params: %{"state" => "state456"}
      }
    end)

    {_updated_conn, url} = Google.authorize_url(conn, redirect_uri)
    assert url =~ "state=state456"
    assert url =~ "scope=email+profile"
  end

  test "get_callback_url/0 returns Google callback path" do
    expect(HelperMock, :get_callback_url, fn :google -> "/auth/google/callback" end)

    assert Google.get_callback_url() == "/auth/google/callback"
  end
end
