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

    test "uses default values", %{conn: conn} do
      conn = AuthControllerHelpers.handle_rate_limited(conn)
      assert Flash.get(conn.assigns.flash, :error) == "Too many attempts. Please try again later."
      assert redirected_to(conn) == "/"
    end
  end

  describe "format_validation_errors/1" do
    test "formats map of errors into string" do
      errors = %{email: "can't be blank", password: "is too short"}
      result = AuthControllerHelpers.format_validation_errors(errors)
      assert result =~ "Email can't be blank"
      assert result =~ "Password is too short"
    end
  end

  describe "convert_to_boolean/1" do
    test "converts various values to boolean" do
      assert AuthControllerHelpers.convert_to_boolean("true") == true
      assert AuthControllerHelpers.convert_to_boolean("on") == true
      assert AuthControllerHelpers.convert_to_boolean(true) == true
      assert AuthControllerHelpers.convert_to_boolean("false") == false
      assert AuthControllerHelpers.convert_to_boolean(nil) == false
      assert AuthControllerHelpers.convert_to_boolean(123) == false
    end
  end

  describe "handle_generic_error/4" do
    test "logs error, puts flash and redirects", %{conn: conn} do
      conn =
        AuthControllerHelpers.handle_generic_error(
          conn,
          :some_reason,
          "Something went wrong",
          "/error"
        )

      assert Flash.get(conn.assigns.flash, :error) == "Something went wrong"
      assert redirected_to(conn) == "/error"
    end
  end
end
