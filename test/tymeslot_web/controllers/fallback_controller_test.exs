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
    end

    test "renders the branded 404 page with a link back to the app root", %{conn: conn} do
      body = conn |> get("/invalid/path/to/trigger/fallback") |> response(404)

      # Not the bare Phoenix "Not Found" text — a self-contained, branded page
      # whose primary action routes to "/", which sends visitors on to auth.
      # The headline is translated, so HEEx renders it as dynamic content and
      # escapes the apostrophe; the browser still shows a plain one.
      assert body =~ "This page doesn&#39;t exist"
      assert body =~ "<!DOCTYPE html>"
      assert body =~ ~s(href="/")
      assert body =~ "app.css"
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
