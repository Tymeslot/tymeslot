defmodule TymeslotWeb.Dashboard.CalendarSettings.AvailableProvidersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  alias TymeslotWeb.Dashboard.CalendarSettings.AvailableProviders

  describe "available_providers_section" do
    test "renders OAuth providers as cards" do
      providers = [
        %{type: :google, display_name: "Google Calendar"},
        %{type: :outlook, display_name: "Outlook Calendar"}
      ]

      assigns = %{available_calendar_providers: providers, myself: "target"}

      html = render_component(&AvailableProviders.available_providers_section/1, assigns)
      assert html =~ "Available Providers"
      assert html =~ "Google Calendar"
      assert html =~ "Outlook Calendar"
    end

    test "handles an empty providers list" do
      assigns = %{available_calendar_providers: [], myself: "target"}

      html = render_component(&AvailableProviders.available_providers_section/1, assigns)
      assert html =~ "Available Providers"
      refute html =~ "Google Calendar"
    end

    test "collapses CalDAV presets to Apple, Nextcloud and an Other CalDAV affordance" do
      assigns = %{available_calendar_providers: caldav_providers(), myself: "target"}

      html = render_component(&AvailableProviders.available_providers_section/1, assigns)

      # The two first-class presets render as cards.
      assert html =~ ~s(phx-value-provider="apple")
      assert html =~ ~s(phx-value-provider="nextcloud")

      # The reveal affordance is present.
      assert html =~ "Other CalDAV server"

      # The folded presets are NOT rendered as cards yet.
      refute html =~ ~s(phx-value-provider="zimbra")
      refute html =~ ~s(phx-value-provider="radicale")
      refute html =~ ~s(phx-value-provider="baikal")
    end

    test "reveals the folded CalDAV presets when show_all_caldav is true" do
      assigns = %{
        available_calendar_providers: caldav_providers(),
        show_all_caldav: true,
        myself: "target"
      }

      html = render_component(&AvailableProviders.available_providers_section/1, assigns)

      assert html =~ ~s(phx-value-provider="apple")
      assert html =~ ~s(phx-value-provider="nextcloud")
      assert html =~ ~s(phx-value-provider="zimbra")
      assert html =~ ~s(phx-value-provider="radicale")
      assert html =~ ~s(phx-value-provider="baikal")
      assert html =~ ~s(phx-value-provider="mailbox_org")
      assert html =~ ~s(phx-value-provider="caldav")

      # The affordance now offers to collapse again.
      assert html =~ "Show fewer"
    end
  end

  defp caldav_providers do
    [
      %{type: :apple, display_name: "Apple iCloud"},
      %{type: :nextcloud, display_name: "Nextcloud"},
      %{type: :radicale, display_name: "Radicale"},
      %{type: :baikal, display_name: "Baikal"},
      %{type: :zimbra, display_name: "Zimbra"},
      %{type: :mailbox_org, display_name: "mailbox.org"},
      %{type: :caldav, display_name: "CalDAV"}
    ]
  end
end
