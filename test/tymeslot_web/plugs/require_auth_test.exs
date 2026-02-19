defmodule TymeslotWeb.Plugs.RequireAuthPlugTest do
  @moduledoc false

  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs

  alias Phoenix.ConnTest
  alias Phoenix.Controller
  alias Phoenix.Flash
  alias Plug.Conn
  alias Tymeslot.Factory
  alias TymeslotWeb.Plugs.RequireAuthPlug

  defp conn_with_flash(conn) do
    conn
    |> ConnTest.init_test_session(%{})
    |> Conn.fetch_session()
    |> Controller.fetch_flash()
  end

  describe "call/2" do
    test "allows request through when current_user is assigned", %{conn: conn} do
      user = Factory.insert(:user)

      conn =
        conn
        |> conn_with_flash()
        |> assign(:current_user, user)
        |> RequireAuthPlug.call([])

      refute conn.halted
    end

    test "redirects to /auth/login when no current_user", %{conn: conn} do
      conn =
        conn
        |> conn_with_flash()
        |> RequireAuthPlug.call([])

      assert redirected_to(conn) == "/auth/login"
    end

    test "sets error flash message on redirect", %{conn: conn} do
      conn =
        conn
        |> conn_with_flash()
        |> RequireAuthPlug.call([])

      assert Flash.get(conn.assigns.flash, :error) =~
               "You must be logged in to access this page."
    end

    test "halts the connection on redirect", %{conn: conn} do
      conn =
        conn
        |> conn_with_flash()
        |> RequireAuthPlug.call([])

      assert conn.halted
    end
  end

  describe "init/1" do
    test "passes options through unchanged" do
      assert RequireAuthPlug.init(foo: :bar) == [foo: :bar]
    end
  end
end
