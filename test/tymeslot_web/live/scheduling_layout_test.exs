defmodule TymeslotWeb.Live.SchedulingLayoutTest do
  @moduledoc """
  Integration coverage for the `?layout=column` query param on the public
  scheduling page. The param threads through `Themes.Core.Context` to the
  root layout, which sets `data-embed-layout` on `<html>` so theme CSS
  can render the wide-canvas variant.
  """
  use TymeslotWeb.ConnCase, async: false
  @moduletag :themes
  @moduletag :live
  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Mox

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "layoutuser")

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _integration,
                                                                _range_start,
                                                                _range_end ->
      {:ok, []}
    end)

    insert(:calendar_integration, user: user, provider: "google", is_active: true)
    insert(:meeting_type, user: user, name: "Test Meeting", duration_minutes: 30, is_active: true)

    {:ok, username: profile.username}
  end

  describe "layout query param" do
    test "renders default layout when no param is passed", %{conn: conn, username: username} do
      {:ok, _view, html} = live(conn, "/#{username}")

      assert html =~ ~s(data-embed-layout="default")
    end

    test "renders column layout when ?layout=column", %{conn: conn, username: username} do
      {:ok, _view, html} = live(conn, "/#{username}?layout=column")

      assert html =~ ~s(data-embed-layout="column")
    end

    test "falls back to default for unsupported layout values", %{
      conn: conn,
      username: username
    } do
      {:ok, _view, html} = live(conn, "/#{username}?layout=mosaic")

      assert html =~ ~s(data-embed-layout="default")
    end
  end

  describe "layout query param on reschedule route" do
    setup %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "layoutuser2")
      insert(:theme_customization, profile: profile, theme_id: "1")

      meeting =
        insert(:future_meeting,
          organizer_user: user,
          status: "confirmed"
        )

      {:ok, conn: conn, username: profile.username, meeting_uid: meeting.uid}
    end

    test "renders column layout on reschedule route when ?layout=column", %{
      conn: conn,
      username: username,
      meeting_uid: meeting_uid
    } do
      {:ok, _view, html} =
        live(conn, "/#{username}/meeting/#{meeting_uid}/reschedule?layout=column")

      assert html =~ ~s(data-embed-layout="column")
    end

    test "renders default layout on reschedule route when no param is passed", %{
      conn: conn,
      username: username,
      meeting_uid: meeting_uid
    } do
      {:ok, _view, html} = live(conn, "/#{username}/meeting/#{meeting_uid}/reschedule")

      assert html =~ ~s(data-embed-layout="default")
    end
  end
end
