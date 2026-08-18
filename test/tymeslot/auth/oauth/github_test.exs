defmodule Tymeslot.Auth.OAuth.GitHubTest do
  use Tymeslot.DataCase, async: false
  @moduletag :auth

  alias Plug.Test, as: PlugTest
  alias Tymeslot.Auth.OAuth.GitHub
  alias Tymeslot.Auth.OAuth.HelperMock
  import Mox
  import Tymeslot.AuthTestHelpers, only: [setup_oauth_authorize_url: 1]

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
    {conn, redirect_uri} = setup_oauth_authorize_url(conn)

    expect(HelperMock, :build_oauth_client, fn :github, ^redirect_uri, "state123" ->
      %OAuth2.Client{
        client_id: "test",
        authorize_url: "https://github.com/login/oauth/authorize",
        redirect_uri: redirect_uri,
        params: %{"state" => "state123"}
      }
    end)

    {_updated_conn, url} = GitHub.authorize_url(conn, redirect_uri)
    assert url =~ "state=state123"
    assert url =~ "scope=user%3Aemail"
  end

  test "get_callback_url/0 asks the helper for the :github provider" do
    # The stub derives its answer from the provider it is handed, so the
    # assertion below fails if this module ever asks for a different provider.
    expect(HelperMock, :get_callback_url, fn provider -> "/auth/#{provider}/callback" end)

    assert GitHub.get_callback_url() == "/auth/github/callback"
  end
end
