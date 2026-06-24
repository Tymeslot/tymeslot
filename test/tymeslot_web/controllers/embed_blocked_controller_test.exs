defmodule TymeslotWeb.EmbedBlockedControllerTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :security

  describe "GET /embed-unavailable" do
    test "renders the notice and is universally frameable", %{conn: conn} do
      conn = get(conn, ~p"/embed-unavailable")

      assert html_response(conn, 200) =~ "can’t be embedded here"

      # Universally frameable: no frame-ancestors directive, no X-Frame-Options.
      assert [csp] = get_resp_header(conn, "content-security-policy")
      refute csp =~ "frame-ancestors"
      assert get_resp_header(conn, "x-frame-options") == []
    end

    test "posts tymeslot-embed-blocked to a valid parent origin", %{conn: conn} do
      conn = get(conn, ~p"/embed-unavailable?#{%{"parent-origin" => "https://example.com"}}")
      body = html_response(conn, 200)

      assert body =~ ~s(data-parent-origin="https://example.com")
      assert body =~ "tymeslot-embed-blocked"
    end

    test "reduces a parent origin with a path to a bare origin", %{conn: conn} do
      conn =
        get(conn, ~p"/embed-unavailable?#{%{"parent-origin" => "https://example.com/some/page"}}")

      body = html_response(conn, 200)

      assert body =~ ~s(data-parent-origin="https://example.com")
      refute body =~ "/some/page"
    end

    test "ignores a non-http(s) parent origin and omits the message", %{conn: conn} do
      conn = get(conn, ~p"/embed-unavailable?#{%{"parent-origin" => "ftp://evil.example"}}")
      body = html_response(conn, 200)

      refute body =~ "tymeslot-embed-blocked"
      refute body =~ "data-parent-origin=\"ftp"
    end

    test "ignores a list-valued parent origin and omits the message", %{conn: conn} do
      # Plug parses bracket-notation params into a list, so the sanitiser
      # receives a non-binary value — it must fall through to nil, not crash.
      conn = get(conn, "/embed-unavailable?parent-origin[]=https://example.com")
      body = html_response(conn, 200)

      refute body =~ "tymeslot-embed-blocked"
      refute body =~ "data-parent-origin"
    end
  end
end
