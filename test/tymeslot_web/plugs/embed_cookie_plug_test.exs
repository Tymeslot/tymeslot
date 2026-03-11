defmodule TymeslotWeb.Plugs.EmbedCookiePlugTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs
  @moduletag :security

  alias TymeslotWeb.Plugs.EmbedCookiePlug

  @session_cookie "_tymeslot_key"

  describe "call/2" do
    test "registers a before_send callback", %{conn: conn} do
      conn = EmbedCookiePlug.call(conn, [])
      assert conn.private[:before_send] != []
    end
  end

  describe "before_send callback — cross-site embed flag not set" do
    test "does not rewrite the session cookie", %{conn: conn} do
      conn =
        conn
        |> EmbedCookiePlug.call([])
        |> put_resp_cookie(@session_cookie, "token", same_site: "Lax", secure: true)
        |> send_resp(200, "")

      assert conn.resp_cookies[@session_cookie][:same_site] == "Lax"
    end
  end

  describe "before_send callback — cross-site embed flag set" do
    test "rewrites SameSite to None when cookie is Secure", %{conn: conn} do
      conn =
        conn
        |> put_private(:embed_cookie_samesite_none, true)
        |> EmbedCookiePlug.call([])
        |> put_resp_cookie(@session_cookie, "token", same_site: "Lax", secure: true)
        |> send_resp(200, "")

      assert conn.resp_cookies[@session_cookie][:same_site] == "None"
      assert conn.resp_cookies[@session_cookie][:secure] == true
    end

    test "skips rewrite when cookie is not Secure (http dev/test context)", %{conn: conn} do
      conn =
        conn
        |> put_private(:embed_cookie_samesite_none, true)
        |> EmbedCookiePlug.call([])
        |> put_resp_cookie(@session_cookie, "token", same_site: "Lax", secure: false)
        |> send_resp(200, "")

      assert conn.resp_cookies[@session_cookie][:same_site] == "Lax"
    end

    test "leaves other cookies untouched", %{conn: conn} do
      conn =
        conn
        |> put_private(:embed_cookie_samesite_none, true)
        |> EmbedCookiePlug.call([])
        |> put_resp_cookie("other_cookie", "value", same_site: "Lax", secure: true)
        |> put_resp_cookie(@session_cookie, "token", same_site: "Lax", secure: true)
        |> send_resp(200, "")

      assert conn.resp_cookies["other_cookie"][:same_site] == "Lax"
      assert conn.resp_cookies[@session_cookie][:same_site] == "None"
    end
  end
end
