defmodule TymeslotWeb.Dashboard.IntegrationsHubTest do
  use TymeslotWeb.LiveCase, async: true
  @moduletag :utils

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Repo

  setup :setup_dashboard_user

  # Persists an `unhealthy` health-state row for an active integration, the
  # shape `list_unhealthy_for_user/1` (and therefore the hub banner) reads.
  defp mark_unhealthy(user, integration_id, type) do
    %IntegrationHealthStateSchema{}
    |> IntegrationHealthStateSchema.changeset(%{
      integration_type: type,
      integration_id: integration_id,
      user_id: user.id,
      status: "unhealthy"
    })
    |> Repo.insert!()
  end

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

  describe "attention banner and tab summary" do
    test "renders no attention banner when every integration is healthy",
         %{conn: conn, user: user} do
      insert(:calendar_integration, user: user, is_active: true, needs_reauth: false)

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations")

      # No aggregated banner and no coloured status dots on the tabs.
      refute html =~ "needs attention"
      refute html =~ "bg-amber-500"
      refute html =~ "bg-red-500"
    end

    test "surfaces an unhealthy calendar with a banner, a jump link and a tab dot",
         %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration, user: user, name: "Work Google", is_active: true)

      mark_unhealthy(user, integration.id, "calendar")

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations")

      # The aggregated banner names the integration and links to the tab.
      assert html =~ "1 connection needs attention"
      assert html =~ "Work Google stopped syncing."
      assert html =~ ~s(href="/dashboard/integrations?tab=calendars")
      assert html =~ "Review"

      # The Calendars tab carries the amber warning dot.
      assert has_element?(view, "span.bg-amber-500")
    end

    test "shows the connected-calendar count on the Calendars tab",
         %{conn: conn, user: user} do
      insert(:calendar_integration, user: user, is_active: true)
      insert(:calendar_integration, user: user, is_active: true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations")

      # The count pill inside the Calendars tab link reads "2".
      assert has_element?(view, "a[role='tab'] span", "2")
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
