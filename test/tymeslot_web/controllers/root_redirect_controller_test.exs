defmodule TymeslotWeb.RootRedirectControllerTest do
  @moduletag :utils
  # async false because we are changing env vars
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: false

  alias Tymeslot.AuthTestHelpers
  alias Tymeslot.Factory

  setup do
    # Save original env and config to restore them later
    original_type = System.get_env("DEPLOYMENT_TYPE")
    original_router = Application.get_env(:tymeslot, :router)

    # Force standalone mode for these tests
    Application.put_env(:tymeslot, :router, TymeslotWeb.Router)

    on_exit(fn ->
      if original_type do
        System.put_env("DEPLOYMENT_TYPE", original_type)
      else
        System.delete_env("DEPLOYMENT_TYPE")
      end

      Application.put_env(:tymeslot, :router, original_router)
    end)

    :ok
  end

  describe "GET /" do
    test "redirects to dashboard if user is logged in", %{conn: conn} do
      user = Factory.insert(:user)
      conn = conn |> AuthTestHelpers.log_in_user(user) |> get(~p"/")

      assert redirected_to(conn) == "/dashboard"
    end

    test "redirects to login if unauthenticated and standalone (docker)", %{conn: conn} do
      System.put_env("DEPLOYMENT_TYPE", "docker")
      conn = get(conn, ~p"/")

      assert redirected_to(conn) == "/auth/login"
    end

    test "redirects to login if unauthenticated and standalone (cloudron)", %{conn: conn} do
      System.put_env("DEPLOYMENT_TYPE", "cloudron")
      conn = get(conn, ~p"/")

      assert redirected_to(conn) == "/auth/login"
    end
  end
end
