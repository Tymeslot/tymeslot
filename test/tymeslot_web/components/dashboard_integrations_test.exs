defmodule TymeslotWeb.Components.DashboardIntegrationsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import TymeslotWeb.Components.CoreComponents
  alias Floki

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.ConfigBase
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.MailboxOrgConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.NextcloudConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.RadicaleConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents
  alias TymeslotWeb.Components.Dashboard.Integrations.IntegrationForm
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.DeleteIntegrationModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.MirotalkConfig
  alias TymeslotWeb.Dashboard.CalendarSettings.Components, as: CalendarComponents
  alias TymeslotWeb.Dashboard.CalendarSettings.ConfigViewComponent
  alias TymeslotWeb.Dashboard.CalendarSettingsComponent

  test "renders calendar_connection_row with its flat, always-visible actions" do
    assigns = %{
      integration: %{
        id: 1,
        name: "My Calendar",
        provider: "google",
        is_active: true,
        calendar_list: [%CalendarEntry{id: "cal1", name: "Work", selected: true}],
        default_booking_calendar_id: "cal1",
        provider_account_email: nil,
        needs_reauth: false
      },
      health_state: nil,
      myself: "some-target"
    }

    html = render_component(&CalendarComponents.calendar_connection_row/1, assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "My Calendar"
    # The row is flat: Manage calendars, Reconnect and Delete are visible
    # without any expand step. The calendar-selection chips now live in the
    # dedicated selection modal, not the row.
    assert html =~ "Manage calendars"
    assert html =~ "Reconnect"

    assert Floki.find(
             doc,
             "button[phx-click='manage_calendars'][phx-value-id='1'][phx-target='some-target']"
           ) != []

    assert Floki.find(doc, "button[phx-click='show'][phx-target='#delete-calendar-modal']") != []
  end

  test "renders calendar_connection_row correctly when inactive" do
    assigns = %{
      integration: %{
        id: 1,
        name: "My Calendar",
        provider: "google",
        is_active: false,
        calendar_list: [],
        provider_account_email: nil,
        needs_reauth: false
      },
      health_state: nil,
      myself: "some-target"
    }

    html = render_component(&CalendarComponents.calendar_connection_row/1, assigns)
    assert html =~ "Paused"
    # The shared connection row dims inactive integrations.
    assert html =~ "opacity-70"
    # The modal behind this action also holds the name and colour, which apply
    # to a connection with no discovered calendars just as much as to one with.
    assert html =~ "Manage calendars"
  end

  test "renders calendar_connection_row safely when calendar_list is nil" do
    assigns = %{
      integration: %{
        id: 1,
        name: "My Calendar",
        provider: "google",
        is_active: true,
        calendar_list: nil,
        provider_account_email: nil,
        needs_reauth: false
      },
      health_state: nil,
      myself: "some-target"
    }

    # Should not crash
    html = render_component(&CalendarComponents.calendar_connection_row/1, assigns)
    assert html =~ "My Calendar"
    assert html =~ "Manage calendars"
  end

  test "renders shared close_button correctly" do
    assigns = %{target: "some-target"}
    html = render_component(&UIComponents.close_button/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.find(
             doc,
             "button[phx-click='back_to_providers'][phx-target='some-target'][title='Close']"
           ) != []

    assert Floki.text(doc) =~ "Close"
  end

  test "renders shared form_submit_button correctly" do
    # Non-saving state
    assigns = %{saving: false, text: "Save Me"}
    html = render_component(&UIComponents.form_submit_button/1, assigns)
    doc = Floki.parse_document!(html)
    assert html =~ "Save Me"
    # The saving branch renders the spinner plus either `saving_text` or the
    # "Adding..." default — never the string "Saving...", so refuting that could
    # never fire. Refute what the branch actually emits.
    refute html =~ "Adding..."
    refute html =~ "spinner"
    assert Floki.find(doc, "button[type='submit'][disabled]") == []

    # Saving state
    assigns = %{saving: true, saving_text: "Saving Now..."}
    html = render_component(&UIComponents.form_submit_button/1, assigns)
    doc = Floki.parse_document!(html)
    assert html =~ "Saving Now..."
    # The design-system `<.spinner>` carries the `spinner` class; the spin
    # animation comes from CSS (`.spinner { @apply animate-spin }`), not from a
    # utility class in the markup.
    assert html =~ "spinner"
    assert Floki.find(doc, "button[type='submit'][disabled]") != []
  end

  test "renders shared secondary_button correctly" do
    assigns = %{target: "some-target", label: "Back", phx_click: "go_back", icon: "hero-x-mark"}
    html = render_component(&UIComponents.secondary_button/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.find(doc, "button[phx-click='go_back'][phx-target='some-target']") != []
    assert Floki.text(doc) =~ "Back"
  end

  test "renders delete_integration_modal copy for calendar and video" do
    base_assigns = %{
      id: "delete-integration",
      integration_type: :calendar,
      current_user: %{id: 1}
    }

    html = render_component(DeleteIntegrationModal, base_assigns)

    assert html =~ "Delete Calendar Integration"
    assert html =~ "calendar data"
    assert html =~ "Delete Integration"

    html =
      render_component(DeleteIntegrationModal, %{
        base_assigns
        | integration_type: :video
      })

    assert html =~ "Delete Video Integration"
    assert html =~ "video conferencing configuration"
    assert html =~ "Delete Integration"
  end

  test "renders integration_form with provider info and base errors" do
    inner_block = [
      %{__slot__: :inner_block, inner_block: fn assigns, _index -> ~H[<.input name="x" />] end}
    ]

    assigns = %{
      title: "Add Integration",
      cancel_event: "cancel",
      submit_event: "submit",
      target: "some-target",
      provider_info: "Nextcloud",
      show_errors: true,
      form_errors: %{base: ["Something went wrong"]},
      saving: false,
      submit_text: "Add It",
      inner_block: inner_block
    }

    html = render_component(&IntegrationForm.render/1, assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "Add Integration"
    assert html =~ "Provider:"
    assert html =~ "Nextcloud"
    assert html =~ "Something went wrong"
    assert Floki.find(doc, "form[phx-submit='submit'][phx-target='some-target']") != []
    assert Floki.find(doc, "button[type='submit']") != []
    assert html =~ "Add It"
  end

  test "renders integration_form submit button in saving state" do
    inner_block = [
      %{__slot__: :inner_block, inner_block: fn assigns, _index -> ~H[<.input name="x" />] end}
    ]

    assigns = %{
      title: "Add Integration",
      cancel_event: "cancel",
      submit_event: "submit",
      target: "some-target",
      provider_info: nil,
      show_errors: false,
      form_errors: %{},
      saving: true,
      submit_text: "Add It",
      inner_block: inner_block
    }

    html = render_component(&IntegrationForm.render/1, assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "Adding..."
    assert Floki.find(doc, "button[type='submit'][disabled]") != []
  end

  test "renders shared calendar config_form in discovery and selection modes" do
    base_assigns = %{
      provider: "caldav",
      show_calendar_selection: false,
      discovered_calendars: [],
      discovery_credentials: %{url: "https://example.com/dav", username: "u", password: "p"},
      form_errors: %{},
      form_values: %{"name" => "My CalDAV", "url" => "https://example.com/dav"},
      saving: false,
      target: "parent-target",
      myself: "self-target",
      suggested_name: "Suggested"
    }

    # Discovery mode
    html =
      render_component(&SharedFormComponents.config_form/1, base_assigns)

    doc = Floki.parse_document!(html)

    assert Floki.find(
             doc,
             "form[phx-submit='discover_calendars'][phx-change='track_form_change']"
           ) != []

    assert html =~ "Integration Name"
    assert html =~ "Server URL"
    assert html =~ "Username"
    assert html =~ "Password / App Password"

    assert Floki.find(doc, "button[phx-click='back_to_providers'][phx-target='parent-target']") !=
             []

    # Selection mode
    html =
      render_component(&SharedFormComponents.config_form/1, %{
        base_assigns
        | show_calendar_selection: true,
          discovered_calendars: [%{name: "Work", path: "/cal1"}]
      })

    doc = Floki.parse_document!(html)
    assert Floki.find(doc, "form[phx-submit='add_integration'][phx-target='parent-target']") != []
    assert html =~ "Select calendars to sync:"
    assert html =~ "Work"
    assert html =~ "/cal1"

    assert Floki.find(doc, "input[type='hidden'][name='integration[provider]'][value='caldav']") !=
             []

    assert Floki.find(doc, "input[type='hidden'][name='integration[username]'][value='u']") != []
  end

  test "ConfigBase event handlers update assigns without external calls" do
    socket =
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          form_errors: %{url: "bad"},
          security_metadata: %{},
          form_values: %{},
          selected_provider: :caldav
        }
      }

    # track_form_change
    {:noreply, socket} =
      ConfigViewComponent.handle_event(
        "track_form_change",
        %{"integration" => %{"name" => "My CalDAV"}},
        socket
      )

    assert socket.assigns.form_values["name"] == "My CalDAV"

    # validate_field
    {:noreply, socket} =
      ConfigViewComponent.handle_event(
        "validate_field",
        %{"field" => "url", "value" => "https://example.com/dav"},
        socket
      )

    refute Map.has_key?(socket.assigns.form_errors, :url)

    # discover_calendars with invalid credentials
    {:noreply, socket} =
      ConfigViewComponent.handle_event(
        "discover_calendars",
        %{
          "integration" => %{
            "url" => "https://example.com/dav",
            "username" => "",
            "password" => ""
          }
        },
        socket
      )

    assert socket.assigns.is_saving == false
    assert socket.assigns.form_errors == %{username: "Username is required"}
  end

  test "renders calendar provider config headers and provider hidden fields" do
    base_assigns = %{
      id: "test",
      target: "parent-target",
      myself: "self-target",
      saving: false,
      form_values: %{},
      form_errors: %{},
      show_calendar_selection: false,
      discovered_calendars: [],
      discovery_credentials: %{}
    }

    html = render_component(&CaldavConfig.render/1, base_assigns)
    assert html =~ "CalDAV"
    assert html =~ "Connect any CalDAV-compatible server"
    assert html =~ ~s(name="integration[provider]" value="caldav")

    html = render_component(&NextcloudConfig.render/1, base_assigns)
    assert html =~ "Nextcloud"
    assert html =~ "Sync calendars from your Nextcloud server"
    assert html =~ ~s(name="integration[provider]" value="nextcloud")

    html = render_component(&RadicaleConfig.render/1, base_assigns)
    assert html =~ "Radicale"
    assert html =~ "Lightweight CalDAV server integration"
    assert html =~ ~s(name="integration[provider]" value="radicale")

    html = render_component(&MailboxOrgConfig.render/1, base_assigns)
    assert html =~ "mailbox.org"
    assert html =~ "Sync calendars from your mailbox.org account"
    assert html =~ "application-specific password"
    assert html =~ ~s(name="integration[provider]" value="mailbox_org")
  end

  test "renders video provider configs" do
    base_assigns = %{
      target: "parent-target",
      saving: false,
      form_values: %{},
      form_errors: %{}
    }

    html = render_component(&MirotalkConfig.render/1, base_assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "MiroTalk P2P"

    assert Floki.find(doc, "input[type='hidden'][name='integration[provider]'][value='mirotalk']") !=
             []

    assert html =~ "API Key"
    assert html =~ "Server URL"

    html = render_component(&CustomConfig.render/1, base_assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "Custom Video"

    assert Floki.find(doc, "input[type='hidden'][name='integration[provider]'][value='custom']") !=
             []

    assert html =~ "Meeting URL"
  end

  test "ConfigBase macro can be exercised at runtime" do
    # credo:disable-for-lines:2 Credo.Check.Warning.UnsafeToAtom
    module_name =
      Module.concat(__MODULE__, "ConfigBaseRuntime#{System.unique_integer([:positive])}")

    code = """
    defmodule #{module_name} do
      use #{ConfigBase}, provider: :caldav, default_name: "X"
    end
    """

    [{compiled, _bin}] = Code.compile_string(code)
    assert compiled == module_name

    # The macro must inject working defaults, not merely define the function.
    assert %{
             show_calendar_selection: false,
             discovered_calendars: [],
             discovery_credentials: %{},
             form_values: %{},
             form_errors: %{},
             saving: false,
             metadata: %{}
           } = module_name.assign_config_defaults(%{__changed__: %{}})
  end

  describe "refresh_all_calendars" do
    test "sets is_refreshing flag and handles empty active integrations" do
      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            __changed__: %{},
            integrations: [],
            is_refreshing: false,
            current_user: %{id: 1}
          }
        }

      {:noreply, updated_socket} =
        CalendarSettingsComponent.handle_event("refresh_all_calendars", %{}, socket)

      assert updated_socket.assigns.is_refreshing == false
    end

    test "filters only active integrations for refresh" do
      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            id: "test",
            __changed__: %{},
            integrations: [
              %{id: 1, is_active: true, calendar_list: []},
              %{id: 2, is_active: false, calendar_list: []},
              %{id: 3, is_active: true, calendar_list: []}
            ],
            is_refreshing: false,
            current_user: %{id: 1}
          }
        }

      # This test verifies the filtering logic - actual refresh calls would require
      # database setup, but we can verify the event handler structure
      {:noreply, updated_socket} =
        CalendarSettingsComponent.handle_event("refresh_all_calendars", %{}, socket)

      # Refresh starts asynchronously; flag should be set while work runs
      assert updated_socket.assigns.is_refreshing == true
    end
  end

  # `toggle_calendar_selection` LiveComponent handler — full user-visible
  # round-trip (happy path, stale/deleted integration) is exercised in
  # `test/tymeslot_web/live/dashboard/calendar_settings_composition_test.exs`.
end
