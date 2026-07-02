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

    test "renders Add integration jump links to the calendars and video tabs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations")

      assert html =~ "Add integration"
      assert html =~ "Connect a calendar"
      assert html =~ "Connect a video tool"
      assert html =~ ~s(href="/dashboard/integrations?tab=calendars")
      assert html =~ ~s(href="/dashboard/integrations?tab=video")
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

    test "collapses CalDAV presets and reveals them via the Other CalDAV affordance",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      # Apple and Nextcloud show as first-class cards; the folded presets are
      # hidden behind the "Other CalDAV server" affordance.
      assert html =~ ~s(phx-value-provider="apple")
      assert html =~ ~s(phx-value-provider="nextcloud")
      assert html =~ "Other CalDAV server"
      refute html =~ ~s(phx-value-provider="zimbra")
      refute html =~ ~s(phx-value-provider="radicale")

      view
      |> element("button[phx-click='toggle_caldav_options']")
      |> render_click()

      revealed = render(view)
      assert revealed =~ ~s(phx-value-provider="zimbra")
      assert revealed =~ ~s(phx-value-provider="radicale")
      assert revealed =~ "Show fewer"
    end
  end

  describe "video tab" do
    test "renders a connected video integration with its summary and expandable detail",
         %{conn: conn, user: user} do
      integration =
        insert(:video_integration,
          user: user,
          provider: "mirotalk",
          name: "Team Room",
          is_active: true,
          base_url: "https://meet.myserver.com"
        )

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      # The nested video settings component renders the integration title
      # and its one-line summary (the self-hosted host and type).
      assert html =~ "Team Room"
      assert html =~ "meet.myserver.com"
      assert html =~ "self-hosted"

      # The provider-type label and the edit/delete action buttons live in
      # the collapsed detail slot (the header shows the lowercase
      # "self-hosted" tag instead of the "Self-Hosted" label).
      refute html =~ "Self-Hosted"

      refute has_element?(
               view,
               "button[phx-value-id='#{integration.id}'][phx-target='#delete-video-modal']"
             )

      view
      |> element("button[phx-click='toggle_row'][phx-value-id='#{integration.id}']")
      |> render_click()

      # Expanding reveals the provider-type detail and the action buttons.
      assert render(view) =~ "Self-Hosted"

      assert has_element?(
               view,
               "button[phx-value-id='#{integration.id}'][phx-target='#delete-video-modal']"
             )
    end
  end
end
