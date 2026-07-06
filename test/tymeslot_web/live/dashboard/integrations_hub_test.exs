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

    test "the active tab exposes a Connect button that opens the provider picker",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations")

      # The default tab is Calendars; its Connect button opens the picker.
      assert html =~ "Connect a calendar"
      assert html =~ ~s(phx-click="show_picker")
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
    test "renders a connected calendar with its summary and Manage calendars action",
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

      # The calendar chip grid moved into the selection modal; it is not in the
      # row until Manage calendars opens it.
      refute html =~ "Team Sync"

      view
      |> element("button[phx-click='manage_calendars'][phx-value-id='#{integration.id}']")
      |> render_click()

      assert render(view) =~ "Team Sync"
    end

    test "lists every CalDAV preset in the provider picker (no reveal needed)",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      # Every provider — including the CalDAV presets that used to be folded —
      # is present in the always-rendered picker modal.
      for provider <- ~w(apple nextcloud zimbra radicale baikal mailbox_org caldav) do
        assert html =~ ~s(phx-value-provider="#{provider}")
      end
    end
  end

  describe "video tab" do
    test "renders a connected video integration with its summary and always-visible actions",
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
      # and its one-line summary (the self-hosted host and type tag).
      assert html =~ "Team Room"
      assert html =~ "meet.myserver.com"
      assert html =~ "self-hosted"

      # The row is flat: the edit and delete controls are visible immediately,
      # with no expand step.
      assert has_element?(
               view,
               "button[phx-value-id='#{integration.id}'][phx-target='#delete-video-modal']"
             )

      assert has_element?(
               view,
               "button[phx-value-id='#{integration.id}'][phx-target='#edit-video-modal']"
             )
    end
  end
end
