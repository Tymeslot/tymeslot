defmodule TymeslotWeb.Plugs.RejectStaticPathsPlugTest do
  @moduledoc false

  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs
  @moduletag :security

  alias TymeslotWeb.Plugs.RejectStaticPathsPlug

  describe "call/2" do
    for ext <- ~w(.js .css .map .json .ico .png .jpg .svg .woff .woff2 .ttf .gz) do
      test "rejects request with #{ext} extension in first segment", %{conn: conn} do
        conn =
          RejectStaticPathsPlug.call(%{conn | path_info: ["app#{unquote(ext)}"]}, [])

        assert conn.status == 404
        assert conn.halted
        assert hd(get_resp_header(conn, "content-type")) =~ "text/plain"
      end
    end

    test "passes through non-static path", %{conn: conn} do
      result = RejectStaticPathsPlug.call(%{conn | path_info: ["dashboard", "settings"]}, [])

      refute result.halted
    end

    test "passes through username path", %{conn: conn} do
      result = RejectStaticPathsPlug.call(%{conn | path_info: ["johndoe"]}, [])

      refute result.halted
    end

    test "passes through root path with empty path_info", %{conn: conn} do
      result = RejectStaticPathsPlug.call(%{conn | path_info: []}, [])

      refute result.halted
    end

    test "passes through when only second segment has static extension", %{conn: conn} do
      result = RejectStaticPathsPlug.call(%{conn | path_info: ["assets", "app.js"]}, [])

      refute result.halted
    end

    test "rejected response body is 'Not Found'", %{conn: conn} do
      conn = RejectStaticPathsPlug.call(%{conn | path_info: ["embed.js"]}, [])

      assert conn.resp_body == "Not Found"
    end

    test "does not modify an already-halted conn", %{conn: conn} do
      halted_conn =
        conn
        |> send_resp(401, "Unauthorized")
        |> halt()

      result = RejectStaticPathsPlug.call(%{halted_conn | path_info: ["app.js"]}, [])

      assert result.status == 401
      assert result.resp_body == "Unauthorized"
    end
  end
end
