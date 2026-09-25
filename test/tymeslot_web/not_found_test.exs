defmodule TymeslotWeb.NotFoundTest do
  # async: false because the tests change global router and admin-UI config.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :plugs
  @moduletag :auth

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  setup do
    # Under a downstream overlay the endpoint routes through that overlay's
    # router; point it at Core's so the admin scope's own plugs are reached.
    original_router = Application.get_env(:tymeslot, :router)
    Application.put_env(:tymeslot, :router, TymeslotWeb.Router)
    Application.put_env(:tymeslot, :enable_admin_ui, false)

    on_exit(fn ->
      if original_router,
        do: Application.put_env(:tymeslot, :router, original_router),
        else: Application.delete_env(:tymeslot, :router)

      Application.put_env(:tymeslot, :enable_admin_ui, true)
    end)

    :ok
  end

  describe "a plug answering 404" do
    test "serves the same bare branded page as the catch-all route", %{conn: conn} do
      # Rendered inside the root layout, the page would carry a canonical link
      # advertising the missing URL, and would tell a probe this 404 differs
      # from a genuinely unmatched path.
      conn = log_in_user(conn, insert(:user, is_admin: true))

      body = conn |> get(~p"/admin") |> response(404)

      assert body =~ "This page doesn&#39;t exist"
      refute body =~ ~s(rel="canonical")
    end
  end
end
