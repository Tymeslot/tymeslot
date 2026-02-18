defmodule TymeslotWeb.FallbackControllerTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true

  describe "GET / (fallback)" do
  @moduletag :utils
    test "redirects to root path", %{conn: conn} do
      # We need to trigger the fallback.
      # Paths like "/foo" are caught by the /:username route.
      # Paths with multiple segments like "/foo/bar" should hit the fallback.

      conn = get(conn, "/invalid/path/to/trigger/fallback")
      assert redirected_to(conn) == "/"
    end
  end
end
