defmodule TymeslotWeb.FreebusyControllerTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :controllers

  import Tymeslot.Factory

  alias Tymeslot.FreeBusy

  describe "GET /free-busy/:token" do
    test "returns a text/calendar VFREEBUSY for a valid token", %{conn: conn} do
      {:ok, profile} = FreeBusy.enable_feed(insert(:profile))

      conn = get(conn, ~p"/free-busy/#{profile.freebusy_token}")

      assert conn |> get_resp_header("content-type") |> List.first() =~ "text/calendar"
      body = response(conn, 200)
      assert body =~ "BEGIN:VCALENDAR"
      assert body =~ "BEGIN:VFREEBUSY"
    end

    test "returns 404 for an unknown token", %{conn: conn} do
      conn = get(conn, ~p"/free-busy/does-not-exist")

      assert response(conn, 404)
    end
  end
end
