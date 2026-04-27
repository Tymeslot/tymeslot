defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.MailboxOrgConfig do
  @moduledoc """
  Component for configuring mailbox.org calendar integration.
  """
  use TymeslotWeb.Components.Dashboard.Integrations.Calendar.ConfigBase,
    provider: :mailbox_org,
    default_name: "My mailbox.org"

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Components.Icons.ProviderIcon

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, assign_config_defaults(socket)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_config_defaults()}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={"mailbox-org-config-#{@id}"} class="space-y-6">
      <div class="flex items-center gap-4 mb-2">
        <ProviderIcon.provider_icon provider="mailbox_org" type="calendar" size="large" />
        <div>
          <h3 class="text-xl font-black text-tymeslot-900 tracking-tight">mailbox.org</h3>
          <p class="text-sm text-tymeslot-500 font-medium">
            Sync calendars from your mailbox.org account
          </p>
        </div>
      </div>

      <p class="text-sm text-tymeslot-600 leading-relaxed">
        If you have two-factor authentication enabled, generate an application-specific password under
        <span class="font-semibold">Settings → Security</span>
        on mailbox.org and use that here instead of your regular password.
      </p>

      <SharedForm.config_form
        provider="mailbox_org"
        show_calendar_selection={@show_calendar_selection}
        discovered_calendars={@discovered_calendars}
        discovery_credentials={@discovery_credentials}
        form_errors={@form_errors}
        form_values={@form_values}
        saving={@saving}
        target={@target}
        myself={@myself}
        suggested_name="My mailbox.org"
        name_placeholder="My mailbox.org Calendar"
        url_placeholder="https://dav.mailbox.org"
      />
    </div>
    """
  end
end
