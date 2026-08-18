defmodule TymeslotWeb.Plugs.FetchCurrentUserTest do
  @moduledoc """
  Covers the core-authentication state assignment plug. Every browser
  request passes through `FetchCurrentUser` before reaching any
  controller or LiveView, so its output shape — `:current_user` and
  `:user_token` on `conn.assigns`, with `nil` on absent/invalid tokens —
  is an invariant the entire app relies on.
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs

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
    test "assigns both current_user and user_token when a valid session token is present",
         %{conn: conn} do
      user = Factory.insert(:user)

      {:ok, conn, token} =
        conn
        |> conn_with_session()
        |> Session.create_session(user)

      conn = FetchCurrentUser.call(conn, [])

      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.user_token == token
    end

    test "assigns nil current_user and nil user_token when no session token is in the session",
         %{conn: conn} do
      conn =
        conn
        |> conn_with_session()
        |> FetchCurrentUser.call([])

      assert conn.assigns.current_user == nil
      assert conn.assigns.user_token == nil
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
      # The user_token assign still reflects the session contents so
      # LogOut / regenerate flows can clear it.
      assert conn.assigns.user_token == "does-not-exist-in-the-db"
    end
  end
end
