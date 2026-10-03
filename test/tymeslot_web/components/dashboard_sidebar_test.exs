defmodule TymeslotWeb.Components.DashboardSidebarTest do
  # async: false: :dashboard_extension_gettext is read wherever the sidebar renders, which is
  # every dashboard LiveView test.
  use TymeslotWeb.ConnCase, async: false

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

  test "marks only the active link as the current page for assistive technology" do
    assigns = %{
      current_action: :availability,
      integration_status: %{has_calendar: true, has_video: true, has_meeting_types: true},
      profile: %{username: "testuser"}
    }

    doc =
      (&DashboardSidebar.sidebar/1)
      |> render_component(assigns)
      |> Floki.parse_document!()

    assert doc |> Floki.find("a[aria-current='page']") |> Floki.attribute("href") ==
             ["/dashboard/availability"]
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

    # The icon-only button carries an accessible name
    assert Floki.attribute(copy_btn, "aria-label") == ["Copy link to clipboard"]
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

    # Copy button inert but focusable: named for the action, the tooltip says why
    disabled_copy_btn = Floki.find(doc, "button#copy-scheduling-link-disabled")
    assert length(disabled_copy_btn) == 1
    assert Floki.attribute(disabled_copy_btn, "aria-disabled") == ["true"]
    assert Floki.attribute(disabled_copy_btn, "disabled") == []
    assert Floki.attribute(disabled_copy_btn, "phx-hook") == []
    assert Floki.attribute(disabled_copy_btn, "aria-label") == ["Copy link to clipboard"]

    assert disabled_copy_btn |> Floki.attribute("title") |> List.first() =~
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

    # Copy button inert but focusable: named for the action, the tooltip says why
    disabled_copy_btn = Floki.find(doc, "button#copy-scheduling-link-disabled")
    assert length(disabled_copy_btn) == 1
    assert Floki.attribute(disabled_copy_btn, "aria-disabled") == ["true"]
    assert Floki.attribute(disabled_copy_btn, "aria-label") == ["Copy link to clipboard"]

    assert disabled_copy_btn |> Floki.attribute("title") |> List.first() =~
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

    # Each badge is a bare dot: hidden from assistive technology, with its
    # reason spoken from screen-reader-only text instead.
    assert doc
           |> Floki.find(
             "a[href='/dashboard/meeting-settings'] .dashboard-nav-notification .sr-only"
           )
           |> Floki.text() == "Add a meeting type so guests have something to book"

    assert length(Floki.find(doc, ".dashboard-nav-notification [aria-hidden=true]")) == 2
    refute html =~ ~r/dashboard-nav-notification[^>]*>\s*!/
  end

  describe "Integrations item styling" do
    @needs_setup %{has_calendar: false, has_video: false, has_meeting_types: true}
    @all_connected %{has_calendar: true, has_video: true, has_meeting_types: true}

    test "carries no highlight on another page while setup is outstanding" do
      link = integrations_link(:overview, @needs_setup)

      assert link_classes(link) == ["dashboard-nav-link"]
      assert Floki.attribute(link, "aria-current") == []
      assert length(Floki.find(link, ".dashboard-nav-notification")) == 1
    end

    test "carries no highlight and no dot on another page once everything is connected" do
      link = integrations_link(:polls, @all_connected)

      assert link_classes(link) == ["dashboard-nav-link"]
      assert Floki.attribute(link, "aria-current") == []
      assert Floki.find(link, ".dashboard-nav-notification") == []
    end

    test "is styled as active on the Integrations page, with or without outstanding setup" do
      for status <- [@needs_setup, @all_connected] do
        link = integrations_link(:integrations, status)

        assert link_classes(link) == ["dashboard-nav-link", "dashboard-nav-link--active"]
        assert Floki.attribute(link, "aria-current") == ["page"]
      end
    end

    test "only the current section is highlighted on any page while setup is outstanding" do
      for action <- [:overview, :meetings, :polls, :theme, :settings] do
        doc =
          (&DashboardSidebar.sidebar/1)
          |> render_component(%{
            current_action: action,
            integration_status: %{has_calendar: false, has_video: false, has_meeting_types: false},
            profile: %{username: "testuser"}
          })
          |> Floki.parse_document!()

        highlighted =
          doc
          |> Floki.find("aside nav a.dashboard-nav-link")
          |> Enum.reject(&(link_classes(&1) == ["dashboard-nav-link"]))
          |> Enum.flat_map(&Floki.attribute(&1, "href"))

        assert length(highlighted) == 1, "#{action}: #{inspect(highlighted)}"
        refute "/dashboard/integrations" in highlighted
        refute "/dashboard/meeting-settings" in highlighted
      end
    end
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

  test "Integrations badge names the video provider when only that is unconnected" do
    status = %{has_calendar: true, has_video: false, has_meeting_types: true}

    assert integrations_badge_title(status) == "Connect a video provider to finish setup"
  end

  test "Integrations badge names the calendar when only that is unconnected" do
    status = %{has_calendar: false, has_video: true, has_meeting_types: true}

    assert integrations_badge_title(status) == "Connect a calendar to finish setup"
  end

  test "Integrations badge names both when neither is connected" do
    status = %{has_calendar: false, has_video: false, has_meeting_types: true}

    assert integrations_badge_title(status) ==
             "Connect a calendar and a video provider to finish setup"
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

  # The badge is a bare dot, so what it says is carried twice: as
  # screen-reader-only text and as a hover tooltip. Both must agree.
  defp integrations_badge_title(integration_status) do
    badge =
      :overview
      |> integrations_link(integration_status)
      |> Floki.find(".dashboard-nav-notification")

    [title] = Floki.attribute(badge, "title")
    assert badge |> Floki.find(".sr-only") |> Floki.text() == title
    title
  end

  defp integrations_link(current_action, integration_status) do
    assigns = %{
      current_action: current_action,
      integration_status: integration_status,
      profile: %{username: "testuser"}
    }

    (&DashboardSidebar.sidebar/1)
    |> render_component(assigns)
    |> Floki.parse_document!()
    |> Floki.find("aside nav a[href='/dashboard/integrations']")
  end

  defp link_classes(link) do
    link |> Floki.attribute("class") |> Enum.join(" ") |> String.split()
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
