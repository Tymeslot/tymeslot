defmodule TymeslotWeb.Dashboard.CalendarSettings.ComponentsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  alias TymeslotWeb.Dashboard.CalendarSettings.Components

  describe "connected_calendars_section" do
    test "renders nothing when integrations list is empty" do
      assigns = %{
        integrations: [],
        testing_integration_id: nil,
        validating_integration_id: nil,
        myself: "target"
      }

      html = render_component(&Components.connected_calendars_section/1, assigns)
      assert html == ""
    end

    test "renders integrations when list is not empty" do
      integration = %{
        id: 1,
        name: "My Calendar",
        provider: "google",
        is_active: true,
        needs_reauth: false,
        calendar_list: [],
        calendar_paths: [],
        base_url: nil,
        is_primary: true,
        default_booking_calendar_id: nil,
        provider_account_email: nil
      }

      assigns = %{
        integrations: [integration],
        testing_integration_id: nil,
        validating_integration_id: nil,
        is_refreshing: false,
        myself: "target"
      }

      html = render_component(&Components.connected_calendars_section/1, assigns)
      assert html =~ "Active for Conflict Checking"
      assert html =~ "My Calendar"
    end
  end

  describe "available_providers_section" do
    test "renders available providers" do
      providers = [
        %{type: :google, display_name: "Google Calendar"},
        %{type: :outlook, display_name: "Outlook Calendar"}
      ]

      assigns = %{
        available_calendar_providers: providers,
        myself: "target"
      }

      html = render_component(&Components.available_providers_section/1, assigns)
      assert html =~ "Available Providers"
      assert html =~ "Google Calendar"
      assert html =~ "Outlook Calendar"
    end

    test "handles empty providers list" do
      assigns = %{
        available_calendar_providers: [],
        myself: "target"
      }

      html = render_component(&Components.available_providers_section/1, assigns)
      assert html =~ "Available Providers"
      refute html =~ "Google Calendar"
    end
  end

  describe "config_view" do
    test "renders config view for nextcloud" do
      assigns = %{
        selected_provider: :nextcloud,
        myself: "target",
        security_metadata: %{},
        form_errors: %{},
        form_values: %{},
        discovered_calendars: [],
        show_calendar_selection: false,
        discovery_credentials: %{},
        is_saving: false
      }

      html = render_component(&Components.config_view/1, assigns)
      assert html =~ "Setup Nextcloud"
      assert html =~ "Server URL"
    end

    test "renders fallback for unknown provider" do
      assigns = %{
        selected_provider: :unknown,
        myself: "target",
        security_metadata: %{},
        form_errors: %{},
        form_values: %{},
        discovered_calendars: [],
        show_calendar_selection: false,
        discovery_credentials: %{},
        is_saving: false
      }

      html = render_component(&Components.config_view/1, assigns)
      assert html =~ "Setup Calendar"
      assert html =~ "Configuration form not available"
    end
  end

  describe "calendar_item reconnect button" do
    test "renders an OAuth Reconnect button for Google integrations" do
      integration = %{
        id: 42,
        name: "Work Google",
        provider: "google",
        is_active: true,
        needs_reauth: false,
        calendar_list: [],
        calendar_paths: [],
        base_url: nil,
        is_primary: false,
        default_booking_calendar_id: nil,
        provider_account_email: "user@example.com"
      }

      html =
        render_component(&Components.calendar_item/1,
          integration: integration,
          validating_integration_id: nil,
          myself: "target"
        )

      assert html =~ ~s(phx-click="connect_provider")
      assert html =~ ~s(phx-value-provider="google")
      assert html =~ "Reconnect"
    end

    test "renders a modal-targeted Reconnect button for CalDAV integrations" do
      integration = %{
        id: 7,
        name: "My CalDAV",
        provider: "caldav",
        is_active: true,
        needs_reauth: false,
        calendar_list: [],
        calendar_paths: ["/calendars/user/default/"],
        base_url: "https://caldav.example.com",
        is_primary: false,
        default_booking_calendar_id: nil,
        provider_account_email: nil
      }

      html =
        render_component(&Components.calendar_item/1,
          integration: integration,
          validating_integration_id: nil,
          myself: "target"
        )

      assert html =~ ~s(phx-click="show_reconnect")
      assert html =~ ~s(phx-value-id="7")
      assert html =~ ~s(phx-target="#caldav-reconnect-modal")
      assert html =~ "Reconnect"
    end
  end

  describe "calendar_item reauth badge" do
    test "renders a reauth warning badge when needs_reauth is true" do
      integration = %{
        id: 99,
        name: "Stale CalDAV",
        provider: "caldav",
        is_active: true,
        needs_reauth: true,
        calendar_list: [
          %{"id" => "/a/", "path" => "/a/", "name" => "A", "selected" => true}
        ],
        calendar_paths: ["/a/"],
        base_url: "https://caldav.example.com",
        is_primary: false,
        default_booking_calendar_id: nil,
        provider_account_email: nil
      }

      html =
        render_component(&Components.calendar_item/1,
          integration: integration,
          validating_integration_id: nil,
          myself: "target"
        )

      assert html =~ "Reconnect required"
    end

    test "does not render the reauth badge when needs_reauth is false" do
      integration = %{
        id: 100,
        name: "Healthy CalDAV",
        provider: "caldav",
        is_active: true,
        needs_reauth: false,
        calendar_list: [
          %{"id" => "/a/", "path" => "/a/", "name" => "A", "selected" => true}
        ],
        calendar_paths: ["/a/"],
        base_url: "https://caldav.example.com",
        is_primary: false,
        default_booking_calendar_id: nil,
        provider_account_email: nil
      }

      html =
        render_component(&Components.calendar_item/1,
          integration: integration,
          validating_integration_id: nil,
          myself: "target"
        )

      refute html =~ "Reconnect required"
    end
  end
end
