defmodule TymeslotWeb.Plugs.RequireAuthPlugTest do
  @moduledoc false

  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs
  @moduletag :auth

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

      assert "/auth/login" <> _query = redirected_to(conn)
    end

    test "names the page a GET asked for in the login link", %{conn: _conn} do
      conn =
        :get
        |> build_conn("/dashboard/meetings?meeting=12")
        |> conn_with_flash()
        |> RequireAuthPlug.call([])

      assert redirected_to(conn) ==
               "/auth/login?redirect_to=%2Fdashboard%2Fmeetings%3Fmeeting%3D12"
    end

    test "sends any other method to the plain login page", %{conn: _conn} do
      conn =
        :post
        |> build_conn("/dashboard/meetings")
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
end
