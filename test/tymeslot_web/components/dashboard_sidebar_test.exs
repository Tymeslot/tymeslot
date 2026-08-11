defmodule TymeslotWeb.Components.DashboardSidebarTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  alias Floki
  alias TymeslotWeb.Components.DashboardSidebar

  setup do
    on_exit(fn -> Gettext.put_locale(TymeslotWeb.Gettext, "en") end)
    :ok
  end

  test "renders sidebar with all navigation links" do
    assigns = %{
      current_action: :overview,
      integration_status: %{has_calendar: true, has_video: true, has_meeting_types: true},
      profile: %{username: "testuser"}
    }

    html = render_component(&DashboardSidebar.sidebar/1, assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "Overview"
    assert html =~ "Profile"
    assert html =~ "Availability"
    assert html =~ "Meeting Types"
    assert html =~ "Integrations"
    assert html =~ "Theme"
    assert html =~ "Meetings"

    # Check exactly one active link, and it's the overview link
    active_links = Floki.find(doc, "a.dashboard-nav-link--active")
    assert length(active_links) == 1

    [active_link] = active_links
    assert Floki.attribute(active_link, "href") == ["/dashboard/overview"]
  end

  test "renders active link correctly for different actions" do
    # The merged Integrations item is current for the hub action and for every
    # legacy action that redirects into it, so all four highlight the same link.
    action_to_path = %{
      overview: "/dashboard/overview",
      settings: "/dashboard/settings",
      availability: "/dashboard/availability",
      meeting_settings: "/dashboard/meeting-settings",
      integrations: "/dashboard/integrations",
      calendar_integration: "/dashboard/integrations",
      video_integration: "/dashboard/integrations",
      payments: "/dashboard/integrations",
      theme: "/dashboard/theme",
      meetings: "/dashboard/meetings"
    }

    for {action, expected_href} <- action_to_path do
      assigns = %{
        current_action: action,
        integration_status: %{has_calendar: true, has_video: true, has_meeting_types: true},
        profile: %{username: "testuser"}
      }

      html = render_component(&DashboardSidebar.sidebar/1, assigns)
      doc = Floki.parse_document!(html)

      active_links = Floki.find(doc, "a.dashboard-nav-link--active")
      assert length(active_links) == 1

      [active_link] = active_links
      assert Floki.attribute(active_link, "href") == [expected_href]
    end
  end

  test "shows scheduling link when allowed" do
    assigns = %{
      current_action: :overview,
      integration_status: %{has_calendar: true},
      profile: %{username: "testuser"}
    }

    html = render_component(&DashboardSidebar.sidebar/1, assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "View Page"

    # Scheduling page link
    assert Floki.find(doc, "a.dashboard-nav-link[href='/testuser'][target='_blank']") != []

    # Copy link button is enabled
    copy_btn = Floki.find(doc, "button#copy-scheduling-link")
    assert length(copy_btn) == 1
    refute copy_btn |> List.first() |> Floki.attribute("disabled") |> Enum.any?()
  end

  test "disables scheduling link when no username" do
    assigns = %{
      current_action: :overview,
      integration_status: %{has_calendar: true},
      profile: %{username: nil}
    }

    html = render_component(&DashboardSidebar.sidebar/1, assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "View Page"
    assert html =~ "cursor-not-allowed"
    assert html =~ "Set a username in Settings to enable this feature"

    # No clickable scheduling link
    assert Floki.find(doc, "a[href='/testuser']") == []

    # Copy button disabled with tooltip
    disabled_copy_btn = Floki.find(doc, "button[disabled][title]")
    assert length(disabled_copy_btn) == 1

    assert disabled_copy_btn |> List.first() |> Floki.attribute("title") |> List.first() =~
             "Set a username in Settings to enable this feature"
  end

  test "disables scheduling link when no calendar connected" do
    assigns = %{
      current_action: :overview,
      integration_status: %{has_calendar: false},
      profile: %{username: "testuser"}
    }

    html = render_component(&DashboardSidebar.sidebar/1, assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "View Page"
    assert html =~ "cursor-not-allowed"
    assert html =~ "Connect a calendar in Calendar settings to enable this feature"

    # No clickable scheduling link
    assert Floki.find(doc, "a[href='/testuser']") == []

    # Copy button disabled with tooltip
    disabled_copy_btn = Floki.find(doc, "button[disabled][title]")
    assert length(disabled_copy_btn) == 1

    assert disabled_copy_btn |> List.first() |> Floki.attribute("title") |> List.first() =~
             "Connect a calendar in Calendar settings to enable this feature"
  end

  test "shows notification badges when setup is incomplete" do
    assigns = %{
      current_action: :overview,
      integration_status: %{has_calendar: false, has_video: false, has_meeting_types: false},
      profile: %{username: "testuser"}
    }

    html = render_component(&DashboardSidebar.sidebar/1, assigns)
    doc = Floki.parse_document!(html)

    # Exactly 2 notification badges now: one for meeting settings and one for the
    # merged Integrations item (which flags either an unconnected calendar or an
    # unconnected video provider).
    assert length(
             Floki.find(doc, "a[href='/dashboard/meeting-settings'] .dashboard-nav-notification")
           ) == 1

    assert length(
             Floki.find(doc, "a[href='/dashboard/integrations'] .dashboard-nav-notification")
           ) == 1

    assert length(Floki.find(doc, ".dashboard-nav-notification")) == 2
    assert html =~ "!"
  end

  test "Integrations badge shows when only one of calendar/video is unconnected" do
    assigns = %{
      current_action: :overview,
      integration_status: %{has_calendar: true, has_video: false, has_meeting_types: true},
      profile: %{username: "testuser"}
    }

    doc =
      (&DashboardSidebar.sidebar/1)
      |> render_component(assigns)
      |> Floki.parse_document!()

    assert length(
             Floki.find(doc, "a[href='/dashboard/integrations'] .dashboard-nav-notification")
           ) == 1
  end

  test "Integrations badge is absent once calendar and video are both connected" do
    assigns = %{
      current_action: :overview,
      integration_status: %{has_calendar: true, has_video: true, has_meeting_types: true},
      profile: %{username: "testuser"}
    }

    doc =
      (&DashboardSidebar.sidebar/1)
      |> render_component(assigns)
      |> Floki.parse_document!()

    assert Floki.find(doc, "a[href='/dashboard/integrations'] .dashboard-nav-notification") == []
  end

  test "translates sidebar extension labels through the configured gettext backend" do
    pin_extension_gettext({TymeslotWeb.Gettext, "dashboard_common"})

    assigns = %{
      current_action: :overview,
      integration_status: %{has_calendar: true, has_video: true, has_meeting_types: true},
      profile: %{username: "testuser"},
      sidebar_extensions: [
        %{
          id: :calendar_sync,
          label: "Calendar",
          icon: "hero-calendar-days",
          path: "/dashboard/calendar-sync",
          action: :calendar_sync
        }
      ]
    }

    Gettext.put_locale(TymeslotWeb.Gettext, "de")

    doc =
      (&DashboardSidebar.sidebar/1)
      |> render_component(assigns)
      |> Floki.parse_document!()

    assert doc |> Floki.find("a[href='/dashboard/calendar-sync']") |> Floki.text() =~ "Kalender"
  end

  test "falls back to the raw label when an extension has no matching translation" do
    pin_extension_gettext({TymeslotWeb.Gettext, "dashboard_common"})

    assigns = %{
      current_action: :overview,
      integration_status: %{has_calendar: true, has_video: true, has_meeting_types: true},
      profile: %{username: "testuser"},
      sidebar_extensions: [
        %{
          id: :unregistered,
          label: "Some Untranslated Extension",
          icon: "hero-puzzle-piece",
          path: "/dashboard/unregistered",
          action: :unregistered
        }
      ]
    }

    Gettext.put_locale(TymeslotWeb.Gettext, "de")
    html = render_component(&DashboardSidebar.sidebar/1, assigns)

    assert html =~ "Some Untranslated Extension"
  end

  # In the umbrella build the SaaS config repoints :dashboard_extension_gettext at
  # its own catalogue, so these tests pin the Core default to stay deterministic
  # in both the standalone and umbrella test runs.
  defp pin_extension_gettext(backend_and_domain) do
    original = Application.fetch_env!(:tymeslot, :dashboard_extension_gettext)
    Application.put_env(:tymeslot, :dashboard_extension_gettext, backend_and_domain)
    on_exit(fn -> Application.put_env(:tymeslot, :dashboard_extension_gettext, original) end)
  end
end
