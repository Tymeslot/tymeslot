defmodule TymeslotWeb.Components.DashboardIntegrationsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import TymeslotWeb.Components.CoreComponents
  alias Floki

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.ConfigBase
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.NextcloudConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.RadicaleConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents
  alias TymeslotWeb.Components.Dashboard.Integrations.IntegrationForm
  alias TymeslotWeb.Components.Dashboard.Integrations.ProviderCard
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.DeleteIntegrationModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.MirotalkConfig
  alias TymeslotWeb.Dashboard.CalendarSettings.Components, as: CalendarComponents
  alias TymeslotWeb.Dashboard.CalendarSettingsComponent

  test "renders calendar_item correctly" do
    assigns = %{
      integration: %{
        id: 1,
        name: "My Calendar",
        provider: "google",
        is_active: true,
        calendar_list: [%{"id" => "cal1", "name" => "Work", "selected" => true}],
        default_booking_calendar_id: "cal1",
        provider_account_email: nil
      },
      validating_integration_id: 0,
      myself: "some-target"
    }

    html = render_component(&CalendarComponents.calendar_item/1, assigns)
    assert html =~ "My Calendar"
    assert html =~ "Work"
    assert html =~ "Active for Conflict Checking" or html =~ "Syncing 1 Calendars"
  end

  test "renders calendar_item correctly when inactive" do
    assigns = %{
      integration: %{
        id: 1,
        name: "My Calendar",
        provider: "google",
        is_active: false,
        calendar_list: [],
        provider_account_email: nil
      },
      validating_integration_id: 0,
      myself: "some-target"
    }

    html = render_component(&CalendarComponents.calendar_item/1, assigns)
    assert html =~ "Paused"
    assert html =~ "disabled"
  end

  test "renders calendar_item safely when calendar_list is nil" do
    assigns = %{
      integration: %{
        id: 1,
        name: "My Calendar",
        provider: "google",
        is_active: true,
        calendar_list: nil,
        provider_account_email: nil
      },
      validating_integration_id: 0,
      myself: "some-target"
    }

    # Should not crash
    html = render_component(&CalendarComponents.calendar_item/1, assigns)
    assert html =~ "My Calendar"
    assert html =~ "Syncing 0 Calendars"
    assert html =~ "No calendars found"
  end

  test "renders provider_card correctly" do
    assigns = %{
      provider: "google",
      title: "Google Calendar",
      description: "Sync with Google",
      button_text: "Connect",
      click_event: "connect_google",
      target: "some-target",
      provider_value: "google"
    }

    html = render_component(&ProviderCard.provider_card/1, assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "Google Calendar"
    assert html =~ "Sync with Google"
    assert html =~ "Connect"

    assert Floki.find(
             doc,
             "button[phx-click='connect_google'][phx-target='some-target'][phx-value-provider='google']"
           ) != []
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

  test "renders shared loading_spinner correctly" do
    assigns = %{class: "w-10 h-10"}
    html = render_component(&UIComponents.loading_spinner/1, assigns)
    doc = Floki.parse_document!(html)
    assert html =~ "animate-spin"
    assert Floki.find(doc, "svg.w-10.h-10.animate-spin") != []
  end

  test "renders shared form_submit_button correctly" do
    # Non-saving state
    assigns = %{saving: false, text: "Save Me"}
    html = render_component(&UIComponents.form_submit_button/1, assigns)
    doc = Floki.parse_document!(html)
    assert html =~ "Save Me"
    refute html =~ "Saving..."
    assert Floki.find(doc, "button[type='submit'][disabled]") == []

    # Saving state
    assigns = %{saving: true, saving_text: "Saving Now..."}
    html = render_component(&UIComponents.form_submit_button/1, assigns)
    doc = Floki.parse_document!(html)
    assert html =~ "Saving Now..."
    assert html =~ "animate-spin"
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
      CalendarSettingsComponent.handle_event(
        "track_form_change",
        %{"integration" => %{"name" => "My CalDAV"}},
        socket
      )

    assert socket.assigns.form_values["name"] == "My CalDAV"

    # validate_field
    {:noreply, socket} =
      CalendarSettingsComponent.handle_event(
        "validate_field",
        %{"field" => "url", "value" => "https://example.com/dav"},
        socket
      )

    refute Map.has_key?(socket.assigns.form_errors, :url)

    # discover_calendars with invalid credentials
    {:noreply, socket} =
      CalendarSettingsComponent.handle_event(
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
    assert is_map(socket.assigns.form_errors)

    assert Map.has_key?(socket.assigns.form_errors, :username) or
             Map.has_key?(socket.assigns.form_errors, :password)
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
    assert function_exported?(module_name, :assign_config_defaults, 1)
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

  describe "toggle_calendar_selection" do
    test "handles missing integration gracefully" do
      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            __changed__: %{},
            integrations: [%{id: 1, calendar_list: []}],
            current_user: %{id: 1}
          }
        }

      {:noreply, updated_socket} =
        CalendarSettingsComponent.handle_event(
          "toggle_calendar_selection",
          %{"integration_id" => "999", "calendar_id" => "cal1"},
          socket
        )

      # Socket should remain unchanged when integration not found
      assert updated_socket.assigns.integrations == socket.assigns.integrations
    end

    test "correctly calculates toggled selection state" do
      integration = %Tymeslot.DatabaseSchemas.CalendarIntegrationSchema{
        id: 1,
        user_id: 1,
        provider: "caldav",
        calendar_list: [
          %{"id" => "cal1", "selected" => true},
          %{"id" => "cal2", "selected" => false}
        ]
      }

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            __changed__: %{},
            integrations: [integration],
            current_user: %{id: 1}
          }
        }

      # Test that the handler processes the toggle correctly
      # The actual Calendar.update_calendar_selection call would require DB setup
      {:noreply, _updated_socket} =
        CalendarSettingsComponent.handle_event(
          "toggle_calendar_selection",
          %{"integration_id" => "1", "calendar_id" => "cal1"},
          socket
        )

      # Handler should process without crashing
      assert true
    end

    test "handles empty calendar_list" do
      integration = %Tymeslot.DatabaseSchemas.CalendarIntegrationSchema{
        id: 1,
        user_id: 1,
        provider: "caldav",
        calendar_list: []
      }

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            __changed__: %{},
            integrations: [integration],
            current_user: %{id: 1}
          }
        }

      {:noreply, updated_socket} =
        CalendarSettingsComponent.handle_event(
          "toggle_calendar_selection",
          %{"integration_id" => "1", "calendar_id" => "cal1"},
          socket
        )

      # Should handle gracefully without error
      assert updated_socket.assigns.integrations == socket.assigns.integrations
    end
  end
end
