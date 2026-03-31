defmodule TymeslotWeb.Components.DashboardSidebarTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  alias Floki
  alias TymeslotWeb.Components.DashboardSidebar

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
    assert html =~ "Calendar"
    assert html =~ "Video"
    assert html =~ "Theme"
    assert html =~ "Meetings"

    # Check exactly one active link, and it's the overview link
    active_links = Floki.find(doc, "a.dashboard-nav-link--active")
    assert length(active_links) == 1

    [active_link] = active_links
    assert Floki.attribute(active_link, "href") == ["/dashboard"]
  end

  test "renders active link correctly for different actions" do
    action_to_path = %{
      overview: "/dashboard",
      settings: "/dashboard/settings",
      availability: "/dashboard/availability",
      meeting_settings: "/dashboard/meeting-settings",
      calendar_integration: "/dashboard/calendar-integration",
      video_integration: "/dashboard/video-integration",
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

    # Exactly 3 notification badges for meeting settings, calendar, and video
    assert length(
             Floki.find(doc, "a[href='/dashboard/meeting-settings'] .dashboard-nav-notification")
           ) == 1

    assert length(
             Floki.find(
               doc,
               "a[href='/dashboard/calendar-integration'] .dashboard-nav-notification"
             )
           ) == 1

    assert length(
             Floki.find(doc, "a[href='/dashboard/video-integration'] .dashboard-nav-notification")
           ) == 1

    assert length(Floki.find(doc, ".dashboard-nav-notification")) == 3
    assert html =~ "!"
  end
end
