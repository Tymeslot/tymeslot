defmodule TymeslotWeb.RootLayoutTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  describe "root layout <html lang>" do
    test "reflects the active locale for a German request", %{conn: conn} do
      conn = get(conn, ~p"/auth/login?locale=de")

      assert html_response(conn, 200) =~ ~s(<html lang="de")
    end

    test "falls back to English when no locale is negotiated", %{conn: conn} do
      conn = get(conn, ~p"/auth/login")

      assert html_response(conn, 200) =~ ~s(<html lang="en")
    end
  end
end
