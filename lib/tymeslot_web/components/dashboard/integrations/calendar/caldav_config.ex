defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavConfig do
  @moduledoc """
  Modern component for configuring CalDAV calendar integration.
  """
  use TymeslotWeb.Components.Dashboard.Integrations.Calendar.ConfigBase,
    provider: :caldav,
    default_name: "My CalDAV"

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
    <div id={"caldav-config-#{@id}"} class="space-y-6">
      <div class="flex items-center gap-4 mb-2">
        <ProviderIcon.provider_icon provider="caldav" type="calendar" size="large" />
        <div>
          <h3 class="text-xl font-black text-tymeslot-900 tracking-tight">CalDAV</h3>
          <p class="text-sm text-tymeslot-500 font-medium">Connect any CalDAV-compatible server</p>
        </div>
      </div>

      <SharedForm.config_form
        provider="caldav"
        show_calendar_selection={@show_calendar_selection}
        discovered_calendars={@discovered_calendars}
        discovery_credentials={@discovery_credentials}
        form_errors={@form_errors}
        form_values={@form_values}
        saving={@saving}
        target={@target}
        myself={@myself}
        suggested_name="My CalDAV"
        name_placeholder="My CalDAV Calendar"
        url_placeholder="https://caldav.example.com"
      />
    </div>
    """
  end
end
