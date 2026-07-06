defmodule TymeslotWeb.FallbackControllerTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :utils

  describe "GET / (fallback)" do
    test "returns a real 404 for unmatched paths", %{conn: conn} do
      # We need to trigger the fallback.
      # Paths like "/foo" are caught by the /:username route.
      # Paths with multiple segments like "/foo/bar" should hit the fallback.

      conn = get(conn, "/invalid/path/to/trigger/fallback")
      assert conn.status == 404
      assert response(conn, 404) =~ "Not Found"
    end

    test "does not redirect (no soft-404)", %{conn: conn} do
      conn = get(conn, "/invalid/path/to/trigger/fallback")
      refute conn.status in 300..399
    end

    test "emits no canonical link advertising the missing URL", %{conn: conn} do
      # The root layout carries a self-referential <link rel="canonical">. On a
      # 404 that would tell crawlers a dead page is its own canonical, so the
      # error response must render without it.
      conn = get(conn, "/invalid/path/to/trigger/fallback")
      refute response(conn, 404) =~ "rel=\"canonical\""
    end
  end
end
