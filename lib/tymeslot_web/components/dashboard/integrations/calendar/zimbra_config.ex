defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.ZimbraConfig do
  @moduledoc """
  Modern component for configuring Zimbra calendar integration.
  """
  use TymeslotWeb.Components.Dashboard.Integrations.Calendar.ConfigBase,
    provider: :zimbra,
    default_name: "My Zimbra"

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
    <div id={"zimbra-config-#{@id}"} class="space-y-6">
      <div class="flex items-center gap-4 mb-2">
        <ProviderIcon.provider_icon provider="zimbra" type="calendar" size="large" />
        <div>
          <h3 class="text-xl font-black text-tymeslot-900 tracking-tight">Zimbra</h3>
          <p class="text-sm text-tymeslot-500 font-medium">Sync calendars from your Zimbra server</p>
        </div>
      </div>

      <SharedForm.config_form
        provider="zimbra"
        show_calendar_selection={@show_calendar_selection}
        discovered_calendars={@discovered_calendars}
        discovery_credentials={@discovery_credentials}
        form_errors={@form_errors}
        form_values={@form_values}
        saving={@saving}
        target={@target}
        myself={@myself}
        suggested_name="My Zimbra"
        name_placeholder="My Zimbra Calendar"
        url_placeholder="https://mail.example.com"
      />
    </div>
    """
  end
end
