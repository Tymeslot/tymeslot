defmodule TymeslotWeb.Plugs.FetchCurrentUserTest do
  @moduledoc """
  Covers the core-authentication state assignment plug. Every browser
  request passes through `FetchCurrentUser` before reaching any
  controller or LiveView, so its output shape (`:current_user` on
  `conn.assigns`, `nil` on absent or invalid tokens) is an invariant the
  entire app relies on.
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs
  @moduletag :auth

  alias Phoenix.ConnTest
  alias Plug.Conn
  alias Tymeslot.Auth.Session
  alias Tymeslot.Factory
  alias TymeslotWeb.Plugs.FetchCurrentUser

  defp conn_with_session(conn) do
    conn
    |> ConnTest.init_test_session(%{})
    |> Conn.fetch_session()
  end

  describe "call/2" do
    test "assigns current_user and keeps the token when a valid session token is present",
         %{conn: conn} do
      user = Factory.insert(:user)

      {:ok, conn, token} =
        conn
        |> conn_with_session()
        |> Session.create_session(user)

      conn = FetchCurrentUser.call(conn, [])

      assert conn.assigns.current_user.id == user.id
      assert Conn.get_session(conn, :user_token) == token
    end

    test "assigns nil current_user when no session token is in the session",
         %{conn: conn} do
      conn =
        conn
        |> conn_with_session()
        |> FetchCurrentUser.call([])

      assert conn.assigns.current_user == nil
    end

    test "assigns nil current_user when the session token does not match any user",
         %{conn: conn} do
      # A malformed / expired / already-deleted token must not crash the
      # plug — it must downgrade to an unauthenticated request.
      conn =
        conn
        |> conn_with_session()
        |> Conn.put_session(:user_token, "does-not-exist-in-the-db")
        |> FetchCurrentUser.call([])

      assert conn.assigns.current_user == nil
    end

    test "drops a token that no longer maps to a session", %{conn: conn} do
      user = Factory.insert(:user)

      {:ok, conn, _token} =
        conn
        |> conn_with_session()
        |> Session.create_session(user)

      Session.revoke_all_sessions(user.id)

      conn = FetchCurrentUser.call(conn, [])

      assert conn.assigns.current_user == nil
      assert Conn.get_session(conn, :user_token) == nil
      assert Conn.get_session(conn, :live_socket_id) == nil
    end
  end
end
