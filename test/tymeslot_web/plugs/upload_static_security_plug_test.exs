defmodule TymeslotWeb.Plugs.UploadStaticSecurityTest do
  @moduledoc false

  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs

  alias TymeslotWeb.Plugs.UploadStaticSecurity

  describe "call/2 — allowlisted extensions" do
    for ext <- ~w(.jpg .jpeg .png .gif .webp .mp4 .webm .mov) do
      test "passes through #{ext} and sets nosniff header", %{conn: conn} do
        path_info = ["uploads", "avatars", "123", "file#{unquote(ext)}"]

        result = UploadStaticSecurity.call(%{conn | path_info: path_info}, [])

        refute result.halted
        assert get_resp_header(result, "x-content-type-options") == ["nosniff"]
      end
    end

    test "accepts uppercase extensions", %{conn: conn} do
      result =
        UploadStaticSecurity.call(
          %{conn | path_info: ["uploads", "avatars", "1", "IMG.JPG"]},
          []
        )

      refute result.halted
      assert get_resp_header(result, "x-content-type-options") == ["nosniff"]
    end
  end

  describe "call/2 — blocked extensions" do
    for ext <- ~w(.html .htm .svg .js .css .php .exe .sh .xml) do
      test "returns 404 for #{ext}", %{conn: conn} do
        path_info = ["uploads", "avatars", "1", "evil#{unquote(ext)}"]

        result = UploadStaticSecurity.call(%{conn | path_info: path_info}, [])

        assert result.halted
        assert result.status == 404
        assert result.resp_body == "Not Found"
      end
    end

    test "returns 404 for files with no extension", %{conn: conn} do
      result =
        UploadStaticSecurity.call(%{conn | path_info: ["uploads", "avatars", "noext"]}, [])

      assert result.halted
      assert result.status == 404
    end

    test "blocks double-extension bypass attempts (foo.jpg.html)", %{conn: conn} do
      result =
        UploadStaticSecurity.call(
          %{conn | path_info: ["uploads", "avatars", "1", "malicious.jpg.html"]},
          []
        )

      assert result.halted
      assert result.status == 404
      assert result.resp_body == "Not Found"
    end
  end

  describe "call/2 — non-upload paths" do
    test "passes through dashboard paths without setting header", %{conn: conn} do
      result =
        UploadStaticSecurity.call(%{conn | path_info: ["dashboard", "settings"]}, [])

      refute result.halted
      assert get_resp_header(result, "x-content-type-options") == []
    end

    test "passes through bare /uploads with empty rest", %{conn: conn} do
      result = UploadStaticSecurity.call(%{conn | path_info: ["uploads"]}, [])

      refute result.halted
      assert get_resp_header(result, "x-content-type-options") == []
    end

    test "passes through root path", %{conn: conn} do
      result = UploadStaticSecurity.call(%{conn | path_info: []}, [])

      refute result.halted
    end
  end

  describe "call/2 — already halted" do
    test "does not touch an already-halted conn", %{conn: conn} do
      halted_conn =
        conn
        |> send_resp(401, "Unauthorized")
        |> halt()

      result =
        UploadStaticSecurity.call(
          %{halted_conn | path_info: ["uploads", "foo.html"]},
          []
        )

      assert result.status == 401
      assert result.resp_body == "Unauthorized"
    end
  end
end
