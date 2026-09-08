defmodule TymeslotWeb.AuthControllerHelpersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias Phoenix.Flash
  alias Plug.Session
  alias TymeslotWeb.AuthControllerHelpers

  setup %{conn: conn} do
    conn =
      conn
      |> Map.put(:secret_key_base, String.duplicate("a", 64))
      |> Session.call(Session.init(store: :cookie, key: "_test", signing_salt: "salt"))
      |> fetch_session()
      |> fetch_flash()

    {:ok, conn: conn}
  end

  describe "handle_rate_limited/3" do
    test "puts flash and redirects", %{conn: conn} do
      conn = AuthControllerHelpers.handle_rate_limited(conn, "Too many requests", "/login")
      assert Flash.get(conn.assigns.flash, :error) == "Too many requests"
      assert redirected_to(conn) == "/login"
    end
  end
end
