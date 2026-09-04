defmodule TymeslotWeb.Live.AuthBackgroundMotionTest do
  @moduledoc """
  The auth pages run the same autoplaying, looping background video as the
  booking page, so WCAG 2.2 SC 2.2.2 applies to them identically: there has to
  be a mechanism on the page to stop it.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :auth
  @moduletag :live

  import Phoenix.LiveViewTest

  defp document(conn, path) do
    {:ok, _view, html} = live(conn, path)
    Floki.parse_document!(html)
  end

  describe "login page" do
    test "the background video ships a control to stop it", %{conn: conn} do
      doc = document(conn, ~p"/auth/login")

      assert [_video | _rest] = Floki.find(doc, "#auth-video-container video")

      [toggle] = Floki.find(doc, "#background-motion-toggle")

      assert Floki.attribute([toggle], "phx-hook") == ["BackgroundMotionToggle"]
      assert [name] = Floki.attribute([toggle], "aria-label")
      assert name != ""

      # Both names are rendered up front: the hook swaps them client-side, so
      # the control still reads correctly for a visitor whose stored choice the
      # server never sees.
      assert [_pause] = Floki.attribute([toggle], "data-label-pause")
      assert [_play] = Floki.attribute([toggle], "data-label-play")
    end
  end

  describe "signup page" do
    test "the background video ships a control to stop it", %{conn: conn} do
      doc = document(conn, ~p"/auth/signup")

      assert [_video | _rest] = Floki.find(doc, "#auth-video-container video")
      assert [_toggle] = Floki.find(doc, "#background-motion-toggle")
    end
  end
end
