defmodule TymeslotWeb.Dashboard.IntegrationsHubTest do
  use TymeslotWeb.LiveCase, async: true
  @moduletag :utils

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

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

  describe "calendars tab" do
    test "renders a connected calendar with its summary and an expandable calendar list",
         %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Work Google",
          is_active: true,
          provider_account_email: "me@gmail.com",
          calendar_list: [%{"id" => "cal-1", "name" => "Team Sync", "selected" => true}]
        )

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      # The nested calendar settings component renders the integration's
      # title and one-line summary (which includes the account email).
      assert html =~ "Work Google"
      assert html =~ "me@gmail.com"

      # The calendar chip grid lives in the collapsed detail slot.
      refute html =~ "Team Sync"

      view
      |> element("button[phx-click='toggle_row'][phx-value-id='#{integration.id}']")
      |> render_click()

      assert render(view) =~ "Team Sync"
    end
  end
end
