defmodule TymeslotWeb.Dashboard.CalendarSettings.ComponentsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils
  @moduletag :calendar

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

    # Booking writes to the configured calendar, not to the primary, so a
    # read-only booking calendar must be reported even while the primary can
    # still be written.
    test "warns when the booking calendar turned read-only while the primary stays writable" do
      integration =
        summary_integration(
          provider: "google",
          default_booking_calendar_id: "cal-team",
          calendar_list: [
            %CalendarEntry{id: "cal-team", name: "Team", read_only: true, primary: false},
            %CalendarEntry{id: "cal-primary", name: "Primary", read_only: false, primary: true}
          ]
        )

      assert Components.calendar_summary(integration) ==
               "booking target can no longer accept bookings"
    end

    test "does not name the primary when the booking calendar is no longer listed" do
      integration =
        summary_integration(
          provider: "google",
          default_booking_calendar_id: "cal-gone",
          calendar_list: [
            %CalendarEntry{id: "cal-primary", name: "Primary", read_only: false, primary: true}
          ]
        )

      assert Components.calendar_summary(integration) == ""
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

    # Exchange is a writable provider now, so it gets the same warning every
    # other writable provider gets when the folder it books into turns out not
    # to accept writes. It was described as read-only by construction while the
    # EWS provider refused every write, which was a statement about the
    # provider rather than about this folder.
    test "warns when an Exchange mailbox's booking folder cannot be written" do
      integration =
        summary_integration(
          provider: "exchange",
          default_booking_calendar_id: "cal-mailbox",
          calendar_list: [
            %CalendarEntry{id: "cal-mailbox", name: "Calendar", read_only: true, primary: true}
          ]
        )

      assert Components.calendar_summary(integration) ==
               "booking target can no longer accept bookings"
    end

    test "names the booking folder when an Exchange folder is writable" do
      integration =
        summary_integration(
          provider: "exchange",
          default_booking_calendar_id: "cal-mailbox",
          calendar_list: [
            %CalendarEntry{id: "cal-mailbox", name: "Calendar", read_only: false, primary: true}
          ]
        )

      # The same segment every writable provider gets. Exchange reached this
      # branch for the first time when the write path landed; before that it
      # was short-circuited into the read-only description.
      assert Components.calendar_summary(integration) == "books into Calendar"
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

    # Only the OAuth providers record an account email, so before this the line
    # for a CalDAV row started at the conflict-check segment and named neither
    # the account nor the server it belonged to.
    test "names the server when the provider records no account email" do
      integration =
        summary_integration(base_url: "https://cloud.example.com:8443/nextcloud")

      assert Components.calendar_summary(integration) == "cloud.example.com:8443/nextcloud"
    end

    # The server URL field takes free text, so a password typed into it must
    # not reach the dashboard.
    test "never renders credentials embedded in the server URL" do
      integration = summary_integration(base_url: "https://admin:hunter2@cloud.example.com")

      summary = Components.calendar_summary(integration)

      assert summary == "cloud.example.com"
      refute summary =~ "hunter2"
    end

    test "prefers the account email over the server when the provider records one" do
      integration =
        summary_integration(
          provider: "google",
          provider_account_email: "organiser@example.com",
          base_url: "https://www.googleapis.com"
        )

      assert Components.calendar_summary(integration) == "organiser@example.com"
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
    # The badge asks "can this take a booking?", which an Exchange mailbox now
    # answers yes to, so it carries no badge. The two actions beside it ask a
    # narrower question, "is this a feed?", and a mailbox answers no to that:
    # it has folders to manage and credentials to re-enter, so both survive the
    # badge going away.
    test "an Exchange mailbox is not badged read-only and keeps its manage and reconnect actions" do
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

      refute html =~ "Read-only"
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

    test "says why the integration needs reconnecting" do
      html = render_row_with(needs_reauth: true, sync_error: "No calendar is selected.")

      assert html =~ "No calendar is selected."
    end

    # The stored sync_error is the reason's untranslated English msgid, so the
    # row must translate it into the viewer's own locale rather than rendering
    # the persisted English text verbatim.
    test "translates a known reason into the viewer's locale" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")
      on_exit(fn -> Gettext.put_locale(TymeslotWeb.Gettext, "en") end)

      html =
        render_row_with(
          needs_reauth: true,
          sync_error:
            "The booking calendar no longer exists on Google. Please reconnect the integration and choose a different calendar."
        )

      assert html =~
               "Der Buchungskalender existiert bei Google nicht mehr. Bitte verbinden Sie die Integration erneut und wählen Sie einen anderen Kalender."
    end

    # sync_error also carries transient failures, which are not the owner's to fix.
    test "keeps a stored sync error to itself while the integration is not flagged" do
      html = render_row_with(needs_reauth: false, sync_error: "Timed out talking to the server.")

      refute html =~ "Timed out talking to the server."
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

  defp render_row_with(overrides) do
    integration =
      Enum.into(overrides, %{
        id: 101,
        name: "Flagged CalDAV",
        provider: "caldav",
        is_active: true,
        calendar_list: [%CalendarEntry{id: "/a/", path: "/a/", name: "A", selected: true}],
        calendar_paths: ["/a/"],
        base_url: "https://caldav.example.com",
        is_primary: false,
        default_booking_calendar_id: nil,
        provider_account_email: nil
      })

    render_component(&Components.calendar_connection_row/1,
      integration: integration,
      health_state: nil,
      myself: "target"
    )
  end
end
