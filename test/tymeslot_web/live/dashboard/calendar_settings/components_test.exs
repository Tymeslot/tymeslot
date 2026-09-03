defmodule TymeslotWeb.Dashboard.CalendarSettings.ComponentsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias TymeslotWeb.Dashboard.CalendarSettings.Components

  describe "calendar_summary/1" do
    test "names the booking target when it is confirmed and writable" do
      integration =
        summary_integration(
          default_booking_calendar_id: "cal-writable",
          calendar_list: [
            %CalendarEntry{id: "cal-writable", name: "Work", read_only: false, primary: true}
          ]
        )

      assert Components.calendar_summary(integration) == "books into Work"
    end

    test "warns when a writable provider's configured booking target has turned read-only" do
      integration =
        summary_integration(
          default_booking_calendar_id: "cal-readonly",
          calendar_list: [
            %CalendarEntry{id: "cal-readonly", name: "Holidays", read_only: true, primary: false}
          ]
        )

      assert Components.calendar_summary(integration) ==
               "booking target can no longer accept bookings"
    end

    test "warns when a writable provider's primary calendar has turned read-only" do
      integration =
        summary_integration(
          default_booking_calendar_id: nil,
          calendar_list: [
            %CalendarEntry{id: "cal-primary", name: "Work", read_only: true, primary: true}
          ]
        )

      assert Components.calendar_summary(integration) ==
               "booking target can no longer accept bookings"
    end

    test "stays silent (no warning) when no booking target has ever been configured" do
      integration =
        summary_integration(
          default_booking_calendar_id: nil,
          calendar_list: [
            %CalendarEntry{id: "cal-a", name: "A", read_only: false, primary: false}
          ]
        )

      assert Components.calendar_summary(integration) == ""
    end

    # A provider that is read-only by construction never lost an ability, so
    # it gets the description rather than the "no longer" warning that tells a
    # user their bookings have started failing.
    test "describes an Exchange mailbox as read-only rather than reporting a breakage" do
      integration =
        summary_integration(
          provider: "exchange",
          default_booking_calendar_id: "cal-mailbox",
          calendar_list: [
            %CalendarEntry{id: "cal-mailbox", name: "Calendar", read_only: true, primary: true}
          ]
        )

      assert Components.calendar_summary(integration) ==
               "read-only, blocks time but takes no bookings"
    end

    test "describes a subscribed feed as read-only rather than reporting a breakage" do
      integration =
        summary_integration(
          provider: "ics_url",
          default_booking_calendar_id: nil,
          calendar_list: [
            %CalendarEntry{id: "cal-feed", name: "Team feed", read_only: true, primary: true}
          ]
        )

      assert Components.calendar_summary(integration) ==
               "read-only, blocks time but takes no bookings"
    end
  end

  describe "connected_calendars_section" do
    test "renders nothing when integrations list is empty" do
      assigns = %{
        integrations: [],
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
        is_refreshing: false,
        myself: "target"
      }

      html = render_component(&Components.connected_calendars_section/1, assigns)
      assert html =~ "Active for Conflict Checking"
      assert html =~ "My Calendar"
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
      assert html =~ "Nextcloud"
      assert html =~ "Server URL"
    end

    test "renders config view for baikal" do
      assigns = %{
        selected_provider: :baikal,
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
      assert html =~ "Baikal"
      assert html =~ "PHP-based CalDAV/CardDAV server"
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
      assert html =~ "Configuration form not available"
    end
  end

  describe "calendar_connection_row reconnect button" do
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
        render_component(&Components.calendar_connection_row/1,
          integration: integration,
          health_state: nil,
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
        render_component(&Components.calendar_connection_row/1,
          integration: integration,
          health_state: nil,
          myself: "target"
        )

      assert html =~ ~s(phx-click="show_reconnect")
      assert html =~ ~s(phx-value-id="7")
      assert html =~ ~s(phx-target="#caldav-reconnect-modal")
      assert html =~ "Reconnect"
    end
  end

  describe "calendar_connection_row read-only badge" do
    # The badge asks "can this take a booking?", which the Exchange mailbox
    # answers no to. The two actions beside it ask a narrower question, "is
    # this a feed?", and a mailbox answers no to that: it has folders to manage
    # and credentials to re-enter.
    test "an Exchange mailbox is badged read-only and keeps its manage and reconnect actions" do
      integration = %{
        id: 21,
        name: "Work mailbox",
        provider: "exchange",
        is_active: true,
        needs_reauth: false,
        calendar_list: [],
        calendar_paths: [],
        base_url: "https://exchange.example.com/EWS/Exchange.asmx",
        is_primary: false,
        default_booking_calendar_id: nil,
        provider_account_email: nil
      }

      html =
        render_component(&Components.calendar_connection_row/1,
          integration: integration,
          health_state: nil,
          myself: "target"
        )

      assert html =~ "Read-only"
      assert html =~ ~s(phx-click="manage_calendars")
      assert html =~ ~s(phx-click="show_reconnect")
    end
  end

  describe "calendar_connection_row desktop icon-only actions" do
    # On desktop the Manage-calendars and Reconnect actions collapse to
    # icon-only squares; their labels live in an `lg:hidden` span (shown on
    # mobile) and each carries an aria-label so the icon-only form stays
    # accessible.
    setup do
      integration = %{
        id: 12,
        name: "My CalDAV",
        provider: "caldav",
        is_active: true,
        needs_reauth: false,
        calendar_list: [
          %CalendarEntry{id: "/a/", path: "/a/", name: "A", selected: true}
        ],
        calendar_paths: ["/a/"],
        base_url: "https://caldav.example.com",
        is_primary: false,
        default_booking_calendar_id: nil,
        provider_account_email: nil
      }

      html =
        render_component(&Components.calendar_connection_row/1,
          integration: integration,
          health_state: nil,
          myself: "target"
        )

      {:ok, html: html}
    end

    test "Manage calendars is an aria-labelled button with an lg:hidden label", %{html: html} do
      assert html =~ ~s(aria-label="Manage calendars")
      # The visible text is kept for mobile but hidden from lg upwards.
      assert html =~ ~r/<span class="lg:hidden">\s*Manage calendars\s*<\/span>/
    end

    test "Reconnect is an aria-labelled button with an lg:hidden label", %{html: html} do
      assert html =~ ~s(aria-label="Reconnect integration")
      assert html =~ ~r/<span class="lg:hidden">\s*Reconnect\s*<\/span>/
    end

    test "the desktop icon-only sizing collapses the buttons to a square", %{html: html} do
      # lg:h-9/lg:w-9 with zeroed padding is what turns the padded mobile pill
      # into a square icon button on desktop.
      assert html =~ "lg:h-9"
      assert html =~ "lg:w-9"
    end
  end

  describe "calendar_connection_row status badge" do
    test "shows a Reconnect status when needs_reauth is true" do
      integration = %{
        id: 99,
        name: "Stale CalDAV",
        provider: "caldav",
        is_active: true,
        needs_reauth: true,
        calendar_list: [
          %CalendarEntry{id: "/a/", path: "/a/", name: "A", selected: true}
        ],
        calendar_paths: ["/a/"],
        base_url: "https://caldav.example.com",
        is_primary: false,
        default_booking_calendar_id: nil,
        provider_account_email: nil
      }

      # A needs_reauth integration surfaces the warning status badge and a
      # promoted (amber) Reconnect control so the fix is one click away.
      html =
        render_component(&Components.calendar_connection_row/1,
          integration: integration,
          health_state: nil,
          myself: "target"
        )

      assert html =~ "Reconnect"
      # The promoted reconnect style is amber.
      assert html =~ "bg-amber-50"
    end

    test "shows a Healthy status when needs_reauth is false" do
      integration = %{
        id: 100,
        name: "Healthy CalDAV",
        provider: "caldav",
        is_active: true,
        needs_reauth: false,
        calendar_list: [
          %CalendarEntry{id: "/a/", path: "/a/", name: "A", selected: true}
        ],
        calendar_paths: ["/a/"],
        base_url: "https://caldav.example.com",
        is_primary: false,
        default_booking_calendar_id: nil,
        provider_account_email: nil
      }

      html =
        render_component(&Components.calendar_connection_row/1,
          integration: integration,
          health_state: nil,
          myself: "target"
        )

      assert html =~ "Healthy"
      # A healthy row still offers Reconnect, but in the subtle (non-amber)
      # style — the promoted attention styling is reserved for needs_reauth.
      refute html =~ "bg-amber-50"
    end
  end

  # Every persisted integration carries a provider, and the summary now
  # branches on it, so the fixture carries one too: a bare map without
  # `:provider` would exercise a shape production never produces.
  defp summary_integration(attrs) do
    Map.merge(
      %{
        provider: "caldav",
        provider_account_email: nil,
        is_active: false,
        last_sync_at: nil,
        default_booking_calendar_id: nil,
        calendar_list: []
      },
      Map.new(attrs)
    )
  end
end
