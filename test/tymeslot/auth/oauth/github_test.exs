defmodule Tymeslot.Auth.OAuth.GitHubTest do
  use Tymeslot.DataCase, async: false
  @moduletag :auth

  alias Plug.Test, as: PlugTest
  alias Tymeslot.Auth.OAuth.GitHub
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

    expect(HelperMock, :generate_and_store_state, fn ^conn -> {conn, "state123"} end)

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

  test "handle_callback/4 validates state and exchanges code" do
    conn = PlugTest.init_test_session(PlugTest.conn(:get, "/"), %{})
    code = "code123"
    state = "state123"
    redirect_uri = "http://callback"

    expect(HelperMock, :handle_oauth_callback, fn _conn,
                                                  %{code: ^code, state: ^state, provider: :github} ->
      {:ok, conn, %{"id" => 1}}
    end)

    assert {:ok, _updated_conn, %{"id" => 1}} =
             GitHub.handle_callback(conn, code, state, redirect_uri)
  end

  test "handle_callback/4 returns error on invalid state" do
    conn = PlugTest.init_test_session(PlugTest.conn(:get, "/"), %{})
    code = "code123"
    state = "wrong_state"
    redirect_uri = "http://callback"

    expect(HelperMock, :handle_oauth_callback, fn _conn,
                                                  %{code: ^code, state: ^state, provider: :github} ->
      {:error, conn, :invalid_state}
    end)

    assert {:error, ^conn, :invalid_state} =
             GitHub.handle_callback(conn, code, state, redirect_uri)
  end
end
