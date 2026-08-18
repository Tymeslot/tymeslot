defmodule TymeslotWeb.RootLayoutTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :ui

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

  describe "root layout robots directive" do
    # Every surface behind this layout is private, and the auth pages in
    # particular are linked from the public marketing site. Keeping them out of
    # a search index depends on the directive being in the page itself: a
    # robots.txt disallow only stops the crawl, so a linked page is indexed
    # anyway and the directive is never read.
    test "marks auth pages noindex", %{conn: conn} do
      for path <- [~p"/auth/login", ~p"/auth/signup"] do
        assert conn |> get(path) |> html_response(200) =~
                 ~s(<meta name="robots" content="noindex")
      end
    end
  end
end
