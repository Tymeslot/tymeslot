defmodule TymeslotWeb.Dashboard.IntegrationsHubTest do
  use TymeslotWeb.LiveCase, async: true
  @moduletag :utils

  import Tymeslot.DashboardTestHelpers

  setup :setup_dashboard_user

  describe "Integrations hub" do
    test "renders the integrations hub with tab labels", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations")

      assert html =~ "Integrations"
      # Tab labels rendered as patch links by the integrations tab nav.
      assert html =~ "Calendars"
      assert html =~ "Video"
      assert html =~ ~s(href="/dashboard/integrations?tab=calendars")
      assert html =~ ~s(href="/dashboard/integrations?tab=video")
    end

    test "marks the active tab link with aria-selected=true", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      # The active (video) tab carries aria-selected="true"; others are false.
      assert html =~ ~s(aria-selected="true")
      assert html =~ ~s(aria-selected="false")
    end

    test "defaults the active tab to calendars", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations")

      assert html =~ ~s(data-tab-panel="calendars")
    end

    test "reads the active tab from the tab query param", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert html =~ ~s(data-tab-panel="video")
    end
  end
end
