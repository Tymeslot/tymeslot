defmodule TymeslotWeb.Dashboard.CalendarSettings.ComponentsTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias TymeslotWeb.Dashboard.CalendarSettings.Components

  describe "connected_calendars_section" do
  @moduletag :utils
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
        calendar_list: [],
        calendar_paths: [],
        base_url: nil,
        is_primary: true,
        default_booking_calendar_id: nil
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
end
