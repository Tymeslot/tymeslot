defmodule Tymeslot.Auth.OAuth.GoogleTest do
  @moduletag :auth
  use Tymeslot.DataCase, async: false

  alias Phoenix.Controller
  alias Phoenix.Flash
  alias Plug.Conn, as: PlugConn
  alias Plug.Test, as: PlugTest
  alias Tymeslot.Auth.OAuth.Google
  alias Tymeslot.Auth.OAuth.HelperMock
  import Mox
  import Phoenix.ConnTest, only: [redirected_to: 1]

  setup :verify_on_exit!
  @moduletag :auth

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

  test "handle_callback/4 validates state and exchanges code" do
    conn = PlugTest.init_test_session(PlugTest.conn(:get, "/"), %{})
    code = "code456"
    state = "state456"
    redirect_uri = "http://callback"

    expect(HelperMock, :handle_oauth_callback, fn _conn,
                                                  %{code: ^code, state: ^state, provider: :google} ->
      PlugConn.put_private(conn, :oauth_callback_result, {:ok, %{"id" => 2}})
    end)

    updated_conn = Google.handle_callback(conn, code, state, redirect_uri)
    assert updated_conn.private[:oauth_callback_result] == {:ok, %{"id" => 2}}
  end

  test "handle_callback/4 returns error on invalid state" do
    conn = PlugTest.init_test_session(PlugTest.conn(:get, "/"), %{})
    code = "code456"
    state = "wrong_state"
    redirect_uri = "http://callback"

    expect(HelperMock, :handle_oauth_callback, fn conn,
                                                  %{code: ^code, state: ^state, provider: :google} ->
      # Mock the error response from FlowHandler
      conn
      |> Controller.fetch_flash([])
      |> PlugConn.put_status(302)
      |> Controller.put_flash(:error, "invalid state")
      |> Controller.redirect(to: "/?auth=login")
    end)

    updated_conn = Google.handle_callback(conn, code, state, redirect_uri)
    assert updated_conn.status == 302
    assert redirected_to(updated_conn) == "/?auth=login"
    assert Flash.get(updated_conn.assigns.flash, :error) == "invalid state"
  end
end
